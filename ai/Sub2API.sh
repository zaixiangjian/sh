#!/bin/bash

APP_DIR="/home/docker/sub2api"
BACKUP_DIR="/home/备份/Sub2API"
APP_PORT="18080"

# ==============================
# 工具函数
# ==============================

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

pause() {
    echo ""
    read -p "按回车继续..."
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif check_cmd docker-compose; then
        docker-compose "$@"
    else
        echo "未检测到 Docker Compose"
        return 1
    fi
}

ensure_docker() {
    if check_cmd docker; then
        return 0
    fi

    echo "未检测到 Docker，开始安装 Docker..."
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 用户运行，或先手动安装 Docker"
        return 1
    fi

    curl -fsSL https://get.docker.com | bash || return 1
    systemctl enable --now docker >/dev/null 2>&1 || true
}

is_installed() {
    [ -f "$APP_DIR/docker-compose.yml" ]
}

volume_exists() {
    docker volume inspect "$1" >/dev/null 2>&1
}

compose_project_name() {
    basename "$APP_DIR"
}

find_volume_name() {
    local logical_name project_name prefixed_name by_container
    logical_name="$1"
    project_name=$(compose_project_name)
    prefixed_name="${project_name}_${logical_name}"

    if volume_exists "$prefixed_name"; then
        echo "$prefixed_name"
        return 0
    fi

    if volume_exists "$logical_name"; then
        echo "$logical_name"
        return 0
    fi

    case "$logical_name" in
        sub2api_data)
            by_container=$(docker inspect sub2api --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
        postgres_data)
            by_container=$(docker inspect sub2api-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
        redis_data)
            by_container=$(docker inspect sub2api-redis --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
    esac

    if [ -n "$by_container" ] && volume_exists "$by_container"; then
        echo "$by_container"
        return 0
    fi

    return 1
}

resolve_volume_name() {
    local logical_name project_name prefixed_name
    logical_name="$1"
    project_name=$(compose_project_name)
    prefixed_name="${project_name}_${logical_name}"

    find_volume_name "$logical_name" || echo "$prefixed_name"
}

backup_files() {
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'sub2api-*.tar.gz' -o -name 'sub2api--*.tar.gz' \) 2>/dev/null | sort -r
}

# ==============================
# 安装
# ==============================

install_app() {
    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    echo "正在生成配置..."

    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    TOTP_KEY=$(openssl rand -hex 32)
    ADMIN_PASSWORD=$(openssl rand -hex 16)

    cat > .env <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
TOTP_ENCRYPTION_KEY=$TOTP_KEY
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=$ADMIN_PASSWORD
POSTGRES_DB=sub2api
POSTGRES_USER=sub2api
TZ=Asia/Shanghai
EOF

    cat > docker-compose.yml <<EOF
services:
  sub2api:
    image: weishaw/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
    ports:
      - "${APP_PORT}:8080"
    environment:
      - AUTO_SETUP=true
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=sub2api
      - DATABASE_PASSWORD=\${POSTGRES_PASSWORD}
      - DATABASE_DBNAME=sub2api
      - REDIS_HOST=redis
      - ADMIN_EMAIL=\${ADMIN_EMAIL}
      - ADMIN_PASSWORD=\${ADMIN_PASSWORD}
      - JWT_SECRET=\${JWT_SECRET}
      - TOTP_ENCRYPTION_KEY=\${TOTP_ENCRYPTION_KEY}
      - TZ=Asia/Shanghai
    volumes:
      - sub2api_data:/app/data
    depends_on:
      - postgres
      - redis
    networks:
      - sub2api-net

  postgres:
    image: postgres:16-alpine
    container_name: sub2api-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: sub2api
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: sub2api
      TZ: Asia/Shanghai
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - sub2api-net

  redis:
    image: redis:7-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - sub2api-net

volumes:
  sub2api_data:
  postgres_data:
  redis_data:

networks:
  sub2api-net:
    driver: bridge
EOF

    docker compose up -d 2>/dev/null || docker-compose up -d

    echo ""
    echo "安装完成"
    echo "访问地址: http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
    echo "---------------------------------------------------------"
    echo "容器地址是8080"
    echo "---------------------------------------------------------"
    echo "管理员邮箱: admin@example.com"
    echo "管理员密码: $ADMIN_PASSWORD"
    echo "配置目录: $APP_DIR"
}

# ==============================
# 更新
# ==============================

update_app() {
    cd "$APP_DIR" || exit
    docker compose pull 2>/dev/null || docker-compose pull
    docker compose up -d 2>/dev/null || docker-compose up -d
    echo "更新完成"
}

# ==============================
# 卸载
# ==============================

uninstall_app() {
    local confirm
    echo "⚠️ 卸载将删除 Sub2API 容器、数据卷、镜像及安装目录，数据库等数据将丢失。"
    IFS= read -r -p "确认卸载请输入 yes（其他输入取消）: " confirm || return 0
    if [ "$confirm" != "yes" ]; then
        echo "已取消卸载"
        return 0
    fi
    cd "$APP_DIR" || exit
    docker compose down -v --rmi all 2>/dev/null || docker-compose down -v --rmi all
    rm -rf "$APP_DIR"
    echo "已完全卸载"
}

# ==============================
# 备份
# ==============================

backup_app() {
    if ! ensure_docker; then
        echo "Docker 环境异常，无法备份"
        return 1
    fi

    if ! is_installed; then
        echo "未检测到 Sub2API 安装目录: $APP_DIR"
        return 1
    fi

    local timestamp backup_file tmp_dir backup_status
    timestamp=$(date +%Y-%m-%d-%H%M%S)
    backup_file="$BACKUP_DIR/sub2api-${timestamp}.tar.gz"
    tmp_dir=$(mktemp -d)
    backup_status=0

    echo "正在备份 Sub2API..."
    echo "备份文件: $backup_file"
    echo "备份流程: 停止 Sub2API → 备份配置和数据卷 → 启动 Sub2API"

    echo "正在停止 Sub2API..."
    cd "$APP_DIR" || {
        rm -rf "$tmp_dir"
        return 1
    }
    compose_cmd down || {
        rm -rf "$tmp_dir"
        echo "停止 Sub2API 失败，已取消备份"
        return 1
    }

    mkdir -p "$tmp_dir/app" "$tmp_dir/volumes"

    echo "正在备份配置目录..."
    tar czf "$tmp_dir/app/app.tar.gz" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" || {
        echo "配置目录备份失败"
        backup_status=1
    }

    if [ "$backup_status" -eq 0 ]; then
        local logical_volume actual_volume
        for logical_volume in sub2api_data postgres_data redis_data; do
            if ! actual_volume=$(find_volume_name "$logical_volume"); then
                echo "错误：未找到关键 Docker 卷: $logical_volume"
                echo "为避免生成无法恢复用户/API/数据库的坏备份，本次备份已中止。"
                backup_status=1
                break
            fi

            echo "正在备份 Docker 卷: $actual_volume -> $logical_volume"
            docker run --rm \
                -v "$actual_volume:/volume:ro" \
                -v "$tmp_dir/volumes:/backup" \
                alpine sh -c "cd /volume && tar czf /backup/${logical_volume}.tar.gz ." || {
                    echo "Docker 卷备份失败: $actual_volume"
                    backup_status=1
                    break
                }
        done
    fi

    if [ "$backup_status" -eq 0 ]; then
        tar czf "$backup_file" -C "$tmp_dir" . || {
            echo "打包备份失败"
            backup_status=1
        }
    fi

    rm -rf "$tmp_dir"

    echo "正在启动 Sub2API..."
    cd "$APP_DIR" && compose_cmd up -d || {
        echo "警告：备份后启动 Sub2API 失败，请手动检查: $APP_DIR"
        [ "$backup_status" -eq 0 ] && backup_status=1
    }

    if [ "$backup_status" -eq 0 ]; then
        echo "备份完成: $backup_file"
        return 0
    fi

    echo "备份失败"
    return 1
}

# ==============================
# 恢复
# ==============================

restore_backup_files() {
    python3 - <<'PY'
import pathlib,re,datetime
files=[]
for root in ('/home','/home/备份/Sub2API','/home/备份'):
    p=pathlib.Path(root)
    if p.is_dir(): files.extend(f for f in p.glob('sub2api-*.tar.gz') if f.is_file() and not f.is_symlink())
def order(f):
    token=f.name[len('sub2api-'):-7].replace('-','')
    return (token if re.fullmatch(r'\d{14}',token) else '',f.stat().st_mtime_ns)
for f in sorted(set(files),key=order,reverse=True): print(f)
PY
}

restore_app() {
    if ! ensure_docker; then
        echo "Docker 环境异常，无法恢复"
        return 1
    fi

    local backups latest backup_file index selected tmp_dir volume_file
    mapfile -t backups < <(restore_backup_files)

    if [ "${#backups[@]}" -eq 0 ]; then
        echo "未在 $BACKUP_DIR 找到备份文件: sub2api-*.tar.gz"
        return 1
    fi

    latest="${backups[0]}"

    echo "检测到以下备份文件："
    index=1
    for backup_file in "${backups[@]}"; do
        echo "$index. $(basename "$backup_file")"
        index=$((index + 1))
    done

    echo ""
    IFS= read -r -p "请选择要恢复的备份编号（回车恢复最新备份，0取消）: " selected || { echo "已取消恢复"; return 0; }

    if [ "$selected" = "0" ]; then
        echo "已取消恢复"
        return 0
    fi

    if [ -z "$selected" ]; then
        backup_file="$latest"
    elif [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "${#selected}" -le 18 ] && [ "$selected" -le "${#backups[@]}" ]; then
        backup_file="${backups[$((selected - 1))]}"
    else
        echo "无效选择"
        return 1
    fi

    local confirm
    echo "将恢复备份: $backup_file"
    echo "恢复目标: $APP_DIR"
    echo "恢复会覆盖当前 Sub2API 配置及数据卷（包括数据库）。"
    IFS= read -r -p "确认恢复请输入 yes（其他输入取消）: " confirm || { echo "已取消恢复"; return 0; }
    if [ "$confirm" != "yes" ]; then
        echo "已取消恢复"
        return 0
    fi

    tmp_dir=$(mktemp -d)
    tar xzf "$backup_file" -C "$tmp_dir" || {
        rm -rf "$tmp_dir"
        echo "解压备份失败"
        return 1
    }

    if [ ! -f "$tmp_dir/app/app.tar.gz" ]; then
        echo "备份中缺少配置目录: app/app.tar.gz"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "$tmp_dir/volumes/postgres_data.tar.gz" ]; then
        echo "错误：备份中缺少 PostgreSQL 数据卷: volumes/postgres_data.tar.gz"
        echo "这个备份不包含用户、API Key、上游账号等核心数据库数据，已中止恢复。"
        echo "请换一个包含 volumes/postgres_data.tar.gz 的备份文件。"
        rm -rf "$tmp_dir"
        return 1
    fi

    if is_installed; then
        echo "正在停止当前 Sub2API..."
        cd "$APP_DIR" || {
            rm -rf "$tmp_dir"
            return 1
        }
        compose_cmd down || {
            rm -rf "$tmp_dir"
            return 1
        }
    else
        echo "未检测到当前 Sub2API 安装，将直接从备份恢复配置和数据。"
    fi

    echo "正在恢复配置目录..."
    rm -rf "$APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    tar xzf "$tmp_dir/app/app.tar.gz" -C "$(dirname "$APP_DIR")" || {
        rm -rf "$tmp_dir"
        echo "恢复配置目录失败"
        return 1
    }

    local logical_volume actual_volume legacy_volume_file
    for logical_volume in sub2api_data postgres_data redis_data; do
        volume_file="$tmp_dir/volumes/${logical_volume}.tar.gz"
        actual_volume=$(resolve_volume_name "$logical_volume")

        # 兼容旧备份：如果旧脚本曾把真实卷名打进文件名，也尝试读取真实卷名文件
        if [ ! -f "$volume_file" ]; then
            legacy_volume_file="$tmp_dir/volumes/${actual_volume}.tar.gz"
            [ -f "$legacy_volume_file" ] && volume_file="$legacy_volume_file"
        fi

        if [ -f "$volume_file" ]; then
            echo "正在恢复 Docker 卷: $logical_volume -> $actual_volume"
            docker volume rm "$actual_volume" >/dev/null 2>&1 || true
            docker volume create \
                --label "com.docker.compose.project=$(compose_project_name)" \
                --label "com.docker.compose.volume=$logical_volume" \
                "$actual_volume" >/dev/null || {
                rm -rf "$tmp_dir"
                echo "创建 Docker 卷失败: $actual_volume"
                return 1
            }
            docker run --rm \
                -v "$actual_volume:/volume" \
                -v "$(dirname "$volume_file"):/backup" \
                alpine sh -c "cd /volume && tar xzf /backup/$(basename "$volume_file")" || {
                    rm -rf "$tmp_dir"
                    echo "恢复 Docker 卷失败: $actual_volume"
                    return 1
                }
        else
            echo "跳过备份中不存在的 Docker 卷: $logical_volume"
        fi
    done

    rm -rf "$tmp_dir"

    echo "正在启动 Sub2API..."
    cd "$APP_DIR" || return 1
    compose_cmd up -d || return 1

    echo "恢复完成"
    echo "访问地址: http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
}

REMOTE_APP_CONTAINER="sub2api"
RETENTION_FILE="/home/备份/Sub2API/config/local-retention.json"
LOCK_FILE="/home/docker/.sub2api-backup.lock"
DATA_DIR="$APP_DIR"
error() { echo "错误：$*" >&2; }
exists() { docker container inspect "$REMOTE_APP_CONTAINER" >/dev/null 2>&1; }
locked() (
    umask 077
    mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
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
    backup_app || exit 1
    prune_local_backups
)
manual_remote_backup() { configure_local_retention && remote_backup_app; }
configure_local_retention() {
    local count
    while true; do
        IFS= read -r -p "本地备份保留数量（回车默认3）：" count || return 1
        count=${count:-3}
        if [[ $count =~ ^[1-9][0-9]{0,5}$ ]] && (( count <= 100000 )); then break; fi
        error "请输入1–100000的正整数。"
    done
    python3 - "$RETENTION_FILE" "$count" <<'PY'
import pathlib,os,json,sys
p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
fd=os.open(p,os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f: json.dump({'keep':int(sys.argv[2])},f)
os.chmod(p,0o600)
PY
}
prune_local_backups() {
    python3 - "$BACKUP_DIR" "$RETENTION_FILE" <<'PY'
import pathlib,sys,json,re
root=pathlib.Path(sys.argv[1]); setting=pathlib.Path(sys.argv[2])
keep=json.loads(setting.read_text()).get('keep',3) if setting.exists() else 3
if not isinstance(keep,int) or isinstance(keep,bool) or not 1<=keep<=100000: raise ValueError('本地保留数量无效，不执行删除')
files=sorted((p for p in root.iterdir() if re.fullmatch(r'sub2api-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name.replace('-',''),reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
REMOTE_DIR="/home/备份/Sub2API/config"
LOG_MAX_BYTES=2097152
LOG_BACKUPS=3
remote_engine() {
    python3 - "$REMOTE_DIR" "$BACKUP_DIR" "$@" 3<&0 <<'PY'
import os,sys,pathlib,json,re,subprocess,getpass,urllib.parse,tempfile,time,hashlib,tarfile
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
    if not s or any(c in s for c in '\r\n\0'): raise ValueError('输入为空或含非法字符')
    return s
def save(path,text):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as f:f.write(text)
    os.chmod(path,0o600)
def load():
    if not p.is_file() or not conf.is_file(): raise ValueError('尚未配置，请先选择1')
    return json.loads(p.read_text())
def rc(args): return run(['rclone','--config',str(conf),'--contimeout','15s','--timeout','2m','--retries','2']+args)
try:
    if mode=='configure':
        if p.exists() and ask('已有配置，输入yes确认覆盖')!='yes': sys.exit(0)
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
                if ask('输入yes确认保存SSH密码')!='yes': sys.exit(0)
                password=valid(getpass.getpass('SSH密码（隐藏输入）：'))
            dest=valid(ask('远端专用备份目录','/home/备份/Sub2API'))
            if not dest.startswith('/') or '..' in pathlib.PurePosixPath(dest).parts or dest=='/': raise ValueError('远端目录无效')
            print('将通过SFTP上传，保留全部远端备份，不删除远端文件：'+dest)
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            keys=run(['ssh-keyscan','-T','10','-p',port,host]).stdout
            if not keys.strip(): raise ValueError('未取得主机公钥')
            with tempfile.NamedTemporaryFile(mode='w',dir=root,delete=False) as f:f.write(keys); tmp=f.name
            try: print(run(['ssh-keygen','-lf',tmp]).stdout)
            finally: os.unlink(tmp)
            print('请与远端服务器管理员提供的指纹独立核对；扫描到的指纹本身不是信任证明。')
            if ask('核对无误请输入yes')!='yes': sys.exit(0)
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
            u=urllib.parse.urlsplit(endpoint)
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('','/'): raise ValueError('Endpoint必须为HTTPS API地址，无用户名/路径/查询参数')
            bucket=valid(ask('存储桶名称（需提前创建）'))
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,62}',bucket): raise ValueError('桶名无效')
            prefix=valid(ask('桶内专用备份前缀','备份/sub2api')).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                keep=ask('S3远端备份保留数量','3')
                if keep.isdigit() and 1<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入1–100000的正整数。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份sub2api时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
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
        owned_files=[p,conf,root/(kind+'-sent.json')]
        if kind in ('ssh','ssh-backup'): owned_files.append(known)
        for q in owned_files:
            if q.exists(): q.unlink()
        print('配置删除，远端和本地备份未删除。')
    elif mode=='test':
        d=load(); rc(['lsjson',d['dest'],'--max-depth','1']); print('远端目录读取测试通过（不代表写入权限已验证）')
    elif mode=='upload':
        d=load(); files=[x for x in backups.glob('sub2api-*.tar.gz') if x.is_file() and not x.is_symlink()]
        if not files: print('暂无归档，等待新备份。'); sys.exit(0)
        f=max(files,key=lambda x:x.stat().st_mtime_ns)
        if not re.fullmatch(r'sub2api-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',f.name): raise ValueError('归档名无效')
        st=f.stat()
        if time.time()-st.st_mtime<60: print('最新归档尚未稳定，稍后再传。'); sys.exit(0)
        with tarfile.open(f,'r:gz') as archive: archive.getmembers()
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
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(r'sub2api-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',x.get('Path',''))],key=lambda name:name.replace('-',''),reverse=True)
            keep=d.get('keep',3)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('S3保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化')
        save(state,json.dumps(signature))
        retention='SSH远端不删除' if kind in ('ssh','ssh-backup') else 'S3远端保留最新'+str(d.get('keep',3))+'份'
        print('上传并校验成功：'+f.name+'；'+retention+'；本地数量由本地备份设置独立控制。')
    else: raise ValueError('未知操作')
except (EOFError,KeyboardInterrupt):
    print('已取消。'); sys.exit(1)
except Exception as e:
    # 不回显rclone原始输出、S3凭据或完整配置。
    print('远程备份失败：'+(str(e) if isinstance(e,ValueError) else type(e).__name__),file=sys.stderr); sys.exit(1)
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
    local kind=$1 action=$2 calendar script unit="sub2api-backup-$1"
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || return 1
    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { error "定时备份需要systemd；配置可保留，仍可手动执行。"; return 1; }
    if [[ $action == remove ]]; then
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
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != '# Sub2API managed remote backup' ]]; then error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" <<'PY'
import sys,pathlib
unit,script,kind,calendar=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
service_content=('# Sub2API managed remote backup\n[Unit]\nDescription=Sub2API remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' --remote '+kind+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# Sub2API managed remote backup\n[Unit]\nDescription=Sub2API daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
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
    logger=logging.getLogger('sub2api'); logger.setLevel(logging.INFO); logger.addHandler(h)
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
            echo "Sub2APISSH 远程备份配置"
        else
            echo "Sub2API S3 API 兼容备份配置"
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
                    7) remote_engine test "$target" ;;
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
                unit='sub2api-backup-'+kind
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

# ==============================
# 菜单
# ==============================

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} == --remote ]]; then remote_locked_run "$2" "${3:-}"; exit $?; fi
    ensure_environment || exit 1
    repair_remote_schedules

while true; do
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear
    fi
    echo "=================================="
    echo "        Sub2API 管理脚本"
    echo "开源 AI API 中转平台，支持多账号管理、配额分发与请求转发"
    echo "部署组件：Sub2API + PostgreSQL + Redis"
    echo "开源地址："
    echo "https://github.com/Wei-Shaw/sub2api"
    echo "=================================="
    remote_summary
    echo "默认访问端口：${APP_PORT}，容器内部端口：8080"
    echo "------------------------"
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份/home/备份/Sub2API/"
    echo "4. 恢复（自动扫描home及备份目录）"
    echo "5. SSH 远程备份配置"
    echo "6. S3 API 兼容备份配置"
    echo "9. 卸载"
    echo "0. 退出"
    echo
    read -r -p "请输入选项: " choice || { echo "已退出"; exit 0; }

    case $choice in
        1) locked install_app; pause ;;
        2) locked update_app; pause ;;
        3) locked manual_remote_backup; pause ;;
        4) locked restore_app; pause ;;
        5) remote_menu ssh; continue ;;
        6) remote_menu s3; continue ;;
        9) locked uninstall_app; pause ;;
        0) echo "已退出"; exit 0 ;;
        *) echo "无效选项"; pause ;;
    esac
done

fi
