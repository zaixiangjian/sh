#!/usr/bin/env bash
# 独立导出自 /root/kejilion.sh 应用 44；不修改源脚本。
# 默认保留原部署路径、端口与禁止注册配置。
set -uo pipefail

CONTAINER="vaultwarden"
INSTALL_DIR="/home/docker/vaultwarden"
OFFICIAL_IMAGE="vaultwarden/server:latest"
CUSTOM_IMAGE="zaixiangjian/vaultwarden:latest"
BACKUP_DIR="/home/备份/vaultwarden"  # 本地备份目录，支持末尾 /

QUIET_SECONDS=5                      # 文件连续无变化等待秒数
DAILY_BACKUP_TIME="05:00"             # 每日打包并传送（主机时区）
DAILY_TRANSFER_TIME="05:05"           # SSH/S3 每日只传最新备份（主机时区）
S3_RETENTION_COUNT=100               # S3远端最多保留备份数量
TRANSFER_RETRY_SECONDS=60           # SSH/S3传送失败后的重试间隔（秒）
TRANSFER_MAX_ATTEMPTS=3             # 每个新备份最多尝试次数（含首次）

# Only mutating operations take this lock; menus and status remain concurrent.
# EXIT/INT/TERM recovery is best effort; SIGKILL cannot run traps.
docker() {
    local limit=180
    [[ ${1:-} != pull && ${1:-} != push ]] || limit=900
    command timeout --kill-after=10s "${limit}s" docker "$@"
}

operation_lock() {
    if [[ ${VW_OP_LOCK_FD+x} ]]; then
        [[ "$VW_OP_LOCK_FD" =~ ^[0-9]+$ ]] || { echo "无效的继承锁 fd。"; return 1; }
        python3 - "$VW_OP_LOCK_FD" <<'PYLOCK'
import os, sys, stat, fcntl
try:
    fd = int(sys.argv[1])
    a, b = os.fstat(fd), os.stat('/run/vaultwarden-operation.lock')
    if not stat.S_ISREG(a.st_mode) or (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
        raise ValueError('not operation lock')
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except Exception:
    sys.exit('继承锁 fd 校验失败，未执行操作。')
PYLOCK
        return $?
    fi
    exec 8>/run/vaultwarden-operation.lock || return 1
    flock -x 8 || return 1
    export VW_OP_LOCK_FD=8
}

operation_recover() {
    local rc=$?
    trap - EXIT INT TERM HUP
    [[ -z ${VW_TEMP_ARCHIVE:-} ]] || rm -f -- "$VW_TEMP_ARCHIVE"
    if [[ ${VW_RECOVER_START:-1} == 1 ]] && container_exists; then
        docker start "$CONTAINER" >/dev/null 2>&1 || echo "操作结束/中断后启动失败，请人工检查 Vaultwarden。" >&2
    fi
    exit "$rc"
}

run_operation() {
    operation_lock || return 1
    local VW_RECOVER_START=1 VW_TEMP_ARCHIVE= rc=0
    [[ "$1" != uninstall_app_unlocked ]] || VW_RECOVER_START=0
    trap operation_recover EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    "$@" || rc=$?
    if [[ "$VW_RECOVER_START" == 1 ]] && container_exists; then
        if ! docker start "$CONTAINER" >/dev/null || ! verify_running; then
            echo "操作结束后容器启动/运行校验失败，请检查日志。" >&2
            rc=1
        fi
    fi
    [[ -z "$VW_TEMP_ARCHIVE" ]] || rm -f -- "$VW_TEMP_ARCHIVE"
    trap - EXIT INT TERM HUP
    return "$rc"
}

install_app() {
    ( run_operation install_app_unlocked "$@" ) || return 1
    repair_background_tasks
}
update_app() ( run_operation update_app_unlocked "$@"; )
backup_app() ( run_operation backup_app_unlocked "$@"; )
restore_app() ( run_operation restore_app_unlocked "$@"; )
set_registration() ( run_operation set_registration_unlocked "$@"; )
uninstall_app() {
    local answer rc=0
    require_docker || return 1
    if ! /usr/bin/python3 - "$INSTALL_DIR" "$BACKUP_DIR" <<'PY'
from pathlib import Path
import sys
install=Path(sys.argv[1]);backup=Path(sys.argv[2])
if not install.is_absolute() or install.is_symlink():sys.exit('安装目录无效，已取消')
i,b=install.resolve(),backup.resolve()
if str(i) in ('/','/home','/root','/home/web','/home/docker') or len(i.parts)<4:sys.exit('安装目录范围过大，已取消')
if b==i or i in b.parents:sys.exit('备份目录在安装目录内，禁止卸载以免删除备份')
PY
    then return 1; fi
    echo "将停止后台任务，备份整个data目录并传送一次，再删除容器及本地安装目录。"
    echo "删除目录：$INSTALL_DIR（含任务配置和凭据）；保留备份目录：$BACKUP_DIR"
    echo "密码库保存在data备份中，任务配置不会单独备份；S3此次不清理旧备份。"
    IFS= read -r -p "确认卸载请输入小写 yes：" answer || return 0
    [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
    /usr/bin/python3 /root/yingyong/vaultwarden-lifecycle.py stop || return 1
    ( run_operation uninstall_app_unlocked ) || rc=$?
    if [[ "$rc" != 0 ]]; then
        echo "卸载已中止，尝试恢复后台任务。"
        repair_background_tasks || echo "后台任务恢复失败，请检查服务。"
    fi
    return "$rc"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "未安装 Docker，请先安装 Docker 后重试。"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "无法连接 Docker，请检查服务状态及当前用户权限。"
        return 1
    fi
}

container_exists() {
    docker container inspect "$CONTAINER" >/dev/null 2>&1
}

install_app_unlocked() {
    local image="$1"
    require_docker || return 1
    if container_exists; then
        echo "容器 $CONTAINER 已存在，请使用更新菜单；不会覆盖现有部署。"
        return 1
    fi
    docker pull "$image" || return 1
    mkdir -p "$INSTALL_DIR/data" || return 1
    if ! docker run -d --name "$CONTAINER" \
        -e SIGNUPS_ALLOWED=false -e WEB_VAULT_ENABLED=false --restart always \
        -p 3280:80 -v "$INSTALL_DIR/data:/data" "$image"; then
        echo "安装失败，数据目录已保留。请检查容器日志与端口占用。"
        return 1
    fi
    if ! verify_running; then
        echo "容器未能稳定运行，请执行：docker logs vaultwarden"
        return 1
    fi
    echo "安装完成：$image"
    echo "访问端口：3280；请通过 HTTPS 反向代理访问。"
    echo "注册已禁用；全新密码库需要另行安排首个账户创建。"
    echo "数据目录：$INSTALL_DIR/data"
}

verify_running() {
    local i state health
    for i in 1 2 3 4 5; do
        sleep 2
        state="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" || return 1
        [[ "$state" == true ]] || return 1
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER")" || return 1
        [[ "$health" != unhealthy ]] || return 1
    done
    # 这是容器运行状态检查，不冒充应用端到端可用性验证。
}

update_app_unlocked() {
    local image="$1" old running backup tmp
    local web_enabled="${2:-}"
    [[ -z $web_enabled || $web_enabled == true || $web_enabled == false ]] || return 1
    require_docker || return 1
    command -v python3 >/dev/null 2>&1 || { echo "更新需要 python3。"; return 1; }
    container_exists || { echo "未安装，请先选择安装。"; return 1; }
    tmp="$(mktemp -d)" || return 1
    chmod 700 "$tmp"
    if ! docker inspect "$CONTAINER" > "$tmp/inspect.json"; then
        rm -rf -- "$tmp"; return 1
    fi
    # 从实际容器复制环境、数据挂载、端口、重启策略等；敏感信息不输出。
    if ! python3 - "$tmp/inspect.json" "$tmp/args" "$image" "$web_enabled" <<'PY'
import json, sys, subprocess
c = json.load(open(sys.argv[1]))[0]
h, cfg = c['HostConfig'], c['Config']
try:
    original_image = json.loads(subprocess.check_output(
        ['docker', 'image', 'inspect', c['Image']], stderr=subprocess.DEVNULL,
        text=True, timeout=30))[0]['Config']
except (subprocess.SubprocessError, OSError, ValueError, KeyError, IndexError):
    sys.exit('无法读取当前容器原镜像的默认启动配置，已取消更新。')
networks = c.get('NetworkSettings', {}).get('Networks', {})
if len(networks) > 1:
    sys.exit('检测到多网络部署，为避免丢失网络配置，请使用原部署工具更新。')
if h.get('Privileged') or h.get('Devices') or h.get('VolumesFrom') or h.get('Links') or h.get('AutoRemove') or h.get('CapAdd') or h.get('CapDrop') or h.get('SecurityOpt') or h.get('ReadonlyRootfs') or h.get('Tmpfs') or h.get('NetworkMode', '').startswith('container:'):
    sys.exit('检测到特殊容器配置，为避免改变部署，请使用原部署工具更新。')
if any(cfg.get(key) != original_image.get(key) for key in ('Cmd', 'Entrypoint')):
    sys.exit('检测到自定义启动命令，为避免丢失设置，请使用原部署工具更新。')
args = ['run', '-d', '--name', 'vaultwarden']
restart = h.get('RestartPolicy', {})
policy = restart.get('Name') or 'no'
if policy == 'on-failure' and restart.get('MaximumRetryCount'):
    policy += ':' + str(restart['MaximumRetryCount'])
args += ['--restart', policy]
web_enabled = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else 'false'
for env in cfg.get('Env', []):
    if env.startswith('WEB_VAULT_ENABLED='):
        continue
    if not env.startswith('SIGNUPS_ALLOWED='):
        args += ['-e', env]
args += ['-e', 'WEB_VAULT_ENABLED=' + web_enabled]
# 保留现有注册环境变量；config.json（如存在）仍优先覆盖。
signups = next((e for e in cfg.get('Env', []) if e.startswith('SIGNUPS_ALLOWED=')), 'SIGNUPS_ALLOWED=false')
args += ['-e', signups]
for k, v in (cfg.get('Labels') or {}).items():
    if k.startswith('com.docker.compose.'):
        sys.exit('检测到 Compose 管理的容器，请通过原 Compose 文件更新。')
    args += ['--label', k + '=' + v]
for m in c.get('Mounts', []):
    if m['Type'] not in ('bind', 'volume'):
        sys.exit('不支持的挂载类型：' + m['Type'])
    source = m['Source'] if m['Type'] == 'bind' else m['Name']
    mode = m.get('Mode') or ('rw' if m.get('RW') else 'ro')
    args += ['-v', source + ':' + m['Destination'] + ':' + mode]
for port, bindings in (h.get('PortBindings') or {}).items():
    for b in bindings or []:
        ip = b.get('HostIp', '')
        if ':' in ip:
            ip = '[' + ip + ']'
        args += ['-p', (ip + ':' if ip else '') + b['HostPort'] + ':' + port]
mode = h.get('NetworkMode')
if mode and mode != 'default':
    args += ['--network', mode]
for n in networks.values():
    ipam = n.get('IPAMConfig') or {}
    if ipam.get('IPv4Address') or ipam.get('IPv6Address'):
        sys.exit('检测到固定容器 IP，请使用原部署工具更新。')
for host in h.get('ExtraHosts') or []:
    args += ['--add-host', host]
for dns in h.get('Dns') or []:
    args += ['--dns', dns]
for key, flag in [('User', '--user'), ('WorkingDir', '--workdir')]:
    if cfg.get(key):
        args += [flag, cfg[key]]
if h.get('Memory') or h.get('NanoCpus') or h.get('CpuQuota') or h.get('CpusetCpus'):
    sys.exit('检测到资源限制，请使用原部署工具更新。')
args.append(sys.argv[3])
with open(sys.argv[2], 'wb') as f:
    for a in args:
        f.write(a.encode() + b'\0')
PY
    then
        rm -rf -- "$tmp"; return 1
    fi
    local -a args=()
    mapfile -d '' -t args < "$tmp/args"
    rm -rf -- "$tmp"
    if [[ -z $web_enabled ]]; then docker pull "$image" || return 1; fi
    old="$(docker inspect --format '{{.Image}}' "$CONTAINER")" || return 1
    backup_app_unlocked || { echo "重建前完整数据备份失败，已取消操作。"; return 1; }
    local data_backup
    data_backup="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "$INSTALL_DIR/backup-db-baseline.json")" || return 1
    echo "更新前完整数据备份：$data_backup"
    backup="${CONTAINER}.before-update.$(date +%Y%m%d%H%M%S).$$"
    # 保留旧容器与旧镜像用于失败回滚；不删除密码库或清理 Docker 镜像。
    docker stop "$CONTAINER" || return 1
    if ! docker rename "$CONTAINER" "$backup"; then
        docker start "$CONTAINER" >/dev/null
        return 1
    fi
    if docker "${args[@]}" && verify_running; then
        if [[ -n $web_enabled ]]; then
            docker rm "$backup" || { echo '设置已应用，但本次临时旧容器清理失败。'; return 1; }
            echo "Web密码库设置已应用；完整数据备份：$data_backup"
        else
            echo "更新完成：$image；Vaultwarden 已启动。"
            echo "旧容器：$backup；旧镜像：$old；完整数据备份：$data_backup"
        fi
        return 0
    fi
    if [[ -n $web_enabled ]]; then
        # 同镜像开关重建可以安全恢复旧容器，不涉及版本/数据库降级。
        if container_exists; then docker rm -f "$CONTAINER" || return 1; fi
        docker rename "$backup" "$CONTAINER" || return 1
        docker start "$CONTAINER" >/dev/null || return 1
        echo 'Web开关应用失败，已恢复原容器。'
        return 1
    fi
    echo "更新失败；可能已迁移数据库，不自动回退旧镜像或数据库。"
    echo "完整数据备份：$data_backup；旧容器：$backup。请人工选择匹配版本恢复。"
    return 1
}

uninstall_app_unlocked() {
    local archive answer
    require_docker || return 1
    container_exists || { echo "未找到容器，未删除安装目录。"; return 1; }
    echo "正在打包"
    backup_app_unlocked || { echo "备份失败，禁止卸载。"; return 1; }
    archive="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "$INSTALL_DIR/backup-db-baseline.json")" || return 1
    echo "打包成功尝试传送：$archive"
    if ! /usr/bin/python3 /root/yingyong/vaultwarden-final-send.py "$archive"; then
        IFS= read -r -p "上述任务传送失败，仍继续卸载请输入小写 yes：" answer || return 1
        [[ "$answer" == yes ]] || { echo "已取消卸载，本地备份保留。"; return 1; }
    else
        echo "现有任务传送完成。"
    fi
    echo "正在卸载"
    docker rm -f "$CONTAINER" || return 1
    if container_exists; then echo "容器删除校验失败，安装目录未删除。"; return 1; fi
    rm -rf -- "$INSTALL_DIR" || return 1
    [[ ! -e "$INSTALL_DIR" ]] || { echo "安装目录未删除完成。"; return 1; }
    echo "卸载成功，本地备份保留：$archive"
}

login_hub() {
    require_docker || return 1
    echo "通过 Docker 官方交互登录 Docker Hub，不在脚本中保存密码。"
    docker login
}

push_image() {
    local source answer local_id remote_id tmp
    require_docker || return 1
    command -v python3 >/dev/null 2>&1 || { echo "推送验证需要 python3。"; return 1; }
    if container_exists; then
        source="$(docker inspect --format '{{.Image}}' "$CONTAINER")" || return 1
    else
        source="$OFFICIAL_IMAGE"
    fi
    docker image inspect "$source" >/dev/null 2>&1 || { echo "本地没有源镜像，请先安装或拉取 $OFFICIAL_IMAGE。"; return 1; }
    echo "将把本地镜像 $source 打标签并推送到 $CUSTOM_IMAGE。"
    echo "这会覆盖远端 latest 标签，需要 zaixiangjian 仓库推送权限。"
    IFS= read -r -p "确认推送请输入小写 yes：" answer || return 0
    [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
    docker tag "$source" "$CUSTOM_IMAGE" || return 1
    docker push "$CUSTOM_IMAGE" || return 1
    local_id="$(docker image inspect --format '{{.Id}}' "$CUSTOM_IMAGE")" || return 1
    tmp="$(mktemp)" || return 1
    if ! docker manifest inspect "$CUSTOM_IMAGE" > "$tmp"; then
        rm -f -- "$tmp"; echo "推送命令已完成，但读取远端清单失败，未确认远端内容。"; return 1
    fi
    remote_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("config",{}).get("digest",""))' "$tmp")"
    rm -f -- "$tmp"
    if [[ -z "$remote_id" || "$remote_id" != "$local_id" ]]; then
        echo "远端镜像摘要未匹配，不能确认推送结果。"; return 1
    fi
    echo "推送完成，远端镜像配置摘要已验证：$remote_id"
    echo "仅推送本机已有镜像的平台版本，不包含密码库挂载数据。"
}

RESTORE_DIRS=("/home" "$BACKUP_DIR" "/home/vaultwarden" "/home/web/密码")

check_data_mount() {
    local actual
    actual="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER")" || return 1
    if [[ "$actual" != "$INSTALL_DIR/data" ]]; then
        echo "容器 /data 实际挂载为 $actual，与 $INSTALL_DIR/data 不一致，已取消。"
        return 1
    fi
    [[ -d "$INSTALL_DIR/data" && ! -L "$INSTALL_DIR/data" ]] || { echo "数据目录不存在或为符号链接。"; return 1; }
}

backup_app_unlocked() {
    local archive
    require_docker || return 1
    command -v python3 >/dev/null || return 1
    container_exists || { echo "未找到 vaultwarden 容器。"; return 1; }
    check_data_mount || return 1
    mkdir -p "$BACKUP_DIR" || return 1
    VW_TEMP_ARCHIVE="$(mktemp "$BACKUP_DIR/.vaultwarden-partial.XXXXXX")" || return 1
    chmod 600 "$VW_TEMP_ARCHIVE" || return 1
    docker stop "$CONTAINER" >/dev/null || { echo "停止失败，未执行打包。"; return 1; }
    echo "容器已停止，正在备份完整 data 目录。"
    # Never publish tar output unless tar itself AND complete integrity checks succeed.
    if ! timeout --kill-after=10s 1800s tar -czpf "$VW_TEMP_ARCHIVE" -C "$INSTALL_DIR" data ||
       ! timeout --kill-after=10s 1800s gzip -t "$VW_TEMP_ARCHIVE" ||
       ! timeout --kill-after=10s 1800s tar -tzf "$VW_TEMP_ARCHIVE" >/dev/null ||
       ! timeout --kill-after=10s 1800s tar -dzf "$VW_TEMP_ARCHIVE" -C "$INSTALL_DIR" data; then
        echo "打包或完整校验失败，未发布正式备份。"; return 1
    fi
    while true; do
        archive="$BACKUP_DIR/mima_$(date +%Y%m%d%H%M%S).tar.gz"
        if ln -- "$VW_TEMP_ARCHIVE" "$archive" 2>/dev/null; then break; fi
        [[ -e "$archive" || -L "$archive" ]] || return 1
        sleep 1
    done
    # Baseline is captured after archive completion, while the container is stopped.
    if ! python3 - "$INSTALL_DIR" "$archive" <<'PYBASE'
import json, os, sys, tempfile, time, sqlite3, hashlib
from pathlib import Path
base = Path(sys.argv[1])
def signature(name):
    try:
        s = (base / 'data' / name).stat()
        return [s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
    except FileNotFoundError:
        return None
payload = {'db': [signature(n) for n in ('db.sqlite3', 'db.sqlite3-shm', 'db.sqlite3-wal')],
           'at': time.time(), 'archive': os.path.abspath(sys.argv[2])}
database = base / 'data' / 'db.sqlite3'
if database.exists():
    source = sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=15)
    snapshot = sqlite3.connect(':memory:')
    source.backup(snapshot)
    h = hashlib.sha256()
    for line in snapshot.iterdump(): h.update((line + '\n').encode())
    payload['logical_hash'] = h.hexdigest()
    snapshot.close(); source.close()
fd, tmp = tempfile.mkstemp(prefix='.backup-baseline-', dir=base)
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(payload, f); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, base / 'backup-db-baseline.json')
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PYBASE
    then
        rm -f -- "$archive"
        echo "基线记录失败，未保留本次正式备份。"; return 1
    fi
    rm -f -- "$VW_TEMP_ARCHIVE"
    VW_TEMP_ARCHIVE=
    echo "备份文件：$archive（0600）；基线已记录，随后启动容器。"
}

list_restore_files() {
    python3 - "${RESTORE_DIRS[@]}" <<'PY'
import os, re, sys
files = []
for directory in sys.argv[1:]:
    try:
        entries = os.scandir(directory)
    except FileNotFoundError:
        continue
    except OSError as e:
        sys.exit('读取备份目录失败：' + str(e))
    with entries:
        for entry in entries:
            match = re.fullmatch(r'mima_(\d{14})\.tar\.gz', entry.name)
            if match and entry.is_file(follow_symlinks=False):
                files.append((match[1], entry.path))
for _, path in sorted(files, reverse=True):
    sys.stdout.buffer.write(os.fsencode(path) + b'\0')
PY
}

extract_backup() {
    # 仅接收 data/ 下普通文件和目录，拒绝链接、特殊文件、重复路径和穿越。
    python3 - "$1" "$2" <<'PY'
import os, sys, tarfile
from pathlib import PurePosixPath
try:
    with tarfile.open(sys.argv[1], 'r:gz') as archive:
        members = archive.getmembers()
        seen = set()
        for m in members:
            parts = PurePosixPath(m.name).parts
            if (not parts or parts[0] != 'data' or '..' in parts or
                m.name.startswith('/') or not (m.isfile() or m.isdir()) or
                parts in seen):
                raise ValueError('非法归档成员：' + repr(m.name))
            seen.add(parts)
        if not members or not any(m.isfile() for m in members):
            raise ValueError('备份为空或没有文件')
        archive.extractall(sys.argv[2], members=members, filter='data')
except Exception as e:
    sys.exit('备份校验或解压失败：' + str(e))
PY
}

restore_app_unlocked() {
    local choice answer selected tmp listing stage before failed index fresh=no
    local -a files=()
    command -v python3 >/dev/null 2>&1 || { echo "恢复需要 python3。"; return 1; }
    listing="$(mktemp)" || return 1
    if ! list_restore_files > "$listing"; then rm -f -- "$listing"; return 1; fi
    mapfile -d '' -t files < "$listing"
    rm -f -- "$listing"
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "=================================="
    echo "可用的站点备份，检测路径"
    for tmp in "${RESTORE_DIRS[@]}"; do echo "$tmp"; done
    echo "=================================="
    if [[ ${#files[@]} -eq 0 ]]; then echo "未检测到 mima_时间戳.tar.gz 备份文件。"; return 0; fi
    for index in "${!files[@]}"; do echo "$((index + 1)). ${files[index]##*/}"; done
    IFS= read -r -p "请输入需要恢复的备份序号（回车默认最新，0 取消）:" choice || return 0
    [[ "$choice" != 0 ]] || { echo "已取消。"; return 0; }
    choice="${choice:-1}"
    if [[ ! "$choice" =~ ^[1-9][0-9]{0,8}$ ]] || (( choice > ${#files[@]} )); then
        echo "无效备份序号。"; return 1
    fi
    selected="${files[choice-1]}"
    echo "备份路径：$selected"
    echo "恢复目标：$INSTALL_DIR/data；将停止容器并替换整个 data 目录。"
    echo "旧数据仅临时保留用于失败回滚；恢复并启动成功后自动清理。"
    IFS= read -r -p "确认恢复请输入小写 yes：" answer || return 0
    [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
    require_docker || return 1
    if container_exists; then
        check_data_mount || return 1
    else
        fresh=yes
        VW_RECOVER_START=0
        echo "未发现容器：校验备份后，将使用官方镜像创建 vaultwarden，端口3280，禁止新注册。"
        IFS= read -r -p "确认创建并恢复请输入小写 yes：" answer || return 0
        [[ "$answer" == yes ]] || return 0
    fi
    [[ ! -L "$selected" && -f "$selected" ]] || { echo "备份文件不可用。"; return 1; }
    mkdir -p "$(dirname "$INSTALL_DIR")" || return 1
    stage="$(mktemp -d "${INSTALL_DIR}.restore-stage.XXXXXX")" || return 1
    if ! extract_backup "$selected" "$stage"; then rm -rf -- "$stage"; return 1; fi
    # 恢复安全策略：配置文件优先于环境变量，必须覆盖旧备份中的注册开关及白名单。
    if ! restore_disable_registration "$stage/data/config.json"; then rm -rf -- "$stage"; return 1; fi
    if [[ $fresh != yes ]]; then
        if ! ensure_web_closed update_app_unlocked; then rm -rf -- "$stage"; return 1; fi
    fi
    if [[ $fresh == yes ]]; then
        if ! docker pull "$OFFICIAL_IMAGE"; then rm -rf -- "$stage"; return 1; fi
        before="$(mktemp -d "${INSTALL_DIR}.before-restore.$(date +%Y%m%d%H%M%S).XXXXXX")" || { rm -rf -- "$stage"; return 1; }
        mkdir -p "$INSTALL_DIR" || { rm -rf -- "$stage"; return 1; }
        if [[ -L "$INSTALL_DIR" || -L "$INSTALL_DIR/data" ]]; then
            echo "恢复目标不能为符号链接。"; rm -rf -- "$stage"; return 1
        fi
        if [[ -e "$INSTALL_DIR/data" ]]; then
            mv -T -- "$INSTALL_DIR/data" "$before/data" || { rm -rf -- "$stage"; return 1; }
        fi
        if ! mv -T -- "$stage/data" "$INSTALL_DIR/data"; then
            [[ ! -e "$before/data" ]] || mv -T -- "$before/data" "$INSTALL_DIR/data"
            rm -rf -- "$stage"; return 1
        fi
        rmdir "$stage"
        if docker run -d --name "$CONTAINER" -e SIGNUPS_ALLOWED=false -e WEB_VAULT_ENABLED=false --restart always \
            -p 3280:80 -v "$INSTALL_DIR/data:/data" "$OFFICIAL_IMAGE" && verify_running; then
            rm -rf -- "$before" || { echo "恢复已成功，但临时旧数据清理失败：$before"; return 1; }
            echo "恢复完成并已创建容器：$selected"
            echo "数据目录：$INSTALL_DIR/data；端口3280；请配置原来的 HTTPS 反向代理。"
            return 0
        fi
        if container_exists; then
            if ! docker stop "$CONTAINER" >/dev/null; then
                echo "无法停止失败容器，旧数据保留在 $before/data，未回滚正在写入的目录。"; return 1
            fi
        fi
        failed="$(mktemp -d "${INSTALL_DIR}.failed-restore.XXXXXX")" || return 1
        mv -T -- "$INSTALL_DIR/data" "$failed/data" || return 1
        if [[ -e "$before/data" ]]; then
            mv -T -- "$before/data" "$INSTALL_DIR/data" || { echo "回滚失败，旧数据保留在 $before/data。"; return 1; }
        fi
        rmdir "$before" 2>/dev/null || true
        echo "创建/启动失败：已回滚恢复前的数据状态；失败恢复数据保留在 $failed/data。"
        echo "请检查端口占用及 docker logs vaultwarden；不会自动再次启动失败容器。"
        return 1
    fi

    before="$(mktemp -d "${INSTALL_DIR}.before-restore.$(date +%Y%m%d%H%M%S).XXXXXX")" || { rm -rf -- "$stage"; return 1; }
    if ! docker stop "$CONTAINER" >/dev/null; then
        rm -rf -- "$stage"; rmdir "$before"; echo "停止失败，数据未替换。"; return 1
    fi
    if ! mv -T -- "$INSTALL_DIR/data" "$before/data"; then
        rm -rf -- "$stage"; rmdir "$before"
        docker start "$CONTAINER" >/dev/null
        echo "保存原数据失败，已取消恢复。"; return 1
    fi
    if mv -T -- "$stage/data" "$INSTALL_DIR/data"; then
        rmdir "$stage"
        if docker start "$CONTAINER" >/dev/null && verify_running; then
            rm -rf -- "$before" || { echo "恢复已成功，但临时旧数据清理失败：$before"; return 1; }
            echo "恢复完成：$selected"
            echo "Vaultwarden 已启动"
            return 0
        fi
        # 必须确认新数据的写入者已停止，才可回滚数据目录。
        if ! docker stop "$CONTAINER" >/dev/null; then
            echo "启动失败且无法停止容器，未移动正在使用的数据；原数据保留在 $before/data。"; return 1
        fi
    else
        rm -rf -- "$stage"
    fi
    failed="$(mktemp -d "${INSTALL_DIR}.failed-restore.XXXXXX")" || { echo "原数据保留在 $before/data。"; return 1; }
    if [[ -e "$INSTALL_DIR/data" ]] && ! mv -T -- "$INSTALL_DIR/data" "$failed/data"; then
        echo "无法移走失败数据，原数据保留在 $before/data。"; return 1
    fi
    if ! mv -T -- "$before/data" "$INSTALL_DIR/data"; then
        echo "回滚失败，原数据保留在 $before/data。"; return 1
    fi
    rmdir "$before" 2>/dev/null || true
    docker start "$CONTAINER" >/dev/null && verify_running || { echo "原数据已恢复，但容器启动失败。"; return 1; }
    echo "恢复失败，已回滚原数据；失败数据保留位置：$failed"
    return 1
}

restore_disable_registration() {
    python3 - "$1" <<'PY_RESTORE_REG'
import json,os,sys,tempfile
from pathlib import Path
p=Path(sys.argv[1])
if p.is_symlink():sys.exit('恢复配置不能为符号链接')
cfg=json.loads(p.read_text()) if p.exists() else {}
if not isinstance(cfg,dict):sys.exit('恢复配置格式无效')
st=p.stat() if p.exists() else p.parent.stat()
cfg['signups_allowed']=False
cfg['signups_domains_whitelist']=''
fd,tmp=tempfile.mkstemp(prefix='.restore-registration-',dir=p.parent)
try:
 with os.fdopen(fd,'w') as f:
  os.fchown(f.fileno(),st.st_uid,st.st_gid)
  os.fchmod(f.fileno(),(st.st_mode & 0o777) if p.exists() else 0o600)
  json.dump(cfg,f,ensure_ascii=False,indent=2);f.flush();os.fsync(f.fileno())
 os.replace(tmp,p)
finally:
 if os.path.exists(tmp):os.unlink(tmp)
PY_RESTORE_REG
}

registration_config() {
    # 输出受验证的状态及配置文件路径，不输出其他配置或密钥。
    local inspect_file rc
    inspect_file="$(mktemp)" || return 1
    if ! docker inspect "$CONTAINER" > "$inspect_file" 2>/dev/null; then rm -f -- "$inspect_file"; return 1; fi
    python3 - "$inspect_file" <<'PY'
import json, os, sys
try:
    c = json.load(open(sys.argv[1]))[0]
    env = dict(e.split('=', 1) for e in c['Config'].get('Env', []) if '=' in e)
    folder = env.get('DATA_FOLDER', '/data').rstrip('/')
    path = env.get('CONFIG_FILE', folder + '/config.json')
    if not path.startswith('/'):
        work = c['Config'].get('WorkingDir') or '/'
        path = os.path.normpath(work + '/' + path)
    mounts = sorted(c.get('Mounts', []), key=lambda m: len(m['Destination']), reverse=True)
    mount = next((m for m in mounts if path.startswith(m['Destination'].rstrip('/') + '/')), None)
    if not mount or mount['Type'] != 'bind' or not mount.get('RW', True):
        raise ValueError('配置文件不在可写 bind 挂载内')
    host = os.path.join(mount['Source'], os.path.relpath(path, mount['Destination']))
    if os.path.realpath(host) != os.path.abspath(host):
        raise ValueError('配置路径包含符号链接')
    cfg = {}
    if os.path.exists(host):
        with open(host) as f: cfg = json.load(f)
        if not isinstance(cfg, dict): raise ValueError('配置格式异常')
    value = cfg.get('signups_allowed')
    if value is None:
        raw = env.get('SIGNUPS_ALLOWED', 'true').lower()
        if raw not in ('true', 'false', '1', '0'): raise ValueError('无效布尔值')
        value = raw in ('true', '1')
    if not isinstance(value, bool): raise ValueError('无效布尔值')
    whitelist = cfg.get('signups_domains_whitelist')
    if whitelist is None: whitelist = env.get('SIGNUPS_DOMAINS_WHITELIST', '')
    if not isinstance(whitelist, str): raise ValueError('白名单格式异常')
    print('restricted' if whitelist.strip() else ('true' if value else 'false'))
    print(host)
except Exception as e:
    print('注册配置检测失败：' + str(e), file=sys.stderr)
    sys.exit(1)
PY
    rc=$?
    rm -f -- "$inspect_file"
    return "$rc"
}

show_registration_status() {
    local result state
    result="$(registration_config 2>/dev/null)" || result="unknown"
    state="${result%%$'\n'*}"
    if [[ "${1:-}" == inline ]]; then
        printf '5. 配置管理（'
    elif [[ "${1:-}" != bare ]]; then
        echo "状态"
    fi
    case "$state" in
        false) printf '\033[31m🔴 禁止注册\033[0m' ;;
        true) printf '\033[32m🟢 允许注册\033[0m' ;;
        restricted) printf '\033[32m🟢 允许注册（仅限邮箱域名白名单）\033[0m' ;;
        *) printf '\033[33m🟡 检测失败\033[0m' ;;
    esac
    if [[ "${1:-}" == inline ]]; then
        printf ' '
        show_smtp_status
        printf '）'
    fi
    printf '\n'
}

set_registration_unlocked() {
    local value="$1" result file running work existed=false backup
    require_docker || return 1
    command -v python3 >/dev/null 2>&1 || { echo "注册管理需要 python3。"; return 1; }
    result="$(registration_config)" || return 1
    file="${result#*$'\n'}"
    running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" || return 1
    work="$(mktemp -d "${INSTALL_DIR}.registration.XXXXXX")" || return 1
    if ! docker stop "$CONTAINER" >/dev/null; then rm -rf -- "$work"; echo "停止失败，配置未修改。"; return 1; fi
    result="$(registration_config)" || { rm -rf -- "$work"; return 1; }
    file="${result#*$'\n'}"
    backup="$work/original.json"
    if [[ -e "$file" ]]; then
        existed=true
        cp -p -- "$file" "$backup" || { rm -rf -- "$work"; return 1; }
    fi
    if ! python3 - "$file" "$work/new.json" "$value" <<'PY'
import json, os, sys
from pathlib import Path
p = Path(sys.argv[1])
cfg = json.loads(p.read_text()) if p.exists() else {}
cfg['signups_allowed'] = sys.argv[3] == 'true'
# 白名单可覆盖禁止注册，两个模式均清空该项以落实全局开/关。
cfg['signups_domains_whitelist'] = ''
new = Path(sys.argv[2])
new.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n')
if p.exists():
    stat = p.stat()
    os.chmod(new, stat.st_mode & 0o777)
    os.chown(new, stat.st_uid, stat.st_gid)
else:
    os.chmod(new, 0o600)
PY
    then rm -rf -- "$work"; return 1; fi
    if mv -T -- "$work/new.json" "$file"; then
        if docker start "$CONTAINER" >/dev/null && verify_running; then
            result="$(registration_config)" || result="unknown"
            if [[ "${result%%$'\n'*}" == "$value" ]]; then
                echo "注册设置已修改，Vaultwarden 已启动"
                if [[ "$existed" == true ]]; then
                    echo "修改前配置保留在：$backup"
                else
                    rmdir "$work"
                fi
                show_registration_status
                echo "只控制普通自行注册，不影响现有账户或邀请注册；如开启 SSO，请另检查其注册策略。"
                return 0
            fi
        fi
        if ! docker stop "$CONTAINER" >/dev/null; then
            echo "无法停止容器，未继续回滚；原配置保留位置：$work"; return 1
        fi
    fi
    if [[ "$existed" == true ]]; then
        cp -p -- "$backup" "$work/rollback.json" && mv -T -- "$work/rollback.json" "$file" || { echo "配置回滚失败：$backup"; return 1; }
    else
        rm -f -- "$file" || return 1
    fi
    if true; then
        docker start "$CONTAINER" >/dev/null && verify_running || { echo "配置已回滚，但容器启动失败。"; return 1; }
    fi
    echo "切换失败，已回滚；临时配置目录：$work"
    return 1
}

ensure_mail_python() {
    local python_version
    echo "正在检查 Python 3..."
    if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import json, pathlib, subprocess, getpass, fcntl' >/dev/null 2>&1; then
        python_version="$(/usr/bin/python3 --version 2>&1)" || return 1
        echo "Python 3已安装：$python_version"
        return 0
    fi
    [[ $EUID -eq 0 ]] || { echo "缺少 Python 3，请使用 root 运行以自动安装。"; return 1; }
    echo "未检测到可用的 /usr/bin/python3，正在安装 Python 3..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 || return 1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm python || return 1
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3 || return 1
    else
        echo "不支持自动安装的包管理器，请手动安装 Python 3。"
        return 1
    fi
    if ! /usr/bin/python3 -c 'import json, pathlib, subprocess, getpass, fcntl' >/dev/null 2>&1; then
        echo "Python 3 安装后校验失败，未执行 SMTP 配置。"
        return 1
    fi
    echo "Python 3 已安装并通过校验。"
}

configure_smtp() {
    ensure_mail_python || { echo "Python 3 不可用，SMTP 配置未修改。"; return 1; }
    /usr/bin/python3 /root/yingyong/vaultwarden-mail.py smtp
}

show_smtp_status() {
    local status
    status="$(/usr/bin/python3 /root/yingyong/vaultwarden-mail.py status 2>/dev/null)" || status=unknown
    case "$status" in
        smtp) printf '\033[32m有SMTP\033[0m' ;;
        none) printf '\033[31m无SMTP\033[0m' ;;
        *) printf '\033[33mSMTP检测失败\033[0m' ;;
    esac
}

registration_menu() {
    local choice answer
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "=================================="
    echo "        vaultwarden 配置管理"
    echo "注册状态"
    show_registration_status bare
    echo "------------------------"
    echo "邮件状态"
    show_smtp_status
    echo
    echo "=================================="
    echo "1. 开启注册"
    echo "2. 禁止注册"
    echo "3. 添加 SMTP 配置"
    echo "0. 返回"
    IFS= read -r -p "请输入选项：" choice || return 0
    case "$choice" in
        1|2)
            echo "将清空邮箱域名注册白名单，并启动容器。"
            [[ "$choice" != 1 ]] || echo "警告：开启后可自行创建账户，请完成注册后及时禁止。"
            IFS= read -r -p "确认修改请输入小写 yes：" answer || return 0
            [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
            if [[ "$choice" == 1 ]]; then set_registration true; else set_registration false; fi
            ;;
        3) configure_smtp ;;
        0) return 0 ;;
        *) echo "无效选项。" ;;
    esac
}

repair_background_tasks() {
    local rc=0
    /usr/bin/python3 /root/yingyong/vaultwarden-lifecycle.py gate || rc=$?
    [[ "$rc" != 3 ]] || return 0
    [[ "$rc" == 0 ]] || return 1
    ssh_backup_repair || return 1
    /usr/bin/python3 /root/yingyong/vaultwarden-s3.py repair
}

ssh_backup_repair() {
    [[ -f /root/yingyong/vaultwarden-ssh.py ]] || { echo "缺少 SSH 备份辅助程序。"; return 1; }
    python3 /root/yingyong/vaultwarden-ssh.py repair || { echo "SSH systemd 修复失败，请检查配置和服务日志。"; return 1; }
}

ssh_backup_summary() {
    python3 /root/yingyong/vaultwarden-ssh.py "${1:-summary}" || {
        echo "SSH备份"
        printf '\033[33m检测异常\033[0m\n'
        echo "------------------------"
        echo "传送任务"
        printf '\033[33m检测异常\033[0m\n'
    }
}

show_backup_logs() {
    echo "=================================="
    echo "SSH 监控、打包及传送日志（最近50行）"
    /usr/bin/python3 - "$INSTALL_DIR/ssh-backup.log" <<'PY'
from collections import deque
from pathlib import Path
import sys
p = Path(sys.argv[1])
if p.exists():
    with p.open(errors='replace') as f:
        print(''.join(deque(f, maxlen=50)), end='')
else:
    print('暂无SSH监控日志。')
PY
    echo "------------------------"
    echo "S3 上传、校验及清理日志（最近50条）"
    journalctl -u vaultwarden-s3-backup.service -u vaultwarden-s3-daily.service -n 50 --no-pager -o short-iso || echo "读取S3日志失败。"
    echo "------------------------"
    echo "SSH 每日兜底及服务异常日志（最近50条）"
    journalctl -u vaultwarden-ssh-daily-backup.service -u vaultwarden-ssh-daily-transfer.service -u vaultwarden-ssh-backup.service -u vaultwarden-ssh-backup-health.service -n 50 --no-pager -o short-iso || echo "读取systemd日志失败。"
    echo "=================================="
}

ssh_backup_menu() {
    local choice
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        SSH 远程备份配置"
        echo "一个打包流程，多任务传送；本地保留最新 10 个，远端不清理"
        echo "=================================="
        ssh_backup_summary summary-numbered
        echo "=================================="
        echo "1. 添加SSH备份任务"
        echo "2. 添加传送任务"
        echo "5. 查看监控日志"
        echo "9. 删除传送任务"
        echo "0. 返回"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) python3 /root/yingyong/vaultwarden-ssh.py add-backup && ssh_backup_repair ;;
            2) python3 /root/yingyong/vaultwarden-ssh.py add-transfer && ssh_backup_repair ;;
            5) show_backup_logs ;;
            9) python3 /root/yingyong/vaultwarden-ssh.py delete && ssh_backup_repair ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

s3_backup_menu() {
    local choice
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        S3 API 兼容备份配置"
        echo "共用本地备份；仅传最新；远端专用前缀保留${S3_RETENTION_COUNT}个"
        echo "=================================="
        ssh_backup_summary summary-numbered
        echo "=================================="
        echo "1. 添加S3任务"
        echo "2. 查看S3任务"
        echo "5. 查看监控日志"
        echo "9. 删除S3任务"
        echo "0. 返回"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) /usr/bin/python3 /root/yingyong/vaultwarden-s3.py add && /usr/bin/python3 /root/yingyong/vaultwarden-s3.py repair ;;
            2) /usr/bin/python3 /root/yingyong/vaultwarden-s3.py list ;;
            5) show_backup_logs ;;
            9) /usr/bin/python3 /root/yingyong/vaultwarden-s3.py delete && /usr/bin/python3 /root/yingyong/vaultwarden-s3.py repair ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

ensure_web_closed() {
    local image value
    require_docker || return 1
    container_exists || return 0
    value=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" | python3 -c 'import sys; v=[s.strip().split("=",1)[1].lower() for s in sys.stdin if s.startswith("WEB_VAULT_ENABLED=")]; print(v[-1] if v else "true")') || return 1
    [[ $value == false || $value == 0 || $value == no || $value == off ]] && return 0
    echo '默认安全策略：使用当前镜像关闭Web密码库，将备份并重建容器。'
    image=$(docker inspect --format '{{.Image}}' "$CONTAINER") || return 1
    "${1:-update_app}" "$image" false
}

show_web_vault_action() {
    local state color='' reset=''
    state=$(python3 - "$CONTAINER" <<'PY_WEB_STATE'
import json,subprocess,sys
try:
 x=json.loads(subprocess.check_output(['docker','inspect',sys.argv[1]],stderr=subprocess.DEVNULL,text=True))[0]
 values=[e.split('=',1)[1].lower() for e in x['Config'].get('Env',[]) if e.startswith('WEB_VAULT_ENABLED=')]
 value=values[-1] if values else 'true'
 print('closed' if value in ('false','0','no','off') else 'open' if value in ('true','1','yes','on') else 'unknown')
except Exception:print('unknown')
PY_WEB_STATE
    )
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        reset=$'\033[0m'
        case $state in closed) color=$'\033[32m';; open) color=$'\033[31m';; *) color=$'\033[33m';; esac
    fi
    case $state in
        closed) printf '8. Web网页访问密码库管理（%s关闭网页访问%s）\n' "$color" "$reset" ;;
        open) printf '8. Web网页访问密码库管理（%s开启网页访问%s）\n' "$color" "$reset" ;;
        *) printf '8. Web网页访问密码库管理（%s状态未知/未安装%s）\n' "$color" "$reset" ;;
    esac
}

web_vault_menu() {
    local choice enabled image answer
    require_docker && container_exists || { echo '请先安装Vaultwarden。'; return 1; }
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo '=================================='
    echo 'Web网页访问密码库管理'
    echo '仅关闭网页密码库；API、客户端同步和/admin不因此关闭，不代替HTTPS或访问控制。'
    echo '=================================='
    echo '1. 关闭Web密码库（WEB_VAULT_ENABLED=false）'
    echo '2. 开启Web密码库（WEB_VAULT_ENABLED=true）'
    echo '------------------------'
    echo '0. 返回'
    echo '------------------------'
    IFS= read -r -p '请输入选项：' choice || return 0
    case "$choice" in 1) enabled=false ;; 2) enabled=true ;; 0) return 0 ;; *) echo '无效选项'; return 1 ;; esac
    echo '将使用当前镜像备份数据并重建容器，短暂中断服务，不拉取新版本。'
    IFS= read -r -p '确认请输入小写yes：' answer || return 0
    [[ $answer == yes ]] || return 0
    image=$(docker inspect --format '{{.Image}}' "$CONTAINER") || return 1
    update_app "$image" "$enabled" || return 1
    python3 - "$CONTAINER" "$enabled" <<'PY_WEB_VERIFY'
import json,subprocess,sys
x=json.loads(subprocess.check_output(['docker','inspect',sys.argv[1]],text=True))[0]
values=[v for v in x['Config'].get('Env',[]) if v.startswith('WEB_VAULT_ENABLED=')]
if values!=['WEB_VAULT_ENABLED='+sys.argv[2]]:sys.exit('环境变量读回不一致，请检查容器')
print('容器配置已验证：'+values[0]+'；请另行确认网页访问效果。')
PY_WEB_VERIFY
}

show_menu() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "=================================="
    echo "        vaultwarden 管理脚本"
    echo "开源密码库服务端（禁止注册，无 SMTP 设置）"
    echo "开源地址："
    echo "https://github.com/dani-garcia/vaultwarden"
    echo "=================================="
    ssh_backup_summary
    echo "=================================="
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份"
    echo "4. 恢复"
    show_registration_status inline
    echo "6. SSH 远程备份配置"
    echo "7. S3 API 兼容备份配置"
    show_web_vault_action
    echo "9. 卸载"
    echo "------------------------"
    echo "21. 自己安装zaixiangjian/vaultwarden:latest"
    echo "22. 从zaixiangjian更新"
    echo "23. 登录 Docker Hub"
    echo "24. 打上标签推送到zaixiangjian/vaultwarden:latest"
    echo "------------------------"
    echo "0. 退出"
}

repair_dependencies() {
    local tool manager
    local -a missing=() packages=()
    for tool in sshpass rsync ssh scp python3 flock timeout tar gzip; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if ! [[ -x /usr/bin/python3 ]] || ! /usr/bin/python3 -c 'import sys,json,pathlib,fcntl,subprocess; assert sys.version_info >= (3,9)' >/dev/null 2>&1; then
        [[ " ${missing[*]} " == *" python3 "* ]] || missing+=(python3)
    fi
    [[ ${#missing[@]} -gt 0 ]] || return 0
    [[ $EUID -eq 0 ]] || { echo "缺少依赖：${missing[*]}；请使用 root 运行以自动安装。" >&2; return 1; }
    if command -v apt-get >/dev/null 2>&1; then manager=apt
    elif command -v dnf >/dev/null 2>&1; then manager=dnf
    elif command -v yum >/dev/null 2>&1; then manager=yum
    elif command -v apk >/dev/null 2>&1; then manager=apk
    else echo "缺少依赖：${missing[*]}；无法识别包管理器，请手动安装。" >&2; return 1
    fi
    for tool in "${missing[@]}"; do
        case "$tool" in
            ssh|scp) [[ $manager == apt || $manager == apk ]] && packages+=(openssh-client) || packages+=(openssh-clients) ;;
            flock) packages+=(util-linux) ;;
            timeout) packages+=(coreutils) ;;
            crontab) [[ $manager == apt ]] && packages+=(cron) || { [[ $manager == apk ]] && packages+=(dcron) || packages+=(cronie); } ;;
            *) packages+=("$tool") ;;
        esac
    done
    echo "缺少 ${missing[*]}，正在自动安装..."
    case "$manager" in
        apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" || return 1 ;;
        dnf) dnf install -y -q "${packages[@]}" || return 1 ;;
        yum) yum install -y -q "${packages[@]}" || return 1 ;;
        apk) apk add --no-cache "${packages[@]}" || return 1 ;;
    esac
    for tool in "${missing[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || { echo "依赖安装后校验失败：$tool" >&2; return 1; }
    done
    /usr/bin/python3 -c 'import sys,json,pathlib,fcntl,subprocess; assert sys.version_info >= (3,9)' >/dev/null 2>&1 || {
        echo "系统 Python 3 不可用或低于3.9，未启动菜单任务，请升级系统Python。" >&2
        return 1
    }
}

main() {
    local choice
    repair_dependencies || { echo "依赖自动修复失败。" >&2; return 1; }
    export VW_STATUS_CACHE
    VW_STATUS_CACHE="$(mktemp)" || return 1
    printf '{}' > "$VW_STATUS_CACHE"
    trap 'rm -f -- "$VW_STATUS_CACHE"' EXIT
    repair_background_tasks || echo "后台任务修复异常，未将检测失败当作未安装。"
    if /usr/bin/python3 /root/yingyong/vaultwarden-lifecycle.py installed; then
        python3 /root/yingyong/vaultwarden-ssh.py check-connections || echo "连接检测异常。"
    fi
    while true; do
        show_menu
        IFS= read -r -p "请输入选项：" choice || { echo "已退出"; return 0; }
        case "$choice" in
            1) install_app "$OFFICIAL_IMAGE" ;;
            2) update_app "$OFFICIAL_IMAGE" ;;
            3) ensure_web_closed && backup_app ;;
            4) restore_app ;;
            5) registration_menu ;;
            6) ssh_backup_menu ;;
            7) s3_backup_menu ;;
            8) web_vault_menu ;;
            9) uninstall_app ;;
            21) install_app "$CUSTOM_IMAGE" ;;
            22) update_app "$CUSTOM_IMAGE" ;;
            23) login_hub ;;
            24) push_image ;;
            0) echo "已退出"; return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

# 单文件发布：helpers 为下方可读源码；只在直接运行时释放，不在 source 时写入。
singlefile_python_ready() {
    /usr/bin/python3 -c 'import sys,fcntl; assert sys.version_info >= (3,9)' >/dev/null 2>&1 && return 0
    [[ $EUID == 0 ]] || { echo '自动释放需要 root 和 Python >=3.9' >&2; return 1; }
    echo '正在安装单文件启动依赖 Python 3...' >&2
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 || return 1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q python3 || return 1
    elif command -v yum >/dev/null 2>&1; then yum install -y -q python3 || return 1
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache python3 || return 1
    else echo '请安装 Python >=3.9 后重试' >&2; return 1; fi
    /usr/bin/python3 -c 'import sys,fcntl; assert sys.version_info >= (3,9)' >/dev/null 2>&1
}
singlefile_bootstrap() {
    singlefile_python_ready || return 1
    /usr/bin/python3 - "${BASH_SOURCE[0]}" 'vaultwarden.sh' <<'SINGLEFILE_INSTALLER_PY'
import os,sys,stat,fcntl,re,tempfile,subprocess
from pathlib import Path
if os.geteuid()!=0: raise SystemExit('单文件释放请使用 root 运行')
os.umask(0o077)
canonical=Path('/root/yingyong')

def open_components(path, create=False):
    path=Path(os.path.abspath(path))
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            if create:
                try: os.mkdir(part,0o700,dir_fd=fd)
                except FileExistsError: pass
            nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=nxt
            st=os.fstat(fd)
            if create and (st.st_uid!=0 or st.st_mode&0o022):
                raise ValueError('发布目录必须 root 所有且不可被其他用户写入')
        return fd
    except BaseException:
        os.close(fd);raise

def read_regular(fd,name):
    f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
    try:
        st=os.fstat(f)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_mode&0o022:
            raise ValueError('源码/目标必须为 root 所有的安全普通文件: '+name)
        with os.fdopen(os.dup(f),'rb') as stream: return stream.read(),stat.S_IMODE(st.st_mode)
    finally: os.close(f)

source=Path(os.path.abspath(sys.argv[1]))
sfd=open_components(source.parent)
try: source_bytes,_=read_regular(sfd,source.name)
finally: os.close(sfd)
text=source_bytes.decode('utf-8')
files={}
for match in re.finditer(r'^# SINGLEFILE_HELPER ([a-z0-9-]+\.py) (SINGLEFILE_SOURCE_[A-Z0-9_]+)\n    cat <<\x27\2\x27\n(.*?)^\2\n',text,re.M|re.S):
    name,delimiter,body=match.groups()
    if name in files: raise ValueError('重复嵌入helper')
    compile(body,name,'exec')
    files[name]=body.encode('utf-8')
expected=['vaultwarden-ssh.py', 'vaultwarden-s3.py', 'vaultwarden-mail.py', 'vaultwarden-lifecycle.py', 'vaultwarden-final-send.py']
if set(files)!=set(expected): raise ValueError('嵌入helper集合不完整')
files[sys.argv[2]]=source_bytes
rootfd=open_components(canonical,create=True)
os.fchmod(rootfd,0o700)
lockfd=os.open('.singlefile-bootstrap.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600,dir_fd=rootfd)
st=os.fstat(lockfd)
if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_nlink!=1 or st.st_mode&0o077:
    raise ValueError('bootstrap锁文件不安全')
fcntl.flock(lockfd,fcntl.LOCK_EX)
staged={};old={};published=[]
try:
    # 先校验所有目标、编译全部源码、准备全部同目录临时文件，再开始发布。
    for name,data in files.items():
        try: before,mode=read_regular(rootfd,name)
        except FileNotFoundError: before,mode=None,None
        old[name]=(before,mode)
        if before==data and mode==0o700: continue
        fd,tmp=tempfile.mkstemp(prefix='.singlefile-stage-',dir=canonical)
        try:
            os.fchmod(fd,0o700)
            with os.fdopen(fd,'wb') as stream:
                stream.write(data);stream.flush();os.fsync(stream.fileno())
        except BaseException:
            os.unlink(tmp);raise
        staged[name]=tmp
    check=staged.get(sys.argv[2]) or str(canonical/sys.argv[2])
    subprocess.run(['bash','-n',check],check=True)
    for name,tmp in staged.items():
        os.replace(tmp,name,dst_dir_fd=rootfd);published.append(name)
    os.fsync(rootfd)
except BaseException:
    # 可捕获的发布错误恢复旧版本，不删除用户数据/配置。
    for name in reversed(published):
        data,mode=old[name]
        if data is None: os.unlink(name,dir_fd=rootfd)
        else:
            fd,tmp=tempfile.mkstemp(prefix='.singlefile-rollback-',dir=canonical)
            with os.fdopen(fd,'wb') as stream:
                os.fchmod(stream.fileno(),mode);stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.replace(tmp,name,dst_dir_fd=rootfd)
    raise
finally:
    for tmp in staged.values():
        try: os.unlink(tmp)
        except FileNotFoundError: pass
    os.close(lockfd);os.close(rootfd)
SINGLEFILE_INSTALLER_PY
}

# 内嵌源码：不要只修改已释放 .py；再次分发前应同步这里的最新版。
singlefile_embedded_sources() {
# SINGLEFILE_HELPER vaultwarden-ssh.py SINGLEFILE_SOURCE_VAULTWARDEN_SSH_PY
    cat <<'SINGLEFILE_SOURCE_VAULTWARDEN_SSH_PY'
#!/usr/bin/env python3
"""Vaultwarden: single debounced backup producer, multiple SSH consumers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time

SCRIPT = Path('/root/yingyong/vaultwarden.sh')


def read_settings():
    command = r'source "$1"; printf "%s\0" "$INSTALL_DIR" "$BACKUP_DIR" "$QUIET_SECONDS" "$DAILY_BACKUP_TIME" "$DAILY_TRANSFER_TIME" "$S3_RETENTION_COUNT" "$TRANSFER_RETRY_SECONDS" "$TRANSFER_MAX_ATTEMPTS"'
    result = subprocess.run(['bash', '-c', command, 'settings', str(SCRIPT)],
                            capture_output=True, check=True, timeout=10)
    values = result.stdout.decode().split('\0')[:-1]
    if len(values) != 8:
        raise ValueError('顶部配置读取失败')
    install, backup, quiet, daily_backup, daily_transfer, retention, retry, attempts = values
    if not retry.isdigit() or not 1 <= int(retry) <= 86400:
        raise ValueError("TRANSFER_RETRY_SECONDS 必须是 1~86400 秒的整数")
    if not attempts.isdigit() or not 1 <= int(attempts) <= 10000:
        raise ValueError("TRANSFER_MAX_ATTEMPTS 必须是正整数")
    if not retention.isdigit() or not 1 <= int(retention) <= 100000:
        raise ValueError("S3_RETENTION_COUNT 必须是正整数")
    if not install.startswith('/') or not backup.startswith('/'):
        raise ValueError('安装和备份目录必须为绝对路径')
    if not quiet.isdigit() or not 1 <= int(quiet) <= 3600:
        raise ValueError('QUIET_SECONDS 必须是 1~3600 秒的整数')
    for value in (daily_backup, daily_transfer):
        if not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', value):
            raise ValueError('每日时间必须为 HH:MM')
    return values


SETTINGS = read_settings()
BASE = Path(SETTINGS[0])
BACKUPS = Path(SETTINGS[1])
QUIET_SECONDS = int(SETTINGS[2])
DAILY_BACKUP_TIME, DAILY_TRANSFER_TIME = SETTINGS[3:5]
S3_RETENTION_COUNT = int(SETTINGS[5])
TRANSFER_RETRY_SECONDS = int(SETTINGS[6])
TRANSFER_MAX_ATTEMPTS = int(SETTINGS[7])

CONFIG = BASE / 'ssh-backup.json'
STATE = BASE / 'ssh-backup-state.json'
PATTERN = re.compile(r'mima_(\d{14})\.tar\.gz')


def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def load(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def signature(path):
    try:
        s = path.stat()
        return [s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
    except FileNotFoundError:
        return None


def db_signature():
    return [signature(BASE / 'data' / name) for name in
            ('db.sqlite3', 'db.sqlite3-shm', 'db.sqlite3-wal')]


def logical_db_hash():
    import sqlite3
    source = sqlite3.connect((BASE / 'data' / 'db.sqlite3').as_uri() + '?mode=ro',
                             uri=True, timeout=15)
    snapshot = sqlite3.connect(':memory:')
    try:
        source.backup(snapshot)
        h = hashlib.sha256()
        for line in snapshot.iterdump():
            h.update((line + '\n').encode())
        return h.hexdigest()
    finally:
        snapshot.close()
        source.close()


class Debounce:
    def __init__(self, baseline):
        self.baseline = baseline
        self.latest = baseline
        self.changed_at = None

    def ready(self, current, now):
        if current != self.latest:
            self.latest = current
            self.changed_at = now
        return (self.changed_at is not None and
                current != self.baseline and now - self.changed_at >= QUIET_SECONDS)

    def reset(self, current):
        self.baseline = self.latest = current
        self.changed_at = None


def archives():
    if not BACKUPS.exists():
        return []
    return sorted((p for p in BACKUPS.iterdir()
                   if PATTERN.fullmatch(p.name) and p.is_file() and not p.is_symlink()),
                  key=lambda p: p.name, reverse=True)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def valid_archive(path):
    try:
        # Reading all member data catches truncated gzip streams, not just headers.
        with tarfile.open(path, 'r:gz') as t:
            members = t.getmembers()
            if not members:
                return False
            for m in members:
                parts = Path(m.name).parts
                if not parts or parts[0] != 'data' or '..' in parts or m.name.startswith('/'):
                    return False
                if not (m.isdir() or m.isfile()):
                    return False
                if m.isfile():
                    with t.extractfile(m) as f:
                        while f.read(1024 * 1024):
                            pass
        return True
    except (OSError, EOFError, tarfile.TarError):
        return False


def ssh_args(task, batch=True):
    password_mode = task.get('auth', 'key') == 'password'
    args = ['ssh', '-p', str(task['port']),
            '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3']
    if password_mode:
        args += ['-o', 'BatchMode=no', '-o', 'PubkeyAuthentication=no',
                 '-o', 'PreferredAuthentications=password,keyboard-interactive',
                 '-o', 'KbdInteractiveAuthentication=yes', '-o', 'NumberOfPasswordPrompts=1']
    else:
        args += ['-i', task['key']]
        if batch:
            args += ['-o', 'BatchMode=yes']
    return args + [task['user'] + '@' + task['host']]


def run_ssh(task, command, *, stdin=None, first=False, timeout=600):
    import shutil
    import stat
    args = ssh_args(task)
    if first:
        args[args.index('StrictHostKeyChecking=yes')] = 'StrictHostKeyChecking=ask'
        if 'BatchMode=yes' in args:
            args[args.index('BatchMode=yes')] = 'BatchMode=no'
    fd = None
    try:
        if task.get('auth', 'key') == 'password':
            if not shutil.which('sshpass'):
                raise RuntimeError('密码认证需要 sshpass，请先安装：apt install sshpass（或 dnf install sshpass）')
            # Read the protected credential through an inherited fd, not argv or env.
            fd = os.open(task['password_file'], os.O_RDONLY | os.O_NOFOLLOW)
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o077:
                raise RuntimeError('密码文件必须为 root 所有且权限 0600')
            args = ['sshpass', '-d', str(fd), *args]
        if first and fd is not None:
            # Trust prompt uses regular SSH, with password auth disabled.
            probe = ssh_args({**task, 'auth': 'key', 'key': '/dev/null'})
            probe[probe.index('StrictHostKeyChecking=yes')] = 'StrictHostKeyChecking=ask'
            probe[probe.index('BatchMode=yes')] = 'BatchMode=no'
            destination = probe.pop()
            probe += ['-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no', destination]
            subprocess.run(probe + ['true'], check=False)
            args = ['sshpass', '-d', str(fd), *ssh_args(task)]
        result = subprocess.run(args + [command], stdin=stdin,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, text=True, pass_fds=(() if fd is None else (fd,)))
        if result.returncode:
            stderr = result.stderr.lower()
            reason = next((label for token, label in [
                ('host key', '主机密钥验证失败'), ('permission denied', '认证或远端权限失败'),
                ('no space left', '远端磁盘空间不足'), ('connection refused', '连接被拒绝'),
                ('timed out', '连接超时'), ('could not resolve', '域名解析失败'),
                ('not found', '远端命令或路径不存在')] if token in stderr), '未知SSH错误')
            raise RuntimeError('SSH 登录或命令执行失败（退出码 %s）：%s' % (result.returncode, reason))
        return result
    finally:
        if fd is not None:
            os.close(fd)


def transfer_unlocked(task, path, checksum):
    directory = task['path']
    final = directory.rstrip('/') + '/' + path.name
    temporary = final + '.upload-' + checksum[:16]
    q = shlex.quote
    # Shell arguments are quoted; remote uses an atomic rename only after hash match.
    command = (f'umask 077; mkdir -p -- {q(directory)} && '
               f'cat > {q(temporary)} && '
               f'actual=$(sha256sum -- {q(temporary)}) && '
               f'actual=${{actual%% *}} && '
               f'[ "$actual" = {q(checksum)} ] && '
               f'mv -f -- {q(temporary)} {q(final)} && '
               f'sha256sum -- {q(final)}')
    with path.open('rb') as f:
        result = run_ssh(task, command, stdin=f)
    if result.returncode or result.stdout.split()[:1] != [checksum]:
        raise RuntimeError('SSH 传送或远端摘要验证失败：' + result.stderr.strip()[:500])


def operation_lock(lock, wait_seconds=2400):
    import fcntl
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError('等待共享操作锁超时，未执行操作')
            time.sleep(1)


def transfer(task, path, checksum):
    import fcntl
    with open('/run/vaultwarden-operation.lock', 'a') as lock:
        operation_lock(lock)
        return transfer_unlocked(task, path, checksum)


def daily(mode):
    import fcntl
    import signal
    # Graceful service stop waits for tar/start cleanup; do not drop the inherited lock.
    signal.signal(signal.SIGTERM, lambda *_: log('每日兜底收到停止信号，等待当前操作安全结束'))
    tasks = load(CONFIG, {'tasks': []}).get('tasks', [])
    tasks = [t for i, t in enumerate(tasks)
             if t.get('mode', 'backup' if i == 0 else 'transfer') == mode]
    if not tasks:
        return
    with open('/run/vaultwarden-operation.lock', 'a') as lock:
        operation_lock(lock)
        if mode == 'backup':
            subprocess.run(['bash', '-c', 'source "$1"; backup_app', 'daily', str(SCRIPT)],
                           env={**os.environ, 'VW_OP_LOCK_FD': str(lock.fileno())},
                           pass_fds=(lock.fileno(),), check=True, timeout=2100)
            baseline = load(BASE / 'backup-db-baseline.json', {})
            if not baseline.get('db'):
                raise RuntimeError('备份没有发布停止状态的数据库基线')
            save(BASE / 'daily-db-baseline.json', baseline)
        files = archives()
        if not files:
            raise RuntimeError('没有可用备份，未传送')
        path = files[0]
        if not valid_archive(path):
            raise RuntimeError('最新备份不完整，未传送')
        checksum = digest(path)
        failed = []
        for task in tasks:
            try:
                transfer_unlocked(task, path, checksum)
                print('每日兜底传送成功：' + task['name'] + ' / ' + path.name, flush=True)
            except Exception as e:
                failed.append(task['name'])
                print('每日兜底传送失败（不重试）：' + task['name'] + ' / ' + str(e), flush=True)
        if failed:
            raise RuntimeError('每日兜底失败任务：' + ', '.join(failed))


def daily_units():
    result = {}
    for mode, when in [('backup', DAILY_BACKUP_TIME + ':00'), ('transfer', DAILY_TRANSFER_TIME + ':00')]:
        name = 'vaultwarden-ssh-daily-' + mode
        result[name + '.service'] = f'''[Unit]
Description=Vaultwarden daily {mode} fallback
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /root/yingyong/vaultwarden-ssh.py daily-{mode}
TimeoutStartSec=infinity
TimeoutStopSec=900
KillMode=mixed
UMask=0077
'''
        result[name + '.timer'] = f'''[Unit]
Description=Vaultwarden daily {mode} timer

[Timer]
OnCalendar=*-*-* {when}
Persistent=true
AccuracySec=1
Unit={name}.service

[Install]
WantedBy=timers.target
'''
    return result


def make_backup():
    # Use the tested local stop/archive/start implementation; never duplicate per destination.
    command = 'source "$1"; backup_app'
    subprocess.run(['bash', '-c', command, 'vaultwarden-backup', str(SCRIPT)], check=True, timeout=2100)


def log(message):
    import logging
    logging.getLogger('vaultwarden').info(message)
    print(time.strftime('%Y-%m-%d %H:%M:%S'), message, flush=True)


def locked_worker():
    import fcntl
    import logging
    from logging.handlers import RotatingFileHandler
    lock = open('/run/vaultwarden-ssh-worker.lock', 'a')
    os.chmod(lock.name, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    os.umask(0o077)
    BASE.mkdir(parents=True, exist_ok=True)
    handler = RotatingFileHandler(BASE / 'ssh-backup.log', maxBytes=2*1024*1024,
                                  backupCount=5, encoding='utf-8')
    os.chmod(BASE / 'ssh-backup.log', 0o600)
    handler.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
    logger = logging.getLogger('vaultwarden')
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)
    # A root-owned PID is informational only; flock is authoritative.
    save(BASE / 'ssh-worker.json', {'pid': os.getpid()})
    run()


SERVICE = 'vaultwarden-ssh-backup.service'
TIMER = 'vaultwarden-ssh-backup-health.timer'
HEARTBEAT = BASE / 'ssh-backup-heartbeat.json'


def units():
    return {
        SERVICE: """[Unit]
Description=Vaultwarden debounced SSH backup
Wants=network-online.target
After=network-online.target docker.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/python3 /root/yingyong/vaultwarden-ssh.py worker
Restart=always
RestartSec=10
UMask=0077
KillMode=mixed
TimeoutStopSec=900
StandardOutput=null
StandardError=journal
SyslogIdentifier=vaultwarden-ssh-backup

[Install]
WantedBy=multi-user.target
""",
        'vaultwarden-ssh-backup-health.service': """[Unit]
Description=Vaultwarden SSH backup health check

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /root/yingyong/vaultwarden-ssh.py health
TimeoutStartSec=960
UMask=0077
""",
        TIMER: """[Unit]
Description=Check Vaultwarden SSH backup every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=1
Unit=vaultwarden-ssh-backup-health.service

[Install]
WantedBy=timers.target
"""}


def systemctl(*args, check=True):
    return subprocess.run(['systemctl', *args], check=check, capture_output=True, text=True)


def beat(phase='idle', ttl=180):
    save(HEARTBEAT, {'pid': os.getpid(), 'phase': phase, 'expires': time.time() + ttl})


class ProgressHeartbeat:
    """Keep long synchronous operations visibly alive; stops on process exit."""
    def __init__(self, phase):
        import threading
        self.phase = phase
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.pulse, daemon=True)

    def pulse(self):
        while not self.stop.wait(10):
            try:
                beat(self.phase, 180)
            except Exception as e:
                log('进度心跳写入失败：' + str(e))

    def __enter__(self):
        beat(self.phase, 180)
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()
        beat()


def shutdown_monitor():
    # Stop timer first; do not stop its current health-check service from itself.
    for name in (TIMER, 'vaultwarden-ssh-daily-backup.timer', 'vaultwarden-ssh-daily-transfer.timer',
                 SERVICE, 'vaultwarden-ssh-daily-backup.service', 'vaultwarden-ssh-daily-transfer.service'):
        if systemctl('show', name, '--property=LoadState', '--value').stdout.strip() != 'not-found':
            systemctl('disable', '--now', name)
    for p in (HEARTBEAT, BASE / 'ssh-worker.json'):
        p.unlink(missing_ok=True)


def health():
    result = subprocess.run(['/usr/bin/python3', '/root/yingyong/vaultwarden-lifecycle.py', 'installed'])
    if result.returncode == 3:
        shutdown_monitor()
        return
    if result.returncode:
        raise RuntimeError('Docker状态异常，未补启动')
    if not load(CONFIG, {'tasks': []}).get('tasks'):
        shutdown_monitor()
        return
    if systemctl('is-active', '--quiet', SERVICE, check=False).returncode:
        systemctl('reset-failed', SERVICE, check=False)
        systemctl('start', SERVICE)
        return
    result = systemctl('show', SERVICE, '--property=MainPID', '--value')
    pid = int(result.stdout.strip() or '0')
    hb = load(HEARTBEAT, {})
    if hb.get('pid') != pid:
        # Give a newly-started process time to initialize, but never trust stale PID metadata.
        started = systemctl('show', SERVICE, '--property=ActiveEnterTimestampMonotonic', '--value')
        age = time.monotonic() - int(started.stdout.strip() or '0') / 1_000_000
        if age < 120:
            return
    elif hb.get('expires', 0) >= time.time():
        return
    systemctl('restart', SERVICE)


CRON_START = '# vaultwarden 密码备份（勿删）'
CRON_END = '# vaultwarden 密码备份结束（勿删）'
RUNNER = '/root/yingyong/vaultwarden-ssh.py'


def reconcile_text(text, enabled=True):
    lines = text.splitlines()
    result = []
    inside = False
    for line in lines:
        if line == CRON_START:
            if inside:
                raise ValueError('备份定时任务块嵌套异常')
            inside = True
            continue
        if line == CRON_END:
            if not inside:
                raise ValueError('备份定时任务块缺少开头')
            inside = False
            continue
        if inside:
            continue
        # Only remove exact runner-owned ensure rows; preserve unrelated cron.
        if re.fullmatch(r'(?:@reboot|\* \* \* \* \*) /usr/bin/python3 /root/(?:yingyong/)?vaultwarden-ssh\.py ensure >/dev/null 2>&1', line):
            continue
        result.append(line)
    if inside:
        raise ValueError('备份定时任务块缺少结尾，未修改 crontab')
    if enabled:
        result += [CRON_START,
                   '@reboot /usr/bin/python3 ' + RUNNER + ' ensure >/dev/null 2>&1',
                   '* * * * * /usr/bin/python3 ' + RUNNER + ' ensure >/dev/null 2>&1',
                   CRON_END]
    return '\n'.join(result).rstrip('\n') + ('\n' if result else '')


def remove_legacy_cron():
    current = subprocess.run(['crontab', '-l'], capture_output=True, text=True,
                             env={**os.environ, 'LC_ALL': 'C'})
    if current.returncode and 'no crontab for' not in current.stderr.lower():
        raise RuntimeError('无法读取旧 crontab，未覆盖：' + current.stderr.strip())
    old = current.stdout if current.returncode == 0 else ''
    new = reconcile_text(old, False)
    if old != new:
        subprocess.run(['crontab', '-'], input=new, text=True, check=True)
        check = subprocess.run(['crontab', '-l'], capture_output=True, text=True, check=True)
        if check.stdout != new:
            raise RuntimeError('旧 cron 清理后校验失败')


def repair_systemd():
    result = subprocess.run(['/usr/bin/python3', '/root/yingyong/vaultwarden-lifecycle.py', 'gate'])
    if result.returncode == 3:
        return
    if result.returncode:
        raise RuntimeError('无法确认安装状态，未修复systemd')
    import fcntl
    lock = open('/run/vaultwarden-ssh-repair.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX)
    config = load(CONFIG, {'tasks': []})
    if not isinstance(config.get('tasks'), list):
        raise ValueError('任务配置格式错误')
    for t in config['tasks']:
        for k in ('id', 'name', 'host', 'user', 'port', 'path'):
            if t.get('auth', 'key') == 'password' and not t.get('password_file'):
                raise ValueError('密码任务缺少凭据文件')
            if t.get('auth', 'key') == 'key' and not t.get('key'):
                raise ValueError('密钥任务缺少私钥路径')
            if k not in t:
                raise ValueError('任务配置缺少字段')
    if not config['tasks']:
        shutdown_monitor()
        name = 'vaultwarden-ssh-backup-health.service'
        if systemctl('show', name, '--property=LoadState', '--value').stdout.strip() != 'not-found':
            systemctl('stop', name)
        remove_legacy_cron()
        return
    changed = False
    for name, content in {**units(), **daily_units()}.items():
        p = Path('/etc/systemd/system') / name
        if not p.exists() or p.read_text() != content:
            fd, temporary = tempfile.mkstemp(prefix='.' + name, dir=p.parent)
            with os.fdopen(fd, 'w') as f:
                f.write(content)
            os.chmod(temporary, 0o644)
            os.replace(temporary, p)
            changed = True
    if changed:
        systemctl('daemon-reload')
    remove_legacy_cron()
    if config['tasks']:
        for mode in ('backup', 'transfer'):
            present = any(t.get('mode', 'backup' if i == 0 else 'transfer') == mode
                          for i, t in enumerate(config['tasks']))
            timer = 'vaultwarden-ssh-daily-' + mode + '.timer'
            if present:
                systemctl('enable', '--now', timer)
                systemctl('is-active', '--quiet', timer)
            else:
                systemctl('disable', '--now', timer)
        systemctl('enable', '--now', TIMER)
        systemctl('enable', SERVICE)
        # Terminate only a verified legacy worker, not a PID copied from stale metadata.
        meta = load(BASE / 'ssh-worker.json', {})
        pid = meta.get('pid')
        main = int(systemctl('show', SERVICE, '--property=MainPID', '--value').stdout.strip() or '0')
        if isinstance(pid, int) and pid > 1 and pid != main:
            try:
                cmd = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
                if (b'/root/yingyong/vaultwarden-ssh.py' in cmd or b'/root/vaultwarden-ssh.py' in cmd) and b'worker' in cmd:
                    import signal
                    os.kill(pid, signal.SIGTERM)
                    for _ in range(900):
                        try: os.kill(pid, 0)
                        except ProcessLookupError: break
                        time.sleep(1)
                    else: raise RuntimeError('旧后台进程未退出，未强制终止备份')
            except FileNotFoundError:
                pass
        if changed and systemctl('is-active', '--quiet', SERVICE, check=False).returncode == 0:
            systemctl('restart', SERVICE)
        health()
        systemctl('is-active', '--quiet', TIMER)
        systemctl('is-active', '--quiet', SERVICE)


def check_connections():
    from concurrent.futures import ThreadPoolExecutor
    tasks = load(CONFIG, {'tasks': []})['tasks']
    cache = os.environ.get('VW_STATUS_CACHE')
    if not cache:
        raise RuntimeError('缺少菜单会话缓存路径')
    def probe(task):
        try:
            run_ssh(task, 'true', timeout=8)
            return task['id'], 'ok'
        except subprocess.TimeoutExpired:
            return task['id'], 'failed'
        except RuntimeError as e:
            if 'SSH 登录或命令执行失败' in str(e):
                return task['id'], 'failed'
            return task.get('id', ''), 'unknown'
        except Exception:
            return task.get('id', ''), 'unknown'
    with ThreadPoolExecutor(max_workers=8) as executor:
        statuses = dict(executor.map(probe, tasks))
    try:
        result = subprocess.run(['/usr/bin/python3', '/root/yingyong/vaultwarden-s3.py', 'check'],
                                capture_output=True, text=True, timeout=15)
        statuses.update(json.loads(result.stdout))
    except Exception:
        pass
    save(Path(cache), statuses)


def summary(numbered=False):
    try:
        tasks = load(CONFIG, {'tasks': []})['tasks']
        cache = os.environ.get('VW_STATUS_CACHE')
        statuses = load(Path(cache), {}) if cache else {}
        if not isinstance(tasks, list): raise ValueError('任务格式错误')
        for t in tasks:
            if not isinstance(t.get('name'), str) or t.get('mode', 'backup') not in ('backup', 'transfer'):
                raise ValueError('任务字段错误')
        failures = load(STATE, {}).get('failures', {})
        idx = 0
        for mode, title in [('backup', 'SSH备份'), ('transfer', '传送任务')]:
            print(title)
            print('备注名   状态')
            group = [t for i, t in enumerate(tasks) if t.get('mode', 'backup' if i == 0 else 'transfer') == mode]
            if not group:
                print('\033[31m暂无\033[0m')
            for t in group:
                idx += 1
                status = statuses.get(t['id'], 'unknown')
                label = {'ok':'\033[32m连接正常\033[0m',
                         'failed':'\033[31m连接失败\033[0m',
                         'unknown':'\033[33m检测异常\033[0m'}.get(status, '\033[33m检测异常\033[0m')
                detail = (f'检测变更等待 {QUIET_SECONDS}s 无变更再备份传送' if mode == 'backup'
                          else f'检测备份目录 {TRANSFER_RETRY_SECONDS} 秒重试传送（每个新备份最多{TRANSFER_MAX_ATTEMPTS}次）')
                if mode == 'transfer' and failures.get(t['id'], 0) >= TRANSFER_MAX_ATTEMPTS:
                    detail = f'\033[31m本备份失败{TRANSFER_MAX_ATTEMPTS}次，等待新备份后自动重试\033[0m'
                name = ''.join(c for c in t['name'] if c.isprintable())
                print(f'{idx}. {name} {label} {detail}')
            print('------------------------')
        print('S3 API 兼容传送任务')
        print('备注名   状态')
        s3_tasks = load(BASE / 's3-backup.json', {'tasks': []})['tasks']
        s3_state = load(BASE / 's3-backup-state.json', {})
        if not s3_tasks:
            print('\033[31m暂无\033[0m')
        for task in s3_tasks:
            idx += 1
            record = s3_state.get(task['id'], {})
            status = statuses.get('s3:' + task['id'], 'unknown')
            label = {'ok':'\033[32m连接正常\033[0m', 'failed':'\033[31m连接失败\033[0m'}.get(status, '\033[33m检测异常\033[0m')
            detail = f'检测备份目录 {TRANSFER_RETRY_SECONDS} 秒重试传送（每个新备份最多{TRANSFER_MAX_ATTEMPTS}次；远端保留{S3_RETENTION_COUNT}个）'
            if record.get('failures', 0) >= TRANSFER_MAX_ATTEMPTS:
                detail = f'\033[31m本备份失败{TRANSFER_MAX_ATTEMPTS}次，等待新备份后自动重试\033[0m'
            name = ''.join(c for c in task['name'] if c.isprintable())
            print(f'{idx}. {name} {label} {detail}')
    except Exception:
        print('SSH备份\n\033[33m检测异常\033[0m\n------------------------\n传送任务\n\033[33m检测异常\033[0m')


def run():
    import signal
    stopping = [False]
    signal.signal(signal.SIGTERM, lambda *_: stopping.__setitem__(0, True))
    signal.signal(signal.SIGINT, lambda *_: stopping.__setitem__(0, True))
    beat()
    state = load(STATE, {'sent': {}, 'db': None})
    state.setdefault('sent', {})
    state.setdefault('attempted', {})
    state.setdefault('failures', {})
    state.setdefault('failure_archive', {})
    current = db_signature()
    debounce = Debounce(state.get('db') if state.get('db') is not None else current)
    if state.get('db') is None:
        state['db'] = current
        save(STATE, state)
    observed = {}
    checksums = {}
    retry_after = {}
    backup_retry = 0
    log(f'监控启动：数据库连续 {QUIET_SECONDS} 秒无变化后打包，同一归档传给多个任务。')
    last_beat = 0
    daily_seen = load(BASE / 'backup-db-baseline.json', {}).get('at')
    while not stopping[0]:
        try:
            if time.monotonic() - last_beat >= 30:
                if read_settings() != SETTINGS:
                    log('顶部配置已变更，退出由 systemd 重启加载新设置。')
                    return
                beat()
                last_beat = time.monotonic()
            tasks = load(CONFIG, {'tasks': []}).get('tasks', [])
            if not tasks:
                time.sleep(2)
                continue
            now = time.monotonic()
            daily_baseline = load(BASE / 'backup-db-baseline.json', {})
            if daily_baseline.get('at') != daily_seen:
                daily_seen = daily_baseline.get('at')
                debounce.reset(daily_baseline.get('db'))
                state['db'] = daily_baseline.get('db')
                save(STATE, state)
            current = db_signature()
            has_producer = any(t.get('mode', 'backup' if i == 0 else 'transfer') == 'backup'
                               for i, t in enumerate(tasks))
            if has_producer and (not archives() or debounce.ready(current, now)) and now >= backup_retry:
                try:
                    baseline = load(BASE / 'backup-db-baseline.json', {})
                    if baseline.get('logical_hash'):
                        with ProgressHeartbeat('database-content-check'):
                            unchanged = logical_db_hash() == baseline['logical_hash']
                        if unchanged and archives():
                            debounce.reset(current)
                            state['db'] = current
                            save(STATE, state)
                            log('数据库内容未变，仅SQLite文件状态变化，不重复打包。')
                            continue
                    with ProgressHeartbeat("backup"):
                        make_backup()
                    baseline = load(BASE / 'backup-db-baseline.json', {})
                    if not baseline.get('db'):
                        raise RuntimeError('备份没有发布数据库基线')
                    daily_seen = baseline.get('at')
                    debounce.reset(baseline['db'])
                    state['db'] = baseline['db']
                    save(STATE, state)
                    log('数据库备份完成，重置变化基线。')
                except Exception as e:
                    backup_retry = now + 60
                    log('打包失败，60 秒后重试：' + str(e))
            paths = archives()
            # Stable archive debounce avoids picking up a manually-created file mid-write.
            active = set()
            # Observe all files only for safe retention; transmit the newest only.
            for entry in paths:
                sig_entry = signature(entry)
                previous = observed.get(str(entry))
                if previous is None or previous[0] != sig_entry:
                    observed[str(entry)] = (sig_entry, time.monotonic())
                active.add(str(entry))
            for path in paths[:1]:
                active.add(str(path))
                sig = signature(path)
                item = observed.get(str(path))
                if item is None or item[0] != sig:
                    observed[str(path)] = (sig, time.monotonic())
                    continue
                if time.monotonic() - item[1] < QUIET_SECONDS:
                    continue
                cached = checksums.get(str(path))
                if cached and cached[0] == sig:
                    checksum = cached[1]
                else:
                    with ProgressHeartbeat("archive-validation"):
                        checksum = digest(path)
                        valid = valid_archive(path)
                    if not valid:
                        if checksums.get(str(path)) != ('invalid', sig):
                            log('最新备份不完整或格式非法，未传送：' + path.name)
                            checksums[str(path)] = ('invalid', sig)
                        continue
                    if signature(path) != sig:
                        observed.pop(str(path), None)
                        continue
                    checksums[str(path)] = (sig, checksum)
                for index, task in enumerate(tasks):
                    mode = task.get('mode', 'backup' if index == 0 else 'transfer')
                    key = task['id'] + ':' + path.name
                    if mode == 'transfer':
                        archive_token = path.name + ':' + checksum
                        if state['failure_archive'].get(task['id']) != archive_token:
                            state['failure_archive'][task['id']] = archive_token
                            state['failures'][task['id']] = 0
                            retry_after.pop(key, None)
                            save(STATE, state)
                        if state['failures'].get(task['id'], 0) >= TRANSFER_MAX_ATTEMPTS:
                            continue
                    if mode == 'backup' and state['attempted'].get(key) == checksum:
                        continue
                    if state['sent'].get(key) == checksum or time.monotonic() < retry_after.get(key, 0):
                        continue
                    if mode == 'backup':
                        # Persist before connecting: producer never retries this archive, even after restart.
                        state['attempted'][key] = checksum
                        save(STATE, state)
                    try:
                        with ProgressHeartbeat("transfer"):
                            transfer(task, path, checksum)
                        state['sent'][key] = checksum
                        state['failures'][task['id']] = 0
                        save(STATE, state)
                        log('传送成功：' + task['name'] + ' / ' + path.name)
                    except Exception as e:
                        if mode == 'transfer':
                            count = state['failures'].get(task['id'], 0) + 1
                            state['failures'][task['id']] = count
                            save(STATE, state)
                            retry_after[key] = time.monotonic() + TRANSFER_RETRY_SECONDS
                            action = '本备份已停止重试，等待新备份' if count >= TRANSFER_MAX_ATTEMPTS else f'{TRANSFER_RETRY_SECONDS} 秒后重试最新备份'
                            log(f'传送连续失败 {count}/{TRANSFER_MAX_ATTEMPTS}，{action}：' + task['name'] + ' / ' + str(e))
                        else:
                            log('SSH备份传送失败，本次不重试，本地备份保留：' + task['name'] + ' / ' + str(e))
            # Retention runs after transmission attempts, never deletes remote files.
            # Do not remove a growing/incomplete archive or an archive not yet stable for 5s.
            for old in paths[10:]:
                item = observed.get(str(old))
                if item and time.monotonic() - item[1] >= QUIET_SECONDS:
                    with ProgressHeartbeat('retention-validation'):
                        valid = valid_archive(old)
                    if not valid:
                        continue
                    old.unlink()
                    log('本地保留策略删除：' + old.name)
            observed = {k: v for k, v in observed.items() if k in active}
            names = {p.name for p in archives()}
            ids = {t['id'] for t in tasks}
            compact = {k: v for k, v in state['sent'].items()
                       if k.split(':', 1)[0] in ids and k.split(':', 1)[1] in names}
            if compact != state['sent']:
                state['sent'] = compact
                save(STATE, state)
            checksums = {k: v for k, v in checksums.items() if k in active}
        except Exception as e:
            log('监控错误（不删除配置）：' + str(e))
        time.sleep(1)


def add_task(mode=None):
    import uuid
    import getpass
    import shutil
    name = input('备注名：').strip()
    host = input('远程服务器 IP 或域名：').strip()
    user = input('SSH 用户（回车 root）：').strip() or 'root'
    port = input('SSH 端口（回车 22）：').strip() or '22'
    choice = input('认证方式：1. 私钥  2. 密码（回车 1）：').strip() or '1'
    if choice not in ('1', '2'):
        raise ValueError('无效认证方式')
    key = ''
    if choice == '1':
        key = os.path.expanduser(input('SSH 私钥路径（回车 /root/.ssh/id_ed25519）：').strip() or '/root/.ssh/id_ed25519')
        if not Path(key).is_file(): raise ValueError('私钥文件不存在')
    else:
        if not shutil.which('sshpass'):
            raise RuntimeError('密码认证需要 sshpass：apt install sshpass（或 dnf install sshpass）')
        print('无人值守需要本地保存密码：单独文件、root 所有、0600；不是加密存储。')
        if input('确认保存密码请输入 yes：') != 'yes':
            print('已取消。')
            return
    raw_path = input('远程保存目录（回车 /home/备份/vaultwarden）：').strip() or '/home/备份/vaultwarden'
    if (not name or not re.fullmatch(r'[A-Za-z0-9_.:-]+', host) or host.startswith('-') or
            not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', user) or
            not port.isdigit() or not 1 <= int(port) <= 65535 or
            not raw_path.startswith('/') or '\n' in raw_path or '\r' in raw_path):
        raise ValueError('备注、主机、用户、端口或远程绝对路径无效。')
    remote_path = '/' + os.path.normpath(raw_path).lstrip('/')
    task = dict(id=uuid.uuid4().hex, name=name, host=host, user=user,
                port=int(port), key=os.path.abspath(key) if key else '', path=remote_path,
                auth='key' if choice == '1' else 'password')
    credential = None
    try:
        if choice == '2':
            if not sys.stdin.isatty(): raise RuntimeError('密码必须在交互终端隐藏输入')
            password = getpass.getpass('SSH 密码（隐藏输入）：')
            if not password or '\n' in password or '\r' in password: raise ValueError('密码为空或包含换行')
            directory = BASE / 'ssh-secrets'
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(directory, 0o700)
            credential = directory / (task['id'] + '.password')
            fd = os.open(credential, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as f: f.write(password + '\n')
            del password
            task['password_file'] = str(credential)
        print('先验证主机指纹和认证；首次连接须自行核对指纹。')
        try:
            run_ssh(task, 'true', first=True)
            run_ssh(task, 'command -v sha256sum >/dev/null && mkdir -p -- ' + shlex.quote(remote_path))
            task['connection_verified'] = True
        except Exception as e:
            print('SSH 当前不可用：' + str(e))
            print('任务仍会保存：本地监控打包不以 SSH 成功为前提，远端恢复后重试传送。')
            print('不会绕过主机密钥验证；指纹异常需手动核实修复，首次未信任的主机也需先确认。')
            task['connection_verified'] = False
    except BaseException:
        if credential: credential.unlink(missing_ok=True)
        raise
    config = load(CONFIG, {'tasks': []})
    for i, old in enumerate(config['tasks']):
        old.setdefault('mode', 'backup' if i == 0 else 'transfer')
    task['mode'] = mode or ('backup' if not config['tasks'] else 'transfer')
    config['tasks'].append(task)
    save(CONFIG, config)
    print('任务已保存：' + name + ' → ' + host + ':' + remote_path)
    print('SSH备份先打包后传送一次；传送任务仅传最新备份，失败重试，不补传历史。')


def list_tasks():
    config = load(CONFIG, {'tasks': []})
    state = load(STATE, {'sent': {}})
    for i, t in enumerate(config['tasks'], 1):
        count = sum(k.startswith(t['id'] + ':') for k in state.get('sent', {}))
        print(f"{i}. {t['name']} | {t['user']}@{t['host']}:{t['port']} → {t['path']} | 已验证本地现存归档 {count} 个")
    if not config['tasks']:
        print('暂无传送任务。')


def delete_task():
    list_tasks()
    config = load(CONFIG, {'tasks': []})
    choice = input('删除任务编号（0 取消）：')
    if choice == '0':
        return
    if not choice.isdigit() or not 1 <= int(choice) <= len(config['tasks']):
        raise ValueError('无效编号')
    if input('仅删除本地任务配置，保留所有备份；确认输入 yes：') != 'yes':
        return
    for i, old in enumerate(config['tasks']):
        old.setdefault('mode', 'backup' if i == 0 else 'transfer')
    removed = config['tasks'].pop(int(choice) - 1)
    save(CONFIG, config)
    if removed.get('auth') == 'password':
        credential = BASE / 'ssh-secrets' / (removed['id'] + '.password')
        if removed.get('password_file') == str(credential):
            credential.unlink(missing_ok=True)
    print('任务已删除。')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['run', 'worker', 'health', 'repair', 'check-connections', 'summary', 'summary-numbered', 'add', 'add-backup', 'add-transfer', 'list', 'delete', 'daily-backup', 'daily-transfer'])
    args = parser.parse_args()
    try:
        {'run': locked_worker, 'worker': locked_worker, 'health': health,
         'repair': repair_systemd, 'check-connections': check_connections, 'summary': summary,
         'summary-numbered': lambda: summary(True),
         'add': add_task, 'add-backup': lambda: add_task('backup'),
         'add-transfer': lambda: add_task('transfer'), 'list': list_tasks, 'delete': delete_task,
         'daily-backup': lambda: daily('backup'), 'daily-transfer': lambda: daily('transfer')}[args.action]()
    except (Exception, KeyboardInterrupt) as e:
        print('操作未完成：' + str(e), file=sys.stderr)
        sys.exit(1)
SINGLEFILE_SOURCE_VAULTWARDEN_SSH_PY
# SINGLEFILE_HELPER vaultwarden-s3.py SINGLEFILE_SOURCE_VAULTWARDEN_S3_PY
    cat <<'SINGLEFILE_SOURCE_VAULTWARDEN_S3_PY'
#!/usr/bin/python3
"""S3-compatible latest-archive uploader; deletion restricted to owned keys."""
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time
import fcntl
import getpass
import uuid
import subprocess
from urllib.parse import urlparse

spec = importlib.util.spec_from_file_location('vw', '/root/yingyong/vaultwarden-ssh.py')
vw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vw)
CONFIG = vw.BASE / 's3-backup.json'
STATE = vw.BASE / 's3-backup-state.json'
PREFIX_MARK = 'vaultwarden-managed/'


def client(task, check=False):
    import boto3
    from botocore.config import Config
    return boto3.client('s3', endpoint_url=task['endpoint'], region_name=task['region'],
                        aws_access_key_id=task['access'], aws_secret_access_key=task['secret'],
                        config=Config(connect_timeout=8, read_timeout=8 if check else 60,
                                      retries={'max_attempts': 0},
                                      s3={'addressing_style': task['style']}))


def normalize_endpoint(value):
    value = value.strip().rstrip('/')
    if '://' not in value:
        value = 'https://' + value
    parsed = urlparse(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or
            parsed.password or parsed.query or parsed.fragment or any(c.isspace() for c in value)):
        raise ValueError('Endpoint 无效，必须为HTTPS地址')
    return value


def ensure_bucket(c, task):
    from botocore.exceptions import ClientError
    try:
        c.head_bucket(Bucket=task['bucket'])
    except ClientError as e:
        code = str(e.response.get('Error', {}).get('Code', ''))
        status = e.response.get('ResponseMetadata', {}).get('HTTPStatusCode')
        if code not in ('404', 'NoSuchBucket', 'NotFound') and status != 404:
            raise
        args = {'Bucket': task['bucket']}
        if task['region'] != 'us-east-1':
            args['CreateBucketConfiguration'] = {'LocationConstraint': task['region']}
        c.create_bucket(**args)
        c.head_bucket(Bucket=task['bucket'])


def owned_objects(c, task):
    result = []
    for page in c.get_paginator('list_objects_v2').paginate(Bucket=task['bucket'], Prefix=task['prefix']):
        for item in page.get('Contents', []):
            tail = item['Key'][len(task['prefix']):]
            if re.fullmatch(r'mima_\d{14}\.tar\.gz', tail):
                result.append(item)
    return sorted(result, key=lambda x: x['Key'], reverse=True)


def upload_prune_unbounded(c, task, path, prune=True):
    print('S3阶段：检查Bucket / ' + task['name'], flush=True)
    ensure_bucket(c, task)
    checksum = vw.digest(path)
    key = task['prefix'] + path.name
    print('S3阶段：上传 / ' + task['name'], flush=True)
    c.upload_file(str(path), task['bucket'], key, ExtraArgs={'Metadata': {'sha256': checksum}})
    print('S3阶段：远端大小与元数据校验 / ' + task['name'], flush=True)
    head = c.head_object(Bucket=task['bucket'], Key=key)
    if head.get('ContentLength') != path.stat().st_size or head.get('Metadata', {}).get('sha256') != checksum:
        raise RuntimeError('上传后大小或摘要元数据校验失败，未删除旧备份')
    # Metadata is provenance, not an independent integrity check; read bytes back.
    import hashlib
    print('S3阶段：远端读回SHA256 / ' + task['name'], flush=True)
    body = c.get_object(Bucket=task['bucket'], Key=key)['Body']
    h = hashlib.sha256()
    try:
        while True:
            block = body.read(1024*1024)
            if not block: break
            h.update(block)
    finally:
        body.close()
    if h.hexdigest() != checksum:
        raise RuntimeError('远端读回 SHA256 不一致，未删除旧备份')
    if not prune:
        return checksum
    print('S3阶段：清理旧备份 / ' + task['name'], flush=True)
    for item in owned_objects(c, task)[vw.S3_RETENTION_COUNT:]:
        c.delete_object(Bucket=task['bucket'], Key=item['Key'])
    if len(owned_objects(c, task)) > vw.S3_RETENTION_COUNT:
        raise RuntimeError('远端清理未完成')
    return checksum


def upload_prune(c, task, path, prune=True):
    # A separate process bounds boto3 worker threads too, not only the caller.
    import multiprocessing
    ctx = multiprocessing.get_context('fork')
    receive, send = ctx.Pipe(duplex=False)
    def execute():
        try:
            send.send(('ok', upload_prune_unbounded(c, task, path, prune=prune)))
        except Exception as e:
            response = getattr(e, 'response', {})
            code = response.get('Error', {}).get('Code', '')
            http = response.get('ResponseMetadata', {}).get('HTTPStatusCode', '')
            detail = type(e).__name__ + ' S3=' + re.sub(r'[^A-Za-z0-9_.-]', '', str(code))[:80] + ' HTTP=' + str(http)
            send.send(('error', detail))
        finally:
            send.close()
    process = ctx.Process(target=execute)
    process.start()
    send.close()
    try:
        process.join(900)
        if process.is_alive():
            process.terminate()
            process.join(5)
            if process.is_alive():
                process.kill()
                process.join()
            raise TimeoutError('S3整个上传/校验/清理操作超过900秒')
        if not receive.poll():
            raise RuntimeError('S3子进程异常退出：' + str(process.exitcode))
        result, detail = receive.recv()
        if result != 'ok':
            raise RuntimeError(detail)
        return detail
    finally:
        if process.is_alive():
            process.kill()
            process.join()
        receive.close()


def run(force=False):
    result = subprocess.run(['/usr/bin/python3', '/root/yingyong/vaultwarden-lifecycle.py', 'installed'])
    if result.returncode == 3:
        return
    if result.returncode:
        raise RuntimeError('Docker状态异常，未传送')
    tasks = vw.load(CONFIG, {'tasks': []})['tasks']
    if not tasks: return
    with open('/run/vaultwarden-operation.lock', 'a') as lock:
        vw.operation_lock(lock)
        files = vw.archives()
        if not files: return
        path = files[0]
        if time.time() - path.stat().st_mtime < vw.QUIET_SECONDS: return
        def identity():
            st=path.stat()
            return [path.name,st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns,st.st_ctime_ns]
        source_identity=identity()
        state = vw.load(STATE, {})
        # Each task keeps its own acknowledged source; force explicitly bypasses this fast path.
        pending=[]
        for task in tasks:
            record=state.get(task['id'],{})
            unchanged=record.get('source_identity')==source_identity
            complete=record.get('done') and record.get('done')==record.get('token')
            exhausted=record.get('token') and record.get('failures',0)>=vw.TRANSFER_MAX_ATTEMPTS
            if force or not (unchanged and (complete or exhausted)):pending.append(task)
        if not pending:return
        if not vw.valid_archive(path):
            print('最新备份不完整或格式非法，S3未传送：' + path.name, flush=True)
            return
        checksum = vw.digest(path)
        if identity()!=source_identity:raise RuntimeError('归档在校验中变化，S3未传送')
        for task in pending:
            token = path.name + ':' + checksum
            record = state.get(task['id'], {})
            if not force and (record.get('done') == token or
                             record.get('token') == token and record.get('failures', 0) >= vw.TRANSFER_MAX_ATTEMPTS):
                record['source_identity']=source_identity
                state[task['id']]=record
                vw.save(STATE,state)
                continue
            if record.get('token') != token: record = {'token': token, 'failures': 0}
            try:
                upload_prune(client(task), task, path)
                record = {'token': token, 'done': token, 'failures': 0}
                print(f'S3上传及{vw.S3_RETENTION_COUNT}个保留校验完成：' + task['name'], flush=True)
            except Exception as e:
                record['failures'] = record.get('failures', 0) + 1
                response = getattr(e, 'response', {})
                error_code = response.get('Error', {}).get('Code', '')
                http_status = response.get('ResponseMetadata', {}).get('HTTPStatusCode', '')
                # Do not log request URLs, credentials, or unsanitized provider messages.
                detail = type(e).__name__
                if isinstance(e, RuntimeError) and re.fullmatch(r'[A-Za-z0-9_.-]+ S3=[A-Za-z0-9_.-]* HTTP=[0-9]*', str(e)):
                    detail += ' ' + str(e)
                if error_code: detail += ' S3=' + re.sub(r'[^A-Za-z0-9_.-]', '', str(error_code))[:80]
                if http_status: detail += ' HTTP=' + str(http_status)
                print('S3上传或清理失败：' + task['name'] + '；失败次数 ' + str(record['failures']) + '；' + detail, flush=True)
            if identity()!=source_identity:raise RuntimeError('归档在传送中变化，未提交S3成功记录')
            record['source_identity']=source_identity
            state[task['id']] = record
            vw.save(STATE, state)


def add():
    name = input('备注名：').strip()
    endpoint = normalize_endpoint(input('S3 API Endpoint（https://...）：'))
    bucket = input('Bucket 名称：').strip()
    region = input('Region（回车 us-east-1）：').strip() or 'us-east-1'
    style = input('寻址方式 1. path 2. virtual（回车1）：').strip() or '1'
    prefix = input('保存前缀（回车 /备份/vaultwarden/）：').strip().strip('/') or '备份/vaultwarden'
    prefix += '/'
    if not name or urlparse(endpoint).scheme != 'https' or not urlparse(endpoint).hostname or not bucket or style not in ('1','2') or '..' in prefix.split('/'):
        raise ValueError('配置无效；Endpoint 必须使用 HTTPS')
    if not sys.stdin.isatty(): raise ValueError('凭据必须在交互终端隐藏输入')
    print(f'凭据保存在本地0600文件；仅清理 {prefix} 内的 mima_时间戳.tar.gz，保留{vw.S3_RETENTION_COUNT}个。')
    print('Bucket 不存在时自动创建（需创建权限）；S3目录为对象前缀，不需要创建文件夹。')
    if input('确认保存凭据并启用远端清理请输入 yes：') != 'yes': return
    access = getpass.getpass('Access Key ID（隐藏输入）：')
    secret = getpass.getpass('Secret Access Key（隐藏输入）：')
    if not access or not secret: raise ValueError('凭据为空')
    task = dict(id=uuid.uuid4().hex,name=name,endpoint=endpoint,bucket=bucket,region=region,
                style='path' if style=='1' else 'virtual',prefix=prefix,access=access,secret=secret)
    try:
        ensure_bucket(client(task), task)
        print('Bucket连接正常。')
    except Exception:
        print('当前无法验证或创建Bucket，配置仍保存，上传时再次检查；不会放宽TLS检查。')
    cfg = vw.load(CONFIG, {'tasks': []});cfg['tasks'].append(task);vw.save(CONFIG,cfg)


def check_connections():
    from concurrent.futures import ThreadPoolExecutor
    def probe(task):
        try:
            c = client(task, check=True)
            c.head_bucket(Bucket=task['bucket'])
            return 's3:' + task['id'], 'ok'
        except Exception as e:
            from botocore.exceptions import BotoCoreError, ClientError
            return 's3:' + task['id'], 'failed' if isinstance(e, (BotoCoreError, ClientError)) else 'unknown'
    with ThreadPoolExecutor(max_workers=8) as pool:
        result = dict(pool.map(probe, vw.load(CONFIG, {'tasks': []})['tasks']))
    print(json.dumps(result))


def listing():
    tasks = vw.load(CONFIG, {'tasks': []})['tasks']
    for i,t in enumerate(tasks,1):print(f"{i}. {t['name']} → {t['bucket']}/{t['prefix']}（远端保留{vw.S3_RETENTION_COUNT}个）")
    if not tasks:print('暂无S3任务。')


def delete():
    listing();cfg=vw.load(CONFIG,{'tasks':[]});choice=input('删除编号（0取消）：')
    if choice=='0':return
    if not choice.isdigit() or not 1<=int(choice)<=len(cfg['tasks']):raise ValueError('无效编号')
    if input('仅删除本地任务及凭据，不删除远端备份；确认 yes：')!='yes':return
    cfg['tasks'].pop(int(choice)-1);vw.save(CONFIG,cfg)


def repair():
    result = subprocess.run(['/usr/bin/python3', '/root/yingyong/vaultwarden-lifecycle.py', 'gate'])
    if result.returncode == 3:
        return
    if result.returncode:
        raise RuntimeError('无法确认安装状态，未修复systemd')
    tasks = vw.load(CONFIG, {'tasks': []})['tasks']
    timer='vaultwarden-s3-backup.timer'
    daily='vaultwarden-s3-daily.timer'
    if not tasks:
        for name in (timer,daily,'vaultwarden-s3-backup.service','vaultwarden-s3-daily.service'):
            if vw.systemctl('show',name,'--property=LoadState','--value').stdout.strip()!='not-found':
                vw.systemctl('disable','--now',name)
        return
    contents={}
    for name,action in [('vaultwarden-s3-backup','run'),('vaultwarden-s3-daily','daily')]:
        contents[name+'.service']=f'[Unit]\nDescription=Vaultwarden S3 backup\nAfter=network-online.target\n\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /root/yingyong/vaultwarden-s3.py {action}\nTimeoutStartSec=infinity\nTimeoutStopSec=900\nKillMode=mixed\nUMask=0077\n'
    contents[timer]=f'[Unit]\nDescription=Vaultwarden S3 newest archive check\n\n[Timer]\nOnBootSec=60\nOnUnitInactiveSec={vw.TRANSFER_RETRY_SECONDS}\nUnit=vaultwarden-s3-backup.service\n\n[Install]\nWantedBy=timers.target\n'
    contents[daily]=f'[Unit]\nDescription=Vaultwarden S3 daily fallback\n\n[Timer]\nOnCalendar=*-*-* {vw.DAILY_TRANSFER_TIME}:00\nPersistent=true\nUnit=vaultwarden-s3-daily.service\n\n[Install]\nWantedBy=timers.target\n'
    changed=False
    for name,text in contents.items():
        p=Path('/etc/systemd/system')/name
        if not p.exists() or p.read_text()!=text:p.write_text(text);os.chmod(p,0o644);changed=True
    if changed:vw.systemctl('daemon-reload')
    for name in (timer,daily):vw.systemctl('enable','--now',name);vw.systemctl('is-active','--quiet',name)


if __name__=='__main__':
    try:
        action=sys.argv[1]
        {'run':run,'daily':lambda:run(True),'check':check_connections,'add':add,'list':listing,'delete':delete,'repair':repair}[action]()
    except Exception as e:
        # Avoid SDK exception text containing credential-bearing request URLs.
        print('S3操作未完成：'+type(e).__name__,file=sys.stderr);sys.exit(1)
SINGLEFILE_SOURCE_VAULTWARDEN_S3_PY
# SINGLEFILE_HELPER vaultwarden-mail.py SINGLEFILE_SOURCE_VAULTWARDEN_MAIL_PY
    cat <<'SINGLEFILE_SOURCE_VAULTWARDEN_MAIL_PY'
#!/usr/bin/python3
import json, os, sys, subprocess, tempfile, getpass
from pathlib import Path
import importlib.util

spec=importlib.util.spec_from_file_location('vw','/root/yingyong/vaultwarden-ssh.py')
vw=importlib.util.module_from_spec(spec);spec.loader.exec_module(vw)

def inspect():
    name=subprocess.run(['bash','-c','source "$1"; printf "%s" "$CONTAINER"','config',str(vw.SCRIPT)],capture_output=True,text=True,check=True,timeout=180).stdout
    return json.loads(subprocess.run(['docker','inspect',name],capture_output=True,text=True,check=True,timeout=180).stdout)[0],name

def effective():
    # Reuse the manager's validated host configuration path resolution.
    r=subprocess.run(['bash','-c','source "$1"; registration_config','config',str(vw.SCRIPT)],capture_output=True,text=True,check=True,timeout=180)
    path=Path(r.stdout.splitlines()[1]);c,name=inspect()
    env=dict(x.split('=',1) for x in c['Config'].get('Env',[]) if '=' in x)
    cfg=json.loads(path.read_text()) if path.exists() else {}
    def get(k,default=None):return cfg[k] if cfg.get(k) is not None else env.get(k.upper(),default)
    return path,cfg,get,c,name

def status():
    try:
        _,_,get,_,_=effective()
        print('smtp' if get('smtp_host','') and get('smtp_from','') else 'none')
    except Exception:print('unknown')

def apply(values):
    import fcntl, signal, stat
    inherited = os.environ.get('VW_OP_LOCK_FD')
    lock = None
    if inherited is not None:
        if not inherited.isascii() or not inherited.isdigit():
            raise ValueError('invalid operation lock fd')
        fd = int(inherited)
        a, b = os.fstat(fd), os.stat('/run/vaultwarden-operation.lock')
        if not stat.S_ISREG(a.st_mode) or (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
            raise ValueError('operation lock fd mismatch')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    else:
        lock = open('/run/vaultwarden-operation.lock', 'a')
        fcntl.flock(lock, fcntl.LOCK_EX)
    name = None
    handlers = {}
    def interrupted(signum, frame):
        raise InterruptedError('operation interrupted')
    def docker(action):
        subprocess.run(['docker', action, name], check=True,
                       stdout=subprocess.DEVNULL, timeout=180)
    def atomic_bytes(content, metadata):
        fd, tmp = tempfile.mkstemp(prefix='.smtp-', dir=path.parent)
        try:
            with os.fdopen(fd, 'wb') as f:
                f.write(content)
                if metadata:
                    os.fchown(f.fileno(), metadata.st_uid, metadata.st_gid)
                    os.fchmod(f.fileno(), stat.S_IMODE(metadata.st_mode))
                else:
                    os.fchmod(f.fileno(), 0o600)
                f.flush(); os.fsync(f.fileno())
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            handlers[sig] = signal.signal(sig, interrupted)
        path, _, _, _, name = effective()
        expected = vw.BASE / 'data' / 'config.json'
        if path != expected:
            raise ValueError('实际配置路径与 INSTALL_DIR/data/config.json 不一致，未修改')
        docker('stop')
        # The admin UI may write config until stop completes: re-read now.
        path, cfg, _, _, name = effective()
        if path != expected:
            raise ValueError('停止后配置路径发生变化，未修改')
        metadata = path.stat() if path.exists() else None
        before = path.read_bytes() if metadata else None
        cfg.update(values)
        try:
            atomic_bytes((json.dumps(cfg, ensure_ascii=False, indent=2) + '\n').encode(), metadata)
            docker('start')
            subprocess.run(['bash', '-c', 'source "$1"; verify_running',
                            'verify', str(vw.SCRIPT)], check=True, timeout=180)
            _, saved, _, _, _ = effective()
            if any(saved.get(k) != v for k, v in values.items()):
                raise ValueError('SMTP配置读回未匹配')
        except Exception:
            docker('stop')  # Never replace configuration while its writer runs.
            if before is None:
                path.unlink(missing_ok=True)
            else:
                atomic_bytes(before, metadata)
            raise
        print('邮件配置已保存，Vaultwarden 已启动；尚未测试实际邮件投递。')
    finally:
        # Best effort on ordinary errors and catchable signals; SIGKILL cannot recover.
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        try:
            if name is not None:
                docker('start')
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
            if lock is not None:
                lock.close()

def smtp():
    host=input('SMTP服务器：').strip()
    security=input('加密方式 starttls / force_tls（回车starttls）：').strip() or 'starttls'
    port=input('端口（回车587，force_tls建议465）：').strip() or '587'
    sender=input('发件邮箱（需服务商验证域名）：').strip()
    username=input('SMTP用户名（回车不认证）：').strip()
    password=getpass.getpass('SMTP密码（隐藏输入）：') if username else None
    if not host or security not in ('starttls','force_tls') or not port.isdigit() or not 1<=int(port)<=65535 or '@' not in sender:raise ValueError('参数无效')
    if input('保存并启动容器，确认 yes：')!='yes':return
    apply(dict(smtp_host=host,smtp_port=int(port),smtp_security=security,smtp_from=sender,
               smtp_username=username or None,smtp_password=password,smtp_auth_mechanism=None))

if __name__=='__main__':
    try:{'status':status,'smtp':smtp}[sys.argv[1]]()
    except Exception as e:print('邮件操作失败：'+type(e).__name__,file=sys.stderr);sys.exit(1)
SINGLEFILE_SOURCE_VAULTWARDEN_MAIL_PY
# SINGLEFILE_HELPER vaultwarden-lifecycle.py SINGLEFILE_SOURCE_VAULTWARDEN_LIFECYCLE_PY
    cat <<'SINGLEFILE_SOURCE_VAULTWARDEN_LIFECYCLE_PY'
#!/usr/bin/python3
"""Installation gate and scoped systemd cleanup for Vaultwarden managers."""
import importlib.util
import subprocess
import sys
from pathlib import Path

SCRIPT='/root/yingyong/vaultwarden.sh'
TIMERS=['vaultwarden-ssh-backup-health.timer','vaultwarden-ssh-daily-backup.timer',
        'vaultwarden-ssh-daily-transfer.timer','vaultwarden-s3-backup.timer','vaultwarden-s3-daily.timer']
SERVICES=['vaultwarden-ssh-backup-health.service','vaultwarden-ssh-backup.service',
          'vaultwarden-ssh-daily-backup.service','vaultwarden-ssh-daily-transfer.service',
          'vaultwarden-s3-backup.service','vaultwarden-s3-daily.service']

def installed():
    name=subprocess.run(['bash','-c','source "$1"; printf "%s" "$CONTAINER"','name',SCRIPT],capture_output=True,text=True,check=True,timeout=10).stdout
    r=subprocess.run(['docker','info'],capture_output=True,timeout=15)
    if r.returncode:raise RuntimeError('Docker不可用，未改变后台任务')
    r=subprocess.run(['docker','container','ls','-a','--format','{{.Names}}'],capture_output=True,text=True,timeout=15,check=True)
    return name in r.stdout.splitlines()

def stop_all():
    if not Path('/run/systemd/system').exists():return
    for name in TIMERS+SERVICES:
        r=subprocess.run(['systemctl','show',name,'--property=LoadState','--value'],capture_output=True,text=True,check=True)
        if r.stdout.strip()=='not-found':continue
        if name in TIMERS or name=='vaultwarden-ssh-backup.service':
            subprocess.run(['systemctl','disable',name],capture_output=True,check=True)
        subprocess.run(['systemctl','stop',name],capture_output=True,check=True)
        r=subprocess.run(['systemctl','is-active','--quiet',name])
        if r.returncode==0:raise RuntimeError('后台任务未停止：'+name)
    spec=importlib.util.spec_from_file_location('vw','/root/yingyong/vaultwarden-ssh.py')
    vw=importlib.util.module_from_spec(spec);spec.loader.exec_module(vw)
    vw.remove_legacy_cron()
    for p in (vw.HEARTBEAT,vw.BASE/'ssh-worker.json'):p.unlink(missing_ok=True)

def gate():
    if installed():return True
    stop_all()
    return False

if __name__=='__main__':
    try:
        if sys.argv[1]=='stop':stop_all()
        elif sys.argv[1]=='gate':sys.exit(0 if gate() else 3)
        elif sys.argv[1]=='installed':sys.exit(0 if installed() else 3)
    except Exception as e:
        print('安装/后台任务检测异常：'+str(e),file=sys.stderr)
        sys.exit(2)
SINGLEFILE_SOURCE_VAULTWARDEN_LIFECYCLE_PY
# SINGLEFILE_HELPER vaultwarden-final-send.py SINGLEFILE_SOURCE_VAULTWARDEN_FINAL_SEND_PY
    cat <<'SINGLEFILE_SOURCE_VAULTWARDEN_FINAL_SEND_PY'
#!/usr/bin/python3
"""Send exact uninstall archive once to each configured target; no S3 pruning."""
import importlib.util
import sys
from pathlib import Path

def load_module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

def send_all(path,ssh,s3):
    if not path.is_file() or not ssh.valid_archive(path):
        raise RuntimeError('卸载备份不可用，未传送')
    checksum=ssh.digest(path);failed=[];count=0
    tasks=ssh.load(ssh.CONFIG,{'tasks':[]})['tasks']
    for i,t in enumerate(tasks):
        category='SSH备份任务' if t.get('mode','backup' if i==0 else 'transfer')=='backup' else '传送任务'
        count+=1
        try:
            ssh.transfer_unlocked(t,path,checksum)
            print(category+'：'+t['name']+' 传送成功',flush=True)
        except Exception:
            failed.append((category,t['name']))
    for t in s3.vw.load(s3.CONFIG,{'tasks':[]})['tasks']:
        count+=1
        try:
            s3.upload_prune(s3.client(t),t,path,prune=False)
            print('S3任务：'+t['name']+' 传送校验成功（未清理远端）',flush=True)
        except Exception:
            failed.append(('S3任务',t['name']))
    if not count:print('暂无远程任务，仅保留本地备份。',flush=True)
    for category,name in failed:
        print(category+'：'+''.join(c for c in name if c.isprintable())+' 传送失败',flush=True)
    return not failed

if __name__=='__main__':
    try:
        ssh=load_module('vw','/root/yingyong/vaultwarden-ssh.py')
        s3=load_module('s3','/root/yingyong/vaultwarden-s3.py')
        # The parent must pass the real lock descriptor; verify without reacquiring separately.
        import os,fcntl
        fd=int(os.environ['VW_OP_LOCK_FD'])
        a,b=os.fstat(fd),os.stat('/run/vaultwarden-operation.lock')
        if (a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino):raise RuntimeError('错误操作锁')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        sys.exit(0 if send_all(Path(sys.argv[1]),ssh,s3) else 1)
    except Exception as e:
        print('卸载传送流程异常：'+type(e).__name__,file=sys.stderr);sys.exit(2)
SINGLEFILE_SOURCE_VAULTWARDEN_FINAL_SEND_PY
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    singlefile_bootstrap || exit 1

    main "$@"
fi
