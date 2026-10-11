#!/usr/bin/env bash
# 独立导出自 /root/kejilion.sh 应用 44；不修改源脚本。
# 默认保留原部署路径、端口与禁止注册配置。
set -uo pipefail

CONTAINER="vaultwarden"
INSTALL_DIR="/home/web/vaultwarden"
OFFICIAL_IMAGE="vaultwarden/server:latest"
CUSTOM_IMAGE="zaixiangjian/vaultwarden:latest"
BACKUP_DIR="/home/备份/vaultwarden"  # 本地备份目录，支持末尾 /
QUIET_SECONDS=3                      # 文件连续无变化等待秒数
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
    if [[ ${VW_RECOVER_START:-1} == 1 ]]; then
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
    if [[ "$VW_RECOVER_START" == 1 ]]; then
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
        -e SIGNUPS_ALLOWED=false --restart always \
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
    require_docker || return 1
    command -v python3 >/dev/null 2>&1 || { echo "更新需要 python3。"; return 1; }
    container_exists || { echo "未安装，请先选择安装。"; return 1; }
    tmp="$(mktemp -d)" || return 1
    chmod 700 "$tmp"
    if ! docker inspect "$CONTAINER" > "$tmp/inspect.json"; then
        rm -rf -- "$tmp"; return 1
    fi
    # 从实际容器复制环境、数据挂载、端口、重启策略等；敏感信息不输出。
    if ! python3 - "$tmp/inspect.json" "$tmp/args" "$image" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))[0]
h, cfg = c['HostConfig'], c['Config']
networks = c.get('NetworkSettings', {}).get('Networks', {})
if len(networks) > 1:
    sys.exit('检测到多网络部署，为避免丢失网络配置，请使用原部署工具更新。')
if h.get('Privileged') or h.get('Devices') or h.get('VolumesFrom') or h.get('Links') or h.get('AutoRemove') or h.get('CapAdd') or h.get('CapDrop') or h.get('SecurityOpt') or h.get('ReadonlyRootfs') or h.get('Tmpfs') or h.get('NetworkMode', '').startswith('container:'):
    sys.exit('检测到特殊容器配置，为避免改变部署，请使用原部署工具更新。')
if cfg.get('Cmd') or cfg.get('Entrypoint') not in (None, [], ['/start.sh']):
    sys.exit('检测到自定义启动命令，为避免丢失设置，请使用原部署工具更新。')
args = ['run', '-d', '--name', 'vaultwarden']
restart = h.get('RestartPolicy', {})
policy = restart.get('Name') or 'no'
if policy == 'on-failure' and restart.get('MaximumRetryCount'):
    policy += ':' + str(restart['MaximumRetryCount'])
args += ['--restart', policy]
for env in cfg.get('Env', []):
    if not env.startswith('SIGNUPS_ALLOWED='):
        args += ['-e', env]
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
    docker pull "$image" || return 1
    old="$(docker inspect --format '{{.Image}}' "$CONTAINER")" || return 1
    backup_app || { echo "更新前完整数据备份失败，已取消更新。"; return 1; }
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
        echo "更新完成：$image；Vaultwarden 已启动。"
        echo "旧容器：$backup；旧镜像：$old；完整数据备份：$data_backup"
        return 0
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
    backup_app || { echo "备份失败，禁止卸载。"; return 1; }
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
import json, os, sys, tempfile, time
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
    local choice answer selected tmp listing stage before failed running index
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
    echo "恢复前数据会保留在安装目录的同级目录中。"
    IFS= read -r -p "确认恢复请输入小写 yes：" answer || return 0
    [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
    require_docker || return 1
    container_exists || { echo "未安装，请先安装容器后再恢复。"; return 1; }
    check_data_mount || return 1
    [[ ! -L "$selected" && -f "$selected" ]] || { echo "备份文件不可用。"; return 1; }
    stage="$(mktemp -d "${INSTALL_DIR}.restore-stage.XXXXXX")" || return 1
    if ! extract_backup "$selected" "$stage"; then rm -rf -- "$stage"; return 1; fi
    running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" || { rm -rf -- "$stage"; return 1; }
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
            echo "恢复完成：$selected"
            echo "恢复前数据：$before/data"
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
    if true; then
        docker start "$CONTAINER" >/dev/null && verify_running || { echo "原数据已恢复，但容器启动失败。"; return 1; }
    fi
    echo "恢复失败，已回滚原数据；失败数据保留位置：$failed"
    return 1
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
    echo "9. 卸载"
    echo "------------------------"
    echo "21. 自己安装zaixiangjian/vaultwarden:latest"
    echo "22. 从zaixiangjian更新"
    echo "23. 登录 Docker Hub"
    echo "24. 打上标签推送到zaixiangjian/vaultwarden:latest"
    echo "------------------------"
    echo "0. 退出"
}

main() {
    local choice
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
            3) backup_app ;;
            4) restore_app ;;
            5) registration_menu ;;
            6) ssh_backup_menu ;;
            7) s3_backup_menu ;;
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
