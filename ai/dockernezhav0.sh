#!/bin/bash

NEZHA_DIR="/opt/nezha/dashboard"
BACKUP_DIR="/home/备份/nezhav0"
IMAGE="zaixiangjian/nezhav0:latest"
CONTAINER_NAME="nezha-dashboard"

# =========================
# Docker 安装检测
# =========================
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        return
    fi

    echo "未检测到 Docker，正在安装..."
    curl -fsSL https://get.docker.com | bash

    systemctl enable docker
    systemctl start docker

    echo "Docker 安装完成"
}

# =========================
# 安装
# =========================
install_nezha() {

    install_docker
    mkdir -p "${NEZHA_DIR}/data"

    echo "请输入 GitHub 用户名:"
    read -r ADMIN

    echo "请输入 GitHub Client ID:"
    read -r CLIENT_ID

    echo "请输入 GitHub Client Secret:"
    read -r CLIENT_SECRET

    read -rp "请输入面板端口 (默认 8008): " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-8008}

    read -rp "请输入 Agent RPC 端口 (默认 5555): " AGENT_PORT
    AGENT_PORT=${AGENT_PORT:-5555}

    cat > "${NEZHA_DIR}/data/config.yaml" <<EOF
language: zh-CN

oauth2:
  type: github
  admin: ${ADMIN}
  clientid: ${CLIENT_ID}
  clientsecret: ${CLIENT_SECRET}
EOF

    echo "📦 拉取镜像..."
    docker pull ${IMAGE}

    echo "🧹 删除旧容器..."
    docker rm -f ${CONTAINER_NAME} >/dev/null 2>&1

    echo "🚀 启动容器..."

    docker run -d \
        --name ${CONTAINER_NAME} \
        --restart always \
        -p ${PANEL_PORT}:80 \
        -p ${AGENT_PORT}:${AGENT_PORT} \
        -v "${NEZHA_DIR}/data:/dashboard/data" \
        -e TZ=Asia/Shanghai \
        ${IMAGE}

    echo "✅ 安装完成"
}

# =========================
# 启动
# =========================
start_nezha() {
    docker start ${CONTAINER_NAME}
}

# =========================
# 停止
# =========================
stop_nezha() {
    docker stop ${CONTAINER_NAME}
}

# =========================
# 999 备份
# =========================
backup_nezha() (
    local restart=0 archive complete=0
    command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "Docker不可用"; exit 1; }
    [[ -d $NEZHA_DIR ]] || { echo "没有应用数据"; exit 1; }
    mkdir -p "$BACKUP_DIR" || exit 1
    archive=$(python3 - "$BACKUP_DIR" <<'PY'
import os,sys,time
while True:
 p=sys.argv[1]+'/nzhav0-'+time.strftime('%Y%m%d_%H%M%S')+'.tar.gz'
 try:
  fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);os.close(fd);print(p);break
 except FileExistsError:time.sleep(1)
PY
    ) || exit 1
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null) != true ]] || restart=1
    cleanup() {
        local rc=$?
        trap - EXIT INT TERM HUP
        (( complete )) || rm -f -- "$archive"
        if (( restart )); then docker start "$CONTAINER_NAME" >/dev/null || rc=1; fi
        exit "$rc"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    (( ! restart )) || docker stop -t 30 "$CONTAINER_NAME" >/dev/null || exit 1
    tar -czf "$archive" -C "$NEZHA_DIR" . || exit 1
    complete=1
    echo "备份完成：$archive（可能含OAuth凭据，请妥善保管）"
)

# =========================
# 8 恢复（支持端口修改）
# =========================
restore_nezha() {

    install_docker
    mkdir -p "${BACKUP_DIR}"

    echo "🔍 扫描备份..."

    local -a BACKUPS=()
    mapfile -d '' -t BACKUPS < <(python3 - <<'PY'
import pathlib,os
files=[]
for root in ('/home','/home/备份/nezhav0','/home/备份'):
 p=pathlib.Path(root)
 if p.is_dir(): files.extend(f for f in p.glob('nzhav0-*.tar.gz') if f.is_file() and not f.is_symlink())
for f in sorted(set(files),key=lambda f:(f.stat().st_mtime_ns,f.name),reverse=True):
 os.write(1,os.fsencode(f)+b'\0')
PY
    )

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "❌ 没有备份"
        return
    fi

    i=1
    for file in "${BACKUPS[@]}"; do
        echo "$i) $(basename "$file")"
        ((i++))
    done

    echo "回车=最新，0=取消"
    IFS= read -r -p "请选择: " CHOICE || return 0
    [[ $CHOICE != 0 ]] || return 0
    CHOICE=${CHOICE:-1}
    [[ $CHOICE =~ ^[1-9][0-9]{0,5}$ ]] && (( CHOICE <= ${#BACKUPS[@]} )) || { echo "备份编号无效。"; return 1; }
    FILE="${BACKUPS[$((CHOICE-1))]}"

    [[ -f $FILE ]] || { echo "备份编号无效。"; return 1; }
    echo "📦 使用: $(basename "$FILE")"
    echo "将替换 ${NEZHA_DIR} 中的全部数据并重建容器。"
    local confirm
    IFS= read -r -p "输入小写 yes 确认恢复：" confirm || return 0
    [[ $confirm == yes ]] || { echo "已取消恢复。"; return 0; }

    # =========================
    # 端口设置（关键）
    # =========================
    read -rp "请输入面板端口 (默认 8008): " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-8008}

    read -rp "请输入Agent端口 (默认 5555): " AGENT_PORT
    AGENT_PORT=${AGENT_PORT:-5555}

    echo "🛑 停止容器..."
    docker stop ${CONTAINER_NAME} >/dev/null 2>&1
    docker rm ${CONTAINER_NAME} >/dev/null 2>&1

    echo "🧹 清理旧数据..."
    rm -rf "${NEZHA_DIR}"
    mkdir -p "${NEZHA_DIR}/data"

    echo "📥 解压备份..."
    tar -zxf "$FILE" -C "${NEZHA_DIR}"

    # 如果 config 丢失自动补
    if [ ! -f "${NEZHA_DIR}/data/config.yaml" ]; then
        cat > "${NEZHA_DIR}/data/config.yaml" <<EOF
language: zh-CN

oauth2:
  type: github
  admin: admin
  clientid: xxx
  clientsecret: xxx
EOF
    fi

    echo "🚀 重新启动容器..."

    docker run -d \
        --name ${CONTAINER_NAME} \
        --restart always \
        -p ${PANEL_PORT}:80 \
        -p ${AGENT_PORT}:${AGENT_PORT} \
        -v "${NEZHA_DIR}/data:/dashboard/data" \
        -e TZ=Asia/Shanghai \
        ${IMAGE}

    echo "✅ 恢复完成"
}

# =========================
# 卸载
# =========================
uninstall_nezha() {

    echo "将删除容器、${NEZHA_DIR} 数据目录和${IMAGE}镜像；保留备份及远端配置。"
    IFS= read -r -p "输入小写 yes 确认卸载：" c || return 0
    [[ "$c" == yes ]] || { echo "已取消。"; return 0; }

    docker stop ${CONTAINER_NAME} >/dev/null 2>&1
    docker rm ${CONTAINER_NAME} >/dev/null 2>&1

    rm -rf "${NEZHA_DIR}"
    docker rmi ${IMAGE} >/dev/null 2>&1

    echo "✔ 已卸载完成"
}

APP_DIR="$NEZHA_DIR"
REMOTE_APP_CONTAINER="nezha-dashboard"
RETENTION_FILE="/home/备份/nezhav0/config/local-retention.json"
LOCK_FILE="/home/docker/.nezhav0-backup.lock"
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
    backup_nezha || exit 1
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
files=sorted((p for p in root.iterdir() if re.fullmatch(r'nzhav0-\d{8}_\d{6}\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name,reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
REMOTE_DIR="/home/备份/nezhav0/config"
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
            dest=valid(ask('远端专用备份目录','/home/备份/nezhav0'))
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
            prefix=valid(ask('桶内专用备份前缀','备份/nezhav0')).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                keep=ask('S3远端备份保留数量','3')
                if keep.isdigit() and 1<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入1–100000的正整数。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份nezhav0时间戳归档')
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
        d=load(); files=[x for x in backups.glob('nzhav0-*.tar.gz') if x.is_file() and not x.is_symlink()]
        if not files: print('暂无归档，等待新备份。'); sys.exit(0)
        f=max(files,key=lambda x:x.stat().st_mtime_ns)
        if not re.fullmatch(r'nzhav0-\d{8}_\d{6}\.tar\.gz',f.name): raise ValueError('归档名无效')
        st=f.stat()
        if time.time()-st.st_mtime<60: print('最新归档尚未稳定，稍后再传。'); sys.exit(0)
        state=root/(kind+'-sent.json')
        identity=[f.name,st.st_size,st.st_mtime_ns,st.st_ctime_ns,st.st_dev,st.st_ino]
        previous=json.loads(state.read_text()) if state.exists() else None
        if isinstance(previous,dict) and previous.get('version')==2 and previous.get('identity')==identity:
            print('最新归档已传送，跳过。'); sys.exit(0)
        with tarfile.open(f,'r:gz') as archive: archive.getmembers()
        digest_hash=hashlib.sha256()
        with f.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''): digest_hash.update(chunk)
        digest=digest_hash.hexdigest()
        signature=[f.name,st.st_size,digest]
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity: raise ValueError('归档在校验中发生变化')
        record={'version':2,'identity':identity,'signature':signature}
        if previous==signature or (isinstance(previous,dict) and previous.get('signature')==signature):
            save(state,json.dumps(record))
            print('最新归档已传送，跳过。'); sys.exit(0)
        target=d['dest'].rstrip('/')+'/'+f.name
        rc(['copyto',str(f),target,'--immutable','--s3-upload-cutoff','32Mi','--s3-chunk-size','8Mi'])
        info=json.loads(rc(['lsjson',target,'--stat']).stdout)
        if info.get('IsDir') or info.get('Size')!=f.stat().st_size: raise ValueError('上传后远端大小校验失败；未执行清理')
        # 按字节比较本次归档；成功后才允许远端保留清理。
        rc(['check',str(f.parent),d['dest'],'--include',f.name,'--one-way','--download'])
        if kind=='s3':
            listing=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(r'nzhav0-\d{8}_\d{6}\.tar\.gz',x.get('Path',''))],reverse=True)
            keep=d.get('keep',3)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('S3保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化')
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity: raise ValueError('归档在传送中发生变化；未提交成功记录')
        save(state,json.dumps(record))
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
    local kind=$1 action=$2 calendar script unit="nezhav0-backup-$1"
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
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != '# nezhav0 managed remote backup' ]]; then error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" <<'PY'
import sys,pathlib
unit,script,kind,calendar=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
service_content=('# nezhav0 managed remote backup\n[Unit]\nDescription=nezhav0 remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' --remote '+kind+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# nezhav0 managed remote backup\n[Unit]\nDescription=nezhav0 daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
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
    logger=logging.getLogger('nezhav0'); logger.setLevel(logging.INFO); logger.addHandler(h)
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
            echo "nezhav0SSH 远程备份配置"
        else
            echo "nezhav0 S3 API 兼容备份配置"
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
                unit='nezhav0-backup-'+kind
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


# =========================
# 菜单
# =========================
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} == --remote ]]; then remote_locked_run "$2" "${3:-}"; exit $?; fi
    ensure_environment || exit 1
    repair_remote_schedules
while true; do
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "========================"
    remote_summary
    echo "1  安装"
    echo "2  启动"
    echo "3  停止"
    echo "4  卸载"
    echo "5. SSH 远程备份配置"
    echo "6. S3 API 兼容备份配置"
    echo "8. 恢复"
    echo "9. 备份"
    echo "0  退出"
    echo "========================"

    IFS= read -r -p "请选择: " num || { echo "已退出"; exit 0; }

    case $num in
        1|1234) locked install_nezha ;;
        2) locked start_nezha ;;
        3) locked stop_nezha ;;
        4) locked uninstall_nezha ;;
        8) locked restore_nezha ;;
        9) locked manual_remote_backup ;;
        5) remote_menu ssh; continue ;;
        6) remote_menu s3; continue ;;
        0) exit 0 ;;
        *) echo "输入错误" ;;
    esac

    read -rp "回车继续..."
done

fi
