#!/usr/bin/env bash
set -o pipefail

# Open WebUI 本地管理脚本
# 路径: /root/yingyong/95open-webui.sh

APP_NAME="open-webui"
IMAGE="ghcr.io/open-webui/open-webui:main"
HOST_PORT="3000"
CONTAINER_PORT="8080"
BASE_DIR="/home/docker/open-webui"
DATA_DIR="${BASE_DIR}/data"
ENV_FILE="${BASE_DIR}/open-webui.env"
# 备份相关文件统一归此目录；应用运行数据仍在 BASE_DIR。
BACKUP_DIR="/home/备份/open-webui"
REMOTE_DIR="${BACKUP_DIR}/config"
RETENTION_FILE="${REMOTE_DIR}/local-retention.json"
LOCK_FILE="${REMOTE_DIR}/operation.lock"
LOG_MAX_BYTES=2097152
LOG_BACKUPS=3

red='\033[31m'
green='\033[32m'
yellow='\033[33m'
blue='\033[36m'
plain='\033[0m'

pause() {
    read -r -p "按回车键继续..." _
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${red}请使用 root 用户运行。${plain}"
        exit 1
    fi
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_ip() {
    curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || \
    curl -4 -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
    hostname -I 2>/dev/null | awk '{print $1}'
}

start_docker_service() {
    if cmd_exists systemctl; then
        systemctl enable docker >/dev/null 2>&1 || true
        systemctl start docker >/dev/null 2>&1 || true
    elif cmd_exists rc-update; then
        rc-update add docker boot >/dev/null 2>&1 || true
        service docker start >/dev/null 2>&1 || true
    elif cmd_exists service; then
        service docker start >/dev/null 2>&1 || true
    fi
}

install_docker() {
    if cmd_exists docker; then
        echo -e "${green}Docker 已安装：$(docker --version 2>/dev/null)${plain}"
        start_docker_service
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        echo -e "${red}Docker 已安装但服务未运行或无法连接 Docker daemon，请先检查 Docker 服务。${plain}"
        return 1
    fi

    echo -e "${yellow}未检测到 Docker，开始自动安装 Docker...${plain}"

    if cmd_exists apt-get; then
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release
        curl -fsSL https://get.docker.com | sh
    elif cmd_exists dnf; then
        dnf install -y curl
        curl -fsSL https://get.docker.com | sh
    elif cmd_exists yum; then
        yum install -y curl
        curl -fsSL https://get.docker.com | sh
    elif cmd_exists apk; then
        apk add --no-cache docker docker-cli-compose curl
    else
        echo -e "${red}未识别的软件包管理器，请先手动安装 Docker。${plain}"
        return 1
    fi

    start_docker_service

    if ! cmd_exists docker; then
        echo -e "${red}Docker 安装失败，请手动安装后重试。${plain}"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${red}Docker 已安装但服务未运行或无法连接 Docker daemon，请先检查 Docker 服务。${plain}"
        return 1
    fi

    echo -e "${green}Docker 安装完成：$(docker --version 2>/dev/null)${plain}"
}

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$APP_NAME"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$APP_NAME"
}

is_installed() {
    container_exists || [ -d "$DATA_DIR" ] || [ -f "$ENV_FILE" ]
}

ensure_dirs() {
    mkdir -p "$DATA_DIR"
}

write_default_env_if_missing() {
    ensure_dirs
    if [ ! -f "$ENV_FILE" ]; then
        local ip
        ip=$(get_ip)
        cat > "$ENV_FILE" <<EOF
# Open WebUI 配置文件，由 /root/open-webui.sh 管理
# Open WebUI 默认配置
WEBUI_URL=http://${ip:-127.0.0.1}:${HOST_PORT}
FRONTEND_URL=http://${ip:-127.0.0.1}:${HOST_PORT}
ENABLE_SIGNUP=true
ENABLE_LOGIN_FORM=true
ENABLE_PASSWORD_AUTH=true
EOF
    fi
}

read_env_value() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2-
}

run_container() {
    ensure_dirs
    write_default_env_if_missing

    docker rm -f "$APP_NAME" >/dev/null 2>&1 || true

    docker run -d \
        --name "$APP_NAME" \
        --restart always \
        -p "${HOST_PORT}:${CONTAINER_PORT}" \
        --env-file "$ENV_FILE" \
        -v "${DATA_DIR}:/app/backend/data" \
        "$IMAGE"
}

install_app() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "▶️ 安装 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }
    ensure_dirs
    write_default_env_if_missing

    if container_exists; then
        echo -e "${yellow}检测到 open-webui 容器已存在，将按当前配置重建容器，数据目录保留：${DATA_DIR}${plain}"
    fi

    echo -e "${yellow}正在拉取镜像：${IMAGE}${plain}"
    docker pull "$IMAGE" || { echo -e "${red}镜像拉取失败。${plain}"; pause; return 1; }

    if run_container; then
        local ip url
        ip=$(get_ip)
        url=$(read_env_value WEBUI_URL)
        echo -e "${green}Open WebUI 安装完成。${plain}"
        echo -e "访问地址：${green}${url:-http://${ip:-服务器IP}:${HOST_PORT}}${plain}"
        echo "数据目录：${DATA_DIR}"
        echo "配置文件：${ENV_FILE}"
        echo "首次进入需要创建管理员账号。"
    else
        echo -e "${red}Open WebUI 启动失败，请查看日志：docker logs open-webui${plain}"
    fi
    pause
}

update_app() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "▶️ 更新 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }
    write_default_env_if_missing

    echo -e "${yellow}正在拉取最新镜像...${plain}"
    docker pull "$IMAGE" || { echo -e "${red}镜像拉取失败。${plain}"; pause; return 1; }

    if run_container; then
        echo -e "${green}Open WebUI 已更新并重启。${plain}"
    else
        echo -e "${red}更新后启动失败，请查看日志：docker logs open-webui${plain}"
    fi
    pause
}

restart_app() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "▶️ 重启 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }
    write_default_env_if_missing

    if container_exists; then
        if run_container; then
            echo -e "${green}Open WebUI 已按当前配置重启。${plain}"
        else
            echo -e "${red}重启失败，请查看日志：docker logs open-webui${plain}"
        fi
    else
        echo -e "${yellow}Open WebUI 未安装，开始安装...${plain}"
        docker pull "$IMAGE" && run_container
    fi
    pause
}

validate_archive() {
    python3 - "$1" <<'PY'
import sys,tarfile,pathlib
with tarfile.open(sys.argv[1],'r:gz') as t:
    seen=set(); has_data=False
    for m in t:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='open-webui' or chr(92) in m.name or not (m.isdir() or m.isfile()) or m.mode&0o7000 or str(p) in seen:
            raise ValueError('归档含不支持的成员')
        seen.add(str(p))
        if str(p)=='open-webui/data' and m.isdir(): has_data=True
    if not has_data: raise ValueError('归档缺少data目录')
PY
}

verify_restored_container() {
    local i health
    for ((i=0;i<120;i++)); do
        container_running || return 1
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$APP_NAME") || return 1
        case "$health" in
            healthy) return 0 ;;
            unhealthy) return 1 ;;
            none) ((i>=9)) && return 0 ;;
        esac
        sleep 2
    done
    error "等待容器健康检查超时。"
    return 1
}

backup_create() (
    umask 077
    [[ -d $BASE_DIR && ! -L $BASE_DIR ]] || { error "未找到应用数据目录：$BASE_DIR"; exit 1; }
    mkdir -p "$BACKUP_DIR" "$REMOTE_DIR" || exit 1
    local was_running=no tmp="" final="" status=0
    backup_cleanup() {
        local rc=$?
        trap - EXIT INT TERM
        [[ -z $tmp ]] || rm -f -- "$tmp"
        if [[ $was_running == yes ]]; then
            if ! docker start "$APP_NAME" >/dev/null || ! container_running; then
                error "恢复启动失败，请检查 docker logs $APP_NAME；已生成的备份仍保留。"
                rc=1
            fi
        fi
        exit "$rc"
    }
    trap backup_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if cmd_exists docker; then
        docker info >/dev/null 2>&1 || { error "Docker不可达，无法确认写入服务，取消备份。"; exit 1; }
        if container_running; then
            was_running=yes
            echo "停止 Open WebUI，确保数据库备份一致性..."
            docker stop --time 60 "$APP_NAME" >/dev/null || exit 1
            container_running && { error "容器仍在运行，取消备份。"; exit 1; }
        fi
    else
        error "缺少Docker，无法确认写入服务，取消备份。"; exit 1
    fi
    tmp=$(mktemp "$BACKUP_DIR/.open-webui-pack.XXXXXX") || exit 1
    echo "备份包含全部应用数据及配置，可能含账号、API Key等敏感信息。"
    tar -czf "$tmp" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")" || exit 1
    gzip -t "$tmp" && tar -tzf "$tmp" >/dev/null || exit 1
    validate_archive "$tmp" || { error "归档含恢复器不支持的链接/特殊文件，未发布备份。"; exit 1; }
    while true; do
        final="$BACKUP_DIR/open-webui-$(date '+%Y%m%d-%H%M%S').tar.gz"
        # link是原子排他发布，已有同名文件或链接绝不覆盖。
        if ln -- "$tmp" "$final" 2>/dev/null; then break; fi
        [[ -e $final || -L $final ]] || { error "备份发布失败。"; exit 1; }
        sleep 1
    done
    rm -f -- "$tmp"; tmp=""
    echo "备份完成：$final"
    prune_local_backups || exit 1
)

backup_app() { locked manual_remote_backup; }

list_backups() {
    python3 - "$BACKUP_DIR" <<'PY'
import pathlib,re,sys
files=[]
for directory in dict.fromkeys([sys.argv[1],'/home']):
    p=pathlib.Path(directory)
    if not p.is_dir(): continue
    files += [f for f in p.iterdir() if not f.is_symlink() and f.is_file() and re.fullmatch(r'open-webui-(?:\d{8}-\d{6}|\d{14})\.tar\.gz',f.name)]
for p in sorted(files,key=lambda p:p.name.replace('-',''),reverse=True): print(p)
PY
}

restore_app() (
    umask 077
    local choice confirm selected stage old="" replaced=no running_before=no
    local -a backups
    mapfile -t backups < <(list_backups)
    ((${#backups[@]})) || { error "$BACKUP_DIR 及 /home 下未找到备份。"; pause; exit 1; }
    local i
    for i in "${!backups[@]}"; do echo "$((i+1)). ${backups[$i]##*/}"; done
    IFS= read -r -p "请选择备份（回车恢复最新，0返回）：" choice || exit 0
    choice=${choice:-1}
    [[ $choice != 0 ]] || exit 0
    [[ $choice =~ ^[0-9]{1,6}$ ]] && ((10#$choice>=1 && 10#$choice<=${#backups[@]})) || { error "输入无效。"; pause; exit 1; }
    selected=${backups[$((10#$choice-1))]}
    echo "恢复：$selected"
    echo "将替换 $BASE_DIR；恢复前数据保存在 $BACKUP_DIR/recovery/。"
    IFS= read -r -p "确认恢复请输入小写yes：" confirm || exit 0
    [[ $confirm == yes ]] || { echo "已取消。"; exit 0; }
    mkdir -p "$BACKUP_DIR/recovery" || exit 1
    stage=$(mktemp -d "$BACKUP_DIR/.restore.XXXXXX") || exit 1
    restore_cleanup() {
        local rc=$?
        trap - EXIT INT TERM
        if ((rc!=0)) && [[ $replaced == yes ]]; then
            if container_exists; then
                docker rm -f "$APP_NAME" >/dev/null 2>&1 || { error "无法移除恢复失败的容器，保留现场：$old；暂存：$stage"; exit 1; }
            fi
            [[ ! -e $BASE_DIR ]] || mv -T -- "$BASE_DIR" "$stage/failed" || exit 1
            if [[ -n $old ]]; then mv -T -- "$old" "$BASE_DIR" || { error "回滚失败，原数据：$old"; exit 1; }; fi
        fi
        if ((rc!=0)) && [[ $running_before == yes && -d $BASE_DIR ]]; then
            if container_exists; then docker start "$APP_NAME" >/dev/null || rc=1
            else run_container >/dev/null || rc=1; fi
        fi
        rm -rf -- "$stage"
        exit "$rc"
    }
    trap restore_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    python3 - "$selected" "$stage" <<'PY'
import sys,tarfile,pathlib,gzip
with gzip.open(sys.argv[1],'rb') as f:
    for chunk in iter(lambda:f.read(1024*1024),b''): pass
with tarfile.open(sys.argv[1],'r:gz') as t:
    members=t.getmembers(); seen=set()
    if not members: raise ValueError('空归档')
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='open-webui' or '\\' in m.name or not (m.isdir() or m.isfile()) or m.mode&0o7000 or str(p) in seen:
            raise ValueError('归档包含危险路径、链接、特殊文件、重复路径或结构错误')
        seen.add(str(p))
    t.extractall(sys.argv[2],members=members)
if not (pathlib.Path(sys.argv[2])/'open-webui'/'data').is_dir(): raise ValueError('缺少data目录')
PY
    [[ $? == 0 ]] || { error "备份校验失败，未修改现有应用。"; pause; exit 1; }
    install_docker || exit 1
    # 拉取失败时仅在已有本地镜像的情况下继续，不先破坏现有容器。
    docker pull "$IMAGE" || docker image inspect "$IMAGE" >/dev/null 2>&1 || exit 1
    container_running && running_before=yes
    if container_exists; then
        docker stop --time 60 "$APP_NAME" >/dev/null || exit 1
        docker rm "$APP_NAME" >/dev/null || exit 1
    fi
    mkdir -p "$(dirname "$BASE_DIR")" || exit 1
    if [[ -e $BASE_DIR ]]; then
        old=$(mktemp -d "$BACKUP_DIR/recovery/open-webui-before-$(date '+%Y%m%d-%H%M%S').XXXXXX") || exit 1
        mv -T -- "$BASE_DIR" "$old" || exit 1
    fi
    replaced=yes
    mv -T -- "$stage/open-webui" "$BASE_DIR" || exit 1
    run_container && verify_restored_container || { error "恢复后启动失败，尝试回滚。"; exit 1; }
    replaced=no
    echo "Open WebUI 已恢复并启动。"
    [[ -z $old ]] || echo "恢复前数据：$old"
    pause
)

uninstall_app() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "▶️ 卸载 Open WebUI"
    echo -e "${green}================================${plain}"
    echo -e "${red}注意：此操作会删除容器。是否删除数据目录可单独选择。${plain}"
    IFS= read -r -p "确认卸载 Open WebUI 容器请输入小写yes: " confirm || return 0
    case "$confirm" in
        yes) ;;
        *) echo "已取消。"; pause; return 0 ;;
    esac

    stop_remote_schedules || { error "停止定时任务失败，取消卸载。"; pause; return 1; }
    locked uninstall_data
}

stop_remote_schedules() {
    local kind unit file
    for kind in ssh-backup ssh s3; do
        unit="open-webui-backup-$kind"
        file="/etc/systemd/system/$unit.service"
        [[ -f $file ]] || continue
        [[ $(IFS= read -r line < "$file"; printf '%s' "$line") == '# Open WebUI managed remote backup' ]] || { error "外部同名unit：$unit"; return 1; }
        systemctl disable --now "$unit.timer" || return 1
        systemctl stop "$unit.service" || return 1
    done
}

uninstall_data() {
    if cmd_exists docker; then
        docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    fi
    echo -e "${green}容器已删除。${plain}"

    if [ -d "$BASE_DIR" ]; then
        IFS= read -r -p "是否同时删除数据目录 ${BASE_DIR}？输入小写yes确认: " del_data || return 0
        case "$del_data" in
            yes)
                rm -rf "$BASE_DIR"
                echo -e "${green}数据目录已删除。${plain}"
                ;;
            *)
                echo "数据目录已保留：${BASE_DIR}"
                ;;
        esac
    fi
    pause
}

error() { echo "错误：$*" >&2; }
exists() { docker container inspect "$APP_NAME" >/dev/null 2>&1; }
locked() (
    umask 077
    mkdir -p "$BACKUP_DIR" "$(dirname "$LOCK_FILE")" || exit 1
    chmod 700 "$BACKUP_DIR" "$(dirname "$LOCK_FILE")" || exit 1
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || { error "应用备份操作正在执行。"; exit 1; }
    "$@"
)
ensure_environment() {
    local cmd
    for cmd in python3 flock; do command -v "$cmd" >/dev/null || { error "请先安装$cmd"; return 1; }; done
    if [[ ${1:-} == remote ]]; then
        if ! command -v rclone >/dev/null || ! command -v ssh-keyscan >/dev/null; then
            if command -v apt-get >/dev/null; then apt-get update && apt-get install -y rclone openssh-client || return 1
            else error "请先安装rclone和OpenSSH客户端。"; return 1; fi
        fi
    fi
}
remote_backup_app() (
    umask 077
    mkdir -p "$BACKUP_DIR" || exit 1
    backup_create || exit 1
)
manual_remote_backup() { local rc=0; configure_local_retention && remote_backup_app || rc=$?; pause; return "$rc"; }
configure_local_retention() {
    local count
    while true; do
        IFS= read -r -p "本地备份保留数量（回车默认3）：" count || return 1
        count=${count:-3}
        if [[ $count =~ ^[1-9][0-9]{0,5}$ ]] && (( count <= 100000 )); then break; fi
        error "请输入1–100000的正整数。"
    done
    python3 - "$RETENTION_FILE" "$count" <<'PY'
import pathlib,os,json,sys,tempfile
p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
fd,tmp=tempfile.mkstemp(prefix='.retention-',dir=p.parent)
with os.fdopen(fd,'w') as f: json.dump({'keep':int(sys.argv[2])},f)
os.replace(tmp,p); os.chmod(p,0o600)
PY
}
prune_local_backups() {
    python3 - "$BACKUP_DIR" "$RETENTION_FILE" <<'PY'
import pathlib,sys,json,re
root=pathlib.Path(sys.argv[1]); setting=pathlib.Path(sys.argv[2])
keep=json.loads(setting.read_text()).get('keep',3) if setting.exists() else 3
if not isinstance(keep,int) or isinstance(keep,bool) or not 1<=keep<=100000: raise ValueError('本地保留数量无效，不执行删除')
files=sorted((p for p in root.iterdir() if re.fullmatch(r'open-webui-(?:\d{8}-\d{6}|\d{14})\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name.replace('-',''),reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
remote_engine() {
    python3 - "$REMOTE_DIR" "$BACKUP_DIR" "$@" 3<&0 <<'PY'
import os,sys,pathlib,json,re,subprocess,getpass,urllib.parse,tempfile,time,hashlib,tarfile,fcntl,shutil,zlib
sys.stdin=os.fdopen(3)
root=pathlib.Path(sys.argv[1]); backups=pathlib.Path(sys.argv[2]); mode=sys.argv[3]; kind=sys.argv[4]
if kind not in ('ssh-backup','ssh','s3'): raise ValueError('未知目标')
root.mkdir(parents=True,exist_ok=True,mode=0o700); os.chmod(root,0o700)
p=root/(kind+'.json'); conf=root/(kind+'.conf'); known=root/(kind+'-known-hosts')
def run(args,**kw):
    return subprocess.run(args,check=True,text=True,capture_output=True,timeout=900,**kw)
def ask(label,default=''):
    s=input(label+(' [默认 '+default+']' if default else '')+'：').strip(); return s or default
def valid(s):
    if not s or any(ord(c)<32 or ord(c)==127 for c in s): raise ValueError('输入为空或含非法字符')
    return s
def save(path,text):
    fd,tmp=tempfile.mkstemp(prefix='.setting-',dir=root)
    try:
        with os.fdopen(fd,'w') as f:f.write(text); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path); os.chmod(path,0o600)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
def load():
    if not p.is_file() or not conf.is_file(): raise ValueError('尚未配置，请先选择1')
    return json.loads(p.read_text())
def rc(args): return run(['rclone','--temp-dir',str(backups/'tmp'),'--cache-dir',str(backups/'cache'),'--config',str(conf),'--contimeout','15s','--timeout','2m','--retries','2']+args)
try:
    if mode=='configure':
        if p.exists() and ask('已有配置，输入yes确认覆盖')!='yes': sys.exit(2)
        d={'kind':kind,'keep':0 if kind in ('ssh','ssh-backup') else 3,'action':'backup' if kind=='ssh-backup' else 'transfer'}
        d['name']=valid(ask('任务备注名',{'ssh-backup':'SSH备份','ssh':'SSH传送','s3':'S3传送'}[kind]))
        if kind in ('ssh','ssh-backup'):
            host=valid(ask('SSH主机IP或域名')); user=valid(ask('SSH用户名','root')); port=ask('SSH端口','22')
            if not re.fullmatch(r'[A-Za-z0-9_.:-]+',host) or not re.fullmatch(r'[A-Za-z0-9_-]+',user) or not port.isdigit() or not 1<=int(port)<=65535: raise ValueError('主机/用户/端口无效')
            auth=ask('SSH认证方式：1私钥 / 2密码','1')
            if auth not in ('1','2'): raise ValueError('认证方式无效')
            key=None; password=None
            if auth=='1':
                key=pathlib.Path(valid(ask('SSH私钥文件','/root/.ssh/id_ed25519')))
                if not key.is_file(): raise ValueError('私钥不存在；定时任务需无交互可用的专用私钥')
            else:
                print('密码认证需在本机配置中保存可还原密码（权限600），不会进入备份包；rclone obscure不是强加密。')
                if ask('输入yes确认保存SSH密码')!='yes': sys.exit(2)
                password=valid(getpass.getpass('SSH密码（隐藏输入）：'))
            dest=valid(ask('远端专用备份目录','/home/备份/open-webui'))
            if not dest.startswith('/') or '..' in pathlib.PurePosixPath(dest).parts or dest=='/': raise ValueError('远端目录无效')
            print('将通过SFTP上传，保留全部远端备份，不删除远端文件：'+dest)
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(2)
            keys=run(['ssh-keyscan','-T','10','-p',port,host]).stdout
            if not keys.strip(): raise ValueError('未取得主机公钥')
            with tempfile.NamedTemporaryFile(mode='w',dir=root,delete=False) as f:f.write(keys); tmp=f.name
            try: print(run(['ssh-keygen','-lf',tmp]).stdout)
            finally: os.unlink(tmp)
            print('请与远端服务器管理员提供的指纹独立核对；扫描到的指纹本身不是信任证明。')
            if ask('核对无误请输入yes')!='yes': sys.exit(2)
            text='[remote]\ntype = sftp\nhost = '+host+'\nuser = '+user+'\nport = '+port+'\nknown_hosts_file = '+str(known)+'\n'
            if auth=='1': text+='key_file = '+str(key)+'\n'
            else:
                # 密码经stdin传入obscure，不进入命令行参数或日志。
                obscured=run(['rclone','obscure','-'],input=password+'\n').stdout.strip()
                if not obscured or '\n' in obscured: raise ValueError('密码处理失败')
                text+='pass = '+obscured+'\n'
            d['auth']='key' if auth=='1' else 'password'
            save(known,keys); d['dest']='remote:'+dest
        else:
            endpoint=valid(ask('S3 API Endpoint（非管理网页）'))
            if '://' not in endpoint: endpoint='https://'+endpoint
            endpoint=endpoint.rstrip('/')
            u=urllib.parse.urlsplit(endpoint)
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or any(c.isspace() for c in endpoint) or u.path not in ('','/'): raise ValueError('Endpoint必须为HTTPS API地址，无用户名/路径/查询参数')
            bucket=valid(ask('存储桶名称（需提前创建）'))
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,62}',bucket): raise ValueError('桶名无效')
            prefix=valid(ask('桶内专用备份前缀','备份/open-webui')).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            print('S3密钥将以明文保存在本机0600配置中，不进入应用备份。')
            if ask('输入yes确认保存S3密钥')!='yes': sys.exit(2)
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                keep=ask('S3远端备份保留数量','3')
                if keep.isdigit() and 1<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入1–100000的正整数。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份open-webui时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(2)
            text='[remote]\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+access+'\nsecret_access_key = '+secret+'\nendpoint = '+endpoint+'\nregion = '+region+'\nforce_path_style = true\nsign_accept_encoding = false\n'
        if d['action']=='backup':
            while True:
                interval=ask('备份间隔（1h/2h/4h/6h/8h/12h/1d/2d/3d/5d/7d）','1d')
                if interval in ('1h','2h','4h','6h','8h','12h','1d','2d','3d','5d','7d'): break
                print('请输入完整间隔，例如4h或2d。')
            d['interval']=interval
            if interval.endswith('h'):
                hours=int(interval[:-1])
                minute=ask('UTC每个周期的分钟','0')
                if not minute.isdigit() or not 0<=int(minute)<=59: raise ValueError('分钟无效')
                d['calendar']='*-*-* 00/'+str(hours)+':'+f'{int(minute):02}'+':00 UTC'
            else:
                hour=ask('每日备份UTC小时','5'); minute=ask('分钟','0')
                if not hour.isdigit() or not minute.isdigit() or not 0<=int(hour)<=23 or not 0<=int(minute)<=59: raise ValueError('时间无效')
                d['calendar']='*-*-* '+f'{int(hour):02}:{int(minute):02}:00 UTC'
                d['anchor_day']=int(time.time()//86400)
        else:
            d['calendar']='*:*:00/30'
            print('传送监控每30秒检查；仅发送最新完整归档，已成功发送的不重复上传。')
        save(conf,text); save(p,json.dumps(d,ensure_ascii=False))
        state=root/(kind+'-sent.json')
        if state.exists(): state.unlink()
        cache=root/(kind+'-source.json')
        if cache.exists(): cache.unlink()
        print('配置已保存，权限0600；凭据不进入备份包。')
    elif mode=='calendar': print(load()['calendar'])
    elif mode=='action': print(load().get('action','backup'))
    elif mode=='due':
        d=load(); interval=d.get('interval','1d')
        if d.get('action','backup')=='backup' and interval.endswith('d'):
            days=int(interval[:-1]); today=int(time.time()//86400)
            sys.exit(0 if (today-int(d.get('anchor_day',today)))%days==0 else 3)
        sys.exit(0)
    elif mode=='delete':
        owned_files=[p,conf,root/(kind+'-sent.json'),root/(kind+'-source.json')]
        if kind in ('ssh','ssh-backup'): owned_files.append(known)
        for q in owned_files:
            if q.exists(): q.unlink()
        print('配置删除，远端和本地备份未删除。')
    elif mode=='test':
        d=load(); rc(['lsjson',d['dest'],'--max-depth','1']); print('远端目录读取测试通过（不代表写入权限已验证）')
    elif mode=='upload':
        d=load()
        snapshot=None
        with (root/'operation.lock').open('a') as op:
            fcntl.flock(op,fcntl.LOCK_EX)
            files=[x for x in backups.glob('open-webui-*.tar.gz') if x.is_file() and not x.is_symlink() and re.fullmatch(r'open-webui-(?:\d{8}-\d{6}|\d{14})\.tar\.gz',x.name)]
            if not files: print('暂无归档，等待新备份。'); sys.exit(0)
            source=max(files,key=lambda x:x.name.replace('-',''))
            st=source.stat()
            token=[source.name,st.st_dev,st.st_ino,st.st_size,st.st_mtime_ns,st.st_ctime_ns]
            cached=root/(kind+'-source.json')
            state=root/(kind+'-sent.json')
            if state.is_file() and cached.is_file() and json.loads(cached.read_text())==token:
                print('最新归档已传送，跳过。'); sys.exit(0)
            if time.time()-st.st_mtime<60: print('最新归档尚未稳定，稍后再传。'); sys.exit(0)
            snapshot=pathlib.Path(tempfile.mkdtemp(prefix='.upload-',dir=backups))
            f=snapshot/source.name
            os.link(source,f)
        # 完整读取归档与gzip尾，不能只检查成员表。
        with tarfile.open(f,'r:gz') as archive:
            for member in archive:
                if member.isfile():
                    with archive.extractfile(member) as stream:
                        for chunk in iter(lambda:stream.read(1024*1024),b''): pass
        import gzip
        with gzip.open(f,'rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''): pass
        digest_hash=hashlib.sha256()
        with f.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''): digest_hash.update(chunk)
        digest=digest_hash.hexdigest()
        state=root/(kind+'-sent.json')
        signature=[f.name,st.st_size,digest]
        if state.exists() and json.loads(state.read_text())==signature:
            print('最新归档已传送，跳过。'); sys.exit(0)
        target=d['dest'].rstrip('/')+'/'+f.name
        rc(['copyto',str(f),target,'--immutable','--s3-upload-cutoff','32Mi','--s3-chunk-size','8Mi'])
        info=json.loads(rc(['lsjson',target,'--stat']).stdout)
        if info.get('IsDir') or info.get('Size')!=f.stat().st_size: raise ValueError('上传后远端大小校验失败；未执行清理')
        # 按字节比较本次归档；成功后才允许远端保留清理。
        rc(['check',str(f.parent),d['dest'],'--include',f.name,'--one-way','--download'])
        if kind=='s3':
            listing=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(r'open-webui-(?:\d{8}-\d{6}|\d{14})\.tar\.gz',x.get('Path',''))],key=lambda name:name.replace('-',''),reverse=True)
            keep=d.get('keep',3)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('S3保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化')
        save(state,json.dumps(signature))
        save(cached,json.dumps(token))
        retention='SSH远端不删除' if kind in ('ssh','ssh-backup') else 'S3远端保留最新'+str(d.get('keep',3))+'份'
        print('上传并校验成功：'+f.name+'；'+retention+'；本地数量由本地备份设置独立控制。')
    else: raise ValueError('未知操作')
except (EOFError,KeyboardInterrupt):
    print('已取消。'); sys.exit(1)
except Exception as e:
    # 不回显rclone原始输出、S3凭据或完整配置。
    print('远程备份失败：'+(str(e) if isinstance(e,ValueError) else type(e).__name__),file=sys.stderr); sys.exit(1)
finally:
    if 'snapshot' in locals() and snapshot is not None: shutil.rmtree(snapshot,ignore_errors=True)
PY
}
repair_remote_schedules() {
    # 仅已安装且有任务时修复，不因脚本存在或Docker检测失败启用任务。
    command -v docker >/dev/null || return 0
    docker info >/dev/null 2>&1 || return 0
    exists && [[ -d $DATA_DIR ]] || return 0
    local kind
    for kind in ssh-backup ssh s3; do
        if [[ -f $REMOTE_DIR/$kind.json && -f $REMOTE_DIR/$kind.conf ]]; then
            remote_schedule "$kind" enable >/dev/null || error "修复$kind定时任务失败。"
        fi
    done
}
# 配置修改顺序：配置锁→对应任务锁，均非阻塞；不同应用路径独立。
configuration_locked() (
    local kind=$1
    shift
    umask 077
    mkdir -p "$REMOTE_DIR" || exit 1
    chmod 700 "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { error "配置正在修改，请稍后重试。"; exit 1; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { error "该任务正在执行，未修改配置。"; exit 1; }
    "$@"
)
remote_schedule() { configuration_locked "$1" remote_schedule_unlocked "$@"; }
configure_remote_task() {
    remote_engine configure "$1" && remote_schedule_unlocked "$1" enable
}
delete_remote_task() {
    remote_schedule_unlocked "$1" remove && remote_engine delete "$1"
}
remote_schedule_unlocked() {
    local kind=$1 action=$2 calendar script unit="open-webui-backup-$1"
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || return 1
    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { error "定时备份需要systemd；配置可保留，仍可手动执行。"; return 1; }
    if [[ $action == remove ]]; then
        local owned
        for owned in "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"; do
            [[ ! -e $owned ]] || [[ $(IFS= read -r line < "$owned"; printf '%s' "$line") == '# Open WebUI managed remote backup' ]] || { error "外部同名unit，拒绝删除：$owned"; return 1; }
        done
        systemctl disable --now "$unit.timer" || return 1
        # 不强行终止正在传送的service；删除配置前检查。
        systemctl is-active --quiet "$unit.service" && { error "任务正在运行，请完成后再删除配置。"; return 1; }
        rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
        systemctl daemon-reload
        return
    fi
    calendar=$(remote_engine calendar "$kind") || return 1
    script=$(readlink -f "${BASH_SOURCE[0]}") || return 1
    [[ $script =~ ^/[A-Za-z0-9_./-]+$ ]] || { error "定时运行的脚本路径不支持空格或特殊字符。"; return 1; }
    local target
    for target in "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"; do
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != '# Open WebUI managed remote backup' ]]; then error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" <<'PY'
import sys,pathlib
unit,script,kind,calendar=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
service_content=('# Open WebUI managed remote backup\n[Unit]\nDescription=Open WebUI remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' --remote '+kind+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\nTimeoutStopSec=20min\nKillMode=mixed\n')
timer_content=('# Open WebUI managed remote backup\n[Unit]\nDescription=Open WebUI daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
changed=False
for suffix,content in (('.service',service_content),('.timer',timer_content)):
    p=base/(unit+suffix)
    if not p.exists() or p.read_text()!=content:
        p.write_text(content); changed=True
print('yes' if changed else 'no')
PY
    ) || return 1
    if [[ $changed == yes ]]; then systemctl daemon-reload || return 1; fi
    if [[ $changed == yes ]] || ! systemctl is-active --quiet "$unit.timer" || ! systemctl is-enabled --quiet "$unit.timer"; then
        systemctl enable --now "$unit.timer" || return 1
        if [[ $changed == yes ]]; then systemctl restart "$unit.timer" || return 1; fi
    fi
    systemctl is-active --quiet "$unit.timer" || return 1
    systemctl cat "$unit.service" "$unit.timer" >/dev/null || return 1
    echo "定时已启用：$calendar；多天间隔按配置日期计算，脚本移动后请重新配置定时。"
}
backup_event_log() {
    python3 - "$REMOTE_DIR" "$LOG_MAX_BYTES" "$LOG_BACKUPS" "$1" "$2" <<'PY'
import pathlib,sys,logging,logging.handlers,fcntl,os
root=pathlib.Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True,mode=0o700)
with (root/'log.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    h=logging.handlers.RotatingFileHandler(root/'backup-transfer.log',maxBytes=int(sys.argv[2]),backupCount=int(sys.argv[3]),encoding='utf-8')
    h.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
    logger=logging.getLogger('open-webui'); logger.setLevel(logging.INFO); logger.addHandler(h)
    logger.info('%s %s',sys.argv[4],sys.argv[5]); h.close()
    for p in root.glob('backup-transfer.log*'): os.chmod(p,0o600)
PY
}
remote_run() {
    local kind=$1
    [[ -f $REMOTE_DIR/$kind.json ]] || { error "尚未配置远端。"; return 1; }
    local action rc=0 result
    action=$(remote_engine action "$kind") || return 1
    if [[ $action == backup ]]; then
        backup_event_log "$kind" "本地备份开始" || return 1
        if ! locked remote_backup_app; then backup_event_log "$kind" "本地备份失败"; return 1; fi
        backup_event_log "$kind" "本地完整备份完成（可能包含应用凭据）" || return 1
        # 本地备份先完成并恢复容器，再检查传送工具和连接远端。
        sleep 60
    fi
    command -v rclone >/dev/null || {
        error "缺少rclone；本地备份保留，可由其他传送任务发送。"
        backup_event_log "$kind" "传送工具缺失，本地备份保留"; return 1;
    }
    result=$(remote_engine upload "$kind" 2>&1) || rc=$?
    [[ -z $result ]] || printf '%s\n' "$result"
    if (( rc )); then
        backup_event_log "$kind" "传送失败，本地备份保留" || return 1
    elif [[ $result == *'上传并校验成功'* ]]; then
        backup_event_log "$kind" "传送校验完成" || return 1
    fi
    # 无新文件/稳定等待/已发送跳过不写日志，防止空闲日志膨胀。
    return "$rc"
}
remote_locked_run() (
    local kind=$1
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || exit 1
    umask 077
    mkdir -p "$REMOTE_DIR" || exit 1
    chmod 700 "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { echo "配置正在修改，本次跳过。"; exit 0; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { echo "该目标正在传送，本次跳过。"; exit 0; }
    flock -u 7
    exec 7>&-
    if [[ ${2:-} == --scheduled ]]; then
        local due_rc=0
        remote_engine due "$kind" || due_rc=$?
        [[ $due_rc != 3 ]] || exit 0
        [[ $due_rc == 0 ]] || exit "$due_rc"
    fi
    remote_run "$kind"
)
remote_choose_ssh() {
    local selection
    echo "1. SSH备份上传任务"
    echo "2. SSH仅传送任务"
    IFS= read -r -p "选择任务（0取消）：" selection || return 1
    case "$selection" in 1) SELECTED_REMOTE=ssh-backup ;; 2) SELECTED_REMOTE=ssh ;; *) return 1 ;; esac
}
remote_menu() {
    local kind=$1 choice confirm target
    ensure_environment remote || return 1
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        if [[ $kind == ssh ]]; then
            echo "Open WebUI SSH 远程备份配置"
        else
            echo "Open WebUI S3 API 兼容备份配置"
        fi
        echo "=================================="
        remote_summary "$kind"
        if [[ $kind == ssh ]]; then
            echo "1. 添加SSH备份任务（定时备份并上传）"
            echo "2. 添加传送任务（有新备份直接传送，不打包）"
        else
            echo "1. 添加S3任务（有新备份直接传送，不打包）"
        fi
        echo "7. 测试远端读取"
        echo "8. 立即执行任务"
        echo "9. 删除任务（保留备份）"
        echo "0. 返回"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1)
                target=s3; [[ $kind != ssh ]] || target=ssh-backup
                if [[ $target == ssh-backup ]]; then locked configure_local_retention || continue; fi
                configuration_locked "$target" configure_remote_task "$target"
                ;;
            2)
                if [[ $kind == ssh ]]; then configuration_locked ssh configure_remote_task ssh
                else echo "无效选项。"; fi
                ;;
            7|8|9)
                target=s3
                if [[ $kind == ssh ]]; then remote_choose_ssh || continue; target=$SELECTED_REMOTE; fi
                case "$choice" in
                    7) configuration_locked "$target" remote_engine test "$target" ;;
                    8) remote_locked_run "$target" ;;
                    9)
                        IFS= read -r -p "输入yes确认删除本任务配置与定时：" confirm || return 0
                        [[ $confirm != yes ]] || { configuration_locked "$target" delete_remote_task "$target"; }
                        ;;
                esac
                ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." _ || return 0
    done
}

remote_summary() {
    # 主菜单仅读取本地配置及timer状态，不连接远端，不显示凭据。
    python3 - "$REMOTE_DIR" "${1:-all}" <<'PY'
import pathlib,json,subprocess,sys
root=pathlib.Path(sys.argv[1]); scope=sys.argv[2]
def color(text,code): return '\033['+code+'m'+text+'\033[0m'
def schedule(d):
    if d.get('action','backup')=='transfer': return '每30秒检测新备份并传送'
    interval=d.get('interval','1d'); calendar=d.get('calendar','')
    import re
    match=re.search(r'(\d{2}):(\d{2}):00 UTC$',calendar)
    if interval.endswith('h'):
        minute=int(match.group(2)) if match else 0
        return '每'+interval[:-1]+'小时，第'+str(minute)+'分运行（UTC）'
    if interval.endswith('d') and match:
        return '每'+interval[:-1]+'天 '+str(int(match.group(1)))+'时 '+str(int(match.group(2)))+'分运行（UTC）'
    return calendar or '未设置周期'

groups=[('ssh-backup','SSH备份','SSH备份'),('ssh','传送任务','SSH传送'),('s3','S3 API 兼容传送任务','S3传送')]
if scope=='ssh': groups=groups[:2]
elif scope=='s3': groups=groups[2:]
for index,(kind,title,default) in enumerate(groups):
    print(title)
    print('备注名   状态')
    p=root/(kind+'.json')
    if not p.exists(): print(color('暂无','31'))
    else:
        try:
            d=json.loads(p.read_text())
            if not isinstance(d,dict) or not d.get('dest') or not (root/(kind+'.conf')).is_file(): raise ValueError()
            name=str(d.get('name',default)).replace('\n',' ').replace('\r',' ')
            state=color('异常','33')+'（定时未运行）'
            try:
                unit='open-webui-backup-'+kind
                r=subprocess.run(['systemctl','is-active',unit+'.timer'],capture_output=True,text=True,timeout=2)
                result=subprocess.run(['systemctl','show',unit+'.service','--property=Result','--value'],capture_output=True,text=True,timeout=2)
                if r.returncode==0 and r.stdout.strip()=='active' and result.returncode==0 and result.stdout.strip() in ('success',''):
                    state=color('正常','32')+'（定时运行中）'
                elif result.returncode==0 and result.stdout.strip() not in ('success',''):
                    state=color('异常','33')+'（最近执行失败）'
            except (OSError,subprocess.TimeoutExpired): state=color('异常','33')+'（检测失败）'
            print(name+'   '+state+'  '+schedule(d))
        except Exception: print(color('异常','33')+'（配置检测失败）')
    print('------------------------' if index==0 and scope!='s3' else '==================================')
PY
}


show_menu() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    if is_installed; then
        if container_running; then
            echo -e "${green}open-webui 已安装（运行中）${plain}"
        else
            echo -e "${yellow}open-webui 已安装（未运行）${plain}"
        fi
    else
        echo "open-webui 未安装"
    fi
    echo "一个类似ChatGPT的AI网页界面，支持多模型接入和API管理。"
    echo "官网: https://github.com/open-webui/open-webui"
    echo
    echo "------------------------"
    remote_summary
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份（${BACKUP_DIR}/）"
    echo "4. 恢复（扫描 /home 和 ${BACKUP_DIR}/）"
    echo "5. SSH 远程备份配置"
    echo "6. S3 API 兼容备份配置"
    echo "9. 卸载"
    echo "------------------------"
    echo "0. 返回上一级"
    echo "------------------------"
}

main() {
    need_root
    ensure_environment || return 1
    if [[ ${1:-} == --remote ]]; then remote_locked_run "${2:-}" "${3:-}"; return $?; fi
    repair_remote_schedules
    while true; do
        show_menu
        IFS= read -r -p "请输入你的选择: " choice || { echo "已退出"; return 0; }
        case "$choice" in
            1) locked install_app ;;
            2) locked update_app ;;
            3) backup_app ;;
            4) locked restore_app ;;
            5) remote_menu ssh; continue ;;
            6) remote_menu s3; continue ;;
            9) uninstall_app ;;
            0) echo "已退出"; return 0 ;;
            *) echo -e "${red}无效输入。${plain}"; sleep 1 ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
