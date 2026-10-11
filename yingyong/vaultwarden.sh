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
S3_RETENTION_COUNT=5               # S3远端最多保留备份数量
TRANSFER_RETRY_SECONDS=60           # SSH/S3传送失败后的重试间隔（秒）
TRANSFER_MAX_ATTEMPTS=3             # 每个新备份最多尝试次数（含首次）

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

install_app() {
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

update_app() {
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
    running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" || return 1
    backup="${CONTAINER}.before-update.$(date +%Y%m%d%H%M%S).$$"
    # 保留旧容器与旧镜像用于失败回滚；不删除密码库或清理 Docker 镜像。
    docker stop "$CONTAINER" || return 1
    if ! docker rename "$CONTAINER" "$backup"; then
        [[ "$running" != true ]] || docker start "$CONTAINER" >/dev/null
        return 1
    fi
    if docker "${args[@]}" && verify_running; then
        if [[ "$running" != true ]]; then
            docker stop "$CONTAINER" >/dev/null || return 1
        fi
        echo "更新完成：$image（原容器是否运行：$running）"
        echo "保留旧容器：$backup；旧镜像：$old"
        echo "注意：新版本若迁移数据库，仅回退容器不能撤销数据迁移。"
        return 0
    fi
    echo "更新失败，尝试恢复旧容器。"
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        docker rm -f "$CONTAINER" >/dev/null || { echo "无法移除失败的新容器，旧容器保留为 $backup。"; return 1; }
    fi
    if ! docker rename "$backup" "$CONTAINER"; then
        echo "恢复名称失败，旧容器保留为 $backup。"; return 1
    fi
    if [[ "$running" == true ]]; then
        docker start "$CONTAINER" >/dev/null || { echo "旧容器启动失败，请检查日志。"; return 1; }
    fi
    echo "旧容器已恢复，密码库数据未删除。"
    return 1
}

uninstall_app() {
    local answer
    require_docker || return 1
    container_exists || { echo "未找到 $CONTAINER 容器。"; return 1; }
    echo "将删除 vaultwarden 容器，保留密码库数据、镜像与更新前旧容器。"
    IFS= read -r -p "确认卸载请输入小写 yes：" answer || return 0
    [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
    docker rm -f "$CONTAINER" || return 1
    if container_exists; then
        echo "卸载校验失败。"; return 1
    fi
    echo "卸载完成，密码库数据已保留。"
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
    local archive running rc=0
    require_docker || return 1
    container_exists || { echo "未找到 vaultwarden 容器。"; return 1; }
    check_data_mount || return 1
    mkdir -p "$BACKUP_DIR" || return 1
    # noclobber 原子创建，防止重名覆盖或跟随已存在的链接。
    while true; do
        archive="$BACKUP_DIR/mima_$(date +%Y%m%d%H%M%S).tar.gz"
        if (umask 077; set -C; : > "$archive") 2>/dev/null; then break; fi
        [[ -e "$archive" || -L "$archive" ]] || { echo "无法创建备份文件。"; return 1; }
        sleep 1
    done
    running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" || { rm -f -- "$archive"; return 1; }
    if ! docker stop "$CONTAINER" >/dev/null; then
        rm -f -- "$archive"; echo "停止容器失败，未执行打包。"; return 1
    fi
    echo "容器已停止，正在备份整个 data 目录（包含密码库敏感信息）。"
    tar -czpf "$archive" -C "$INSTALL_DIR" data && tar -tzf "$archive" >/dev/null || rc=1
    if [[ "$running" == true ]]; then
        if ! docker start "$CONTAINER" >/dev/null || ! verify_running; then
            echo "容器重新启动失败，请检查 docker logs vaultwarden。"
            rc=1
        fi
    fi
    if [[ -s "$archive" ]] && tar -tzf "$archive" >/dev/null 2>&1; then
        echo "备份文件：$archive"
        echo "备份前运行状态：$running；备份文件权限：0600。"
    else
        rm -f -- "$archive"
        echo "打包失败，未保留不完整备份。"
        rc=1
    fi
    return "$rc"
}

backup_app() (
    if [[ ${VW_OP_LOCK_HELD:-0} != 1 ]]; then
        exec 8>/run/vaultwarden-operation.lock
        flock -x 8 || return 1
    fi
    backup_app_unlocked
)

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

restore_app() {
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
        [[ "$running" != true ]] || docker start "$CONTAINER" >/dev/null
        echo "保存原数据失败，已取消恢复。"; return 1
    fi
    if mv -T -- "$stage/data" "$INSTALL_DIR/data"; then
        rmdir "$stage"
        if [[ "$running" != true ]] || { docker start "$CONTAINER" >/dev/null && verify_running; }; then
            echo "恢复完成：$selected"
            echo "恢复前数据：$before/data"
            echo "已恢复原容器运行状态：$running"
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
    if [[ "$running" == true ]]; then
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
        printf '5. 注册管理（'
    else
        echo "状态"
    fi
    case "$state" in
        false) printf '\033[31m🔴 禁止注册\033[0m' ;;
        true) printf '\033[32m🟢 允许注册\033[0m' ;;
        restricted) printf '\033[32m🟢 允许注册（仅限邮箱域名白名单）\033[0m' ;;
        *) printf '\033[33m🟡 检测失败\033[0m' ;;
    esac
    if [[ "${1:-}" == inline ]]; then printf '）'; fi
    printf '\n'
}

set_registration() {
    local value="$1" result file running work existed=false backup
    require_docker || return 1
    command -v python3 >/dev/null 2>&1 || { echo "注册管理需要 python3。"; return 1; }
    result="$(registration_config)" || return 1
    file="${result#*$'\n'}"
    running="$(docker inspect --format '{{.State.Running}}' "$CONTAINER")" || return 1
    work="$(mktemp -d "${INSTALL_DIR}.registration.XXXXXX")" || return 1
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
    if ! docker stop "$CONTAINER" >/dev/null; then rm -rf -- "$work"; echo "停止失败，配置未修改。"; return 1; fi
    if mv -T -- "$work/new.json" "$file"; then
        if [[ "$running" != true ]] || { docker start "$CONTAINER" >/dev/null && verify_running; }; then
            result="$(registration_config)" || result="unknown"
            if [[ "${result%%$'\n'*}" == "$value" ]]; then
                echo "注册设置已修改，已恢复原容器运行状态：$running"
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
    if [[ "$running" == true ]]; then
        docker start "$CONTAINER" >/dev/null && verify_running || { echo "配置已回滚，但容器启动失败。"; return 1; }
    fi
    echo "切换失败，已回滚；临时配置目录：$work"
    return 1
}

registration_menu() {
    local choice answer
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "=================================="
    echo "        vaultwarden 注册管理"
    show_registration_status
    echo "=================================="
    echo "1. 开启注册"
    echo "2. 禁止注册"
    echo "0. 返回"
    IFS= read -r -p "请输入选项：" choice || return 0
    case "$choice" in
        1|2)
            echo "将清空邮箱域名注册白名单，并重启原本运行的容器。"
            [[ "$choice" != 1 ]] || echo "警告：开启后可自行创建账户，请完成注册后及时禁止。"
            IFS= read -r -p "确认修改请输入小写 yes：" answer || return 0
            [[ "$answer" == yes ]] || { echo "已取消。"; return 0; }
            if [[ "$choice" == 1 ]]; then set_registration true; else set_registration false; fi
            ;;
        0) return 0 ;;
        *) echo "无效选项。" ;;
    esac
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
    ssh_backup_repair
    /usr/bin/python3 /root/yingyong/vaultwarden-s3.py repair || echo "S3服务检测异常。"
    python3 /root/yingyong/vaultwarden-ssh.py check-connections || echo "连接检测异常。"
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
