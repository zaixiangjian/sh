#!/bin/bash

set -o pipefail

APP_NAME="CLIProxyAPI"
APP_DIR="/home/docker/CLIProxyAPI"
BACKUP_DIR="/home/备份/CLIProxyAPI"
PORT="8317"

install_app() {

    echo
    echo "开始安装 ${APP_NAME}"
    echo

    mkdir -p "$APP_DIR"

    cd "$APP_DIR"

    if [ ! -f docker-compose.yml ]; then
        git clone https://github.com/router-for-me/CLIProxyAPI.git .
    fi

    cp -n config.example.yaml config.yaml
    cp -n .env.example .env

    read -s -p "请输入管理密钥: " KEY
    echo

    sed -i -E '
    s/^(\s*)allow-remote:\s*false\s*$/\1allow-remote: true/
    s/^(\s*)secret-key:\s*""\s*$/\1secret-key: "'"$KEY"'"/
    ' config.yaml

    docker compose up -d

    echo
    echo "=================================="
    echo "安装完成"
    echo "WebUI:"
    echo "http://你的IP:${PORT}/management.html"
    echo "=================================="
    echo
}

update_app() {

    echo
    echo "更新 ${APP_NAME}"
    echo

    if [ ! -d "$APP_DIR" ]; then
        echo "未安装"
        return
    fi

    cd "$APP_DIR"

    docker compose down || true

    git pull

    docker compose pull

    docker compose up -d

    echo
    echo "更新完成"
    echo
}

backup_app() {

    echo

    if [ ! -d "$APP_DIR" ]; then
        echo "未安装"
        return
    fi

    BACKUP_FILE="${BACKUP_DIR}/CPA-$(date +%Y-%m-%d-%H%M%S).tar.gz"
    WAS_RUNNING="no"

    echo "开始备份..."
    echo "为保证文件一致性，将先停止容器再备份。"
    echo

    if [ -f "$APP_DIR/docker-compose.yml" ]; then
        if docker inspect -f '{{.State.Running}}' cli-proxy-api 2>/dev/null | grep -q true; then
            WAS_RUNNING="yes"
        fi

        echo "停止容器..."
        cd "$APP_DIR"
        docker compose down || true
        sleep 2
    fi

    tar -czf "$BACKUP_FILE" -C /home/docker CLIProxyAPI
    TAR_STATUS=$?

    if [ "$WAS_RUNNING" = "yes" ] && [ -f "$APP_DIR/docker-compose.yml" ]; then
        echo "启动容器..."
        cd "$APP_DIR"
        docker compose up -d
    fi

    if [ $TAR_STATUS -ne 0 ]; then
        echo "备份失败"
        return 1
    fi

    echo "备份完成:"
    echo "$BACKUP_FILE"
    echo
}

restore_backup_files() {
    python3 - <<'PY'
import pathlib,re,datetime
files=[]
for root in ('/home','/home/备份/CLIProxyAPI','/home/备份'):
    p=pathlib.Path(root)
    if p.is_dir(): files.extend(f for f in p.glob('CPA-*.tar.gz') if f.is_file() and not f.is_symlink())
def order(f):
    token=f.name[len('CPA-'):-7].replace('-','')
    return (token if re.fullmatch(r'\d{14}',token) else '',f.stat().st_mtime_ns)
for f in sorted(set(files),key=order,reverse=True): print(f)
PY
}

restore_app() {

    local backups selected index FILE
    mapfile -t backups < <(restore_backup_files)

    if [ "${#backups[@]}" -eq 0 ]; then
        echo "未在 $BACKUP_DIR 找到备份文件: CPA-*.tar.gz"
        return 0
    fi

    echo
    echo "检测到以下备份文件："
    for index in "${!backups[@]}"; do
        echo "$((index + 1)). ${backups[$index]}"
    done
    echo

    IFS= read -r -p "请选择要恢复的备份编号（回车恢复最新备份，0取消）: " selected || { echo "已取消恢复"; return 0; }
    if [ "$selected" = "0" ]; then
        echo "已取消恢复"
        return 0
    fi
    selected="${selected:-1}"
    local backup_count="${#backups[@]}"
    if ! [[ "$selected" =~ ^[1-9][0-9]*$ ]] || [ "${#selected}" -gt "${#backup_count}" ] || [ "$selected" -gt "$backup_count" ]; then
        echo "无效备份编号"
        return 0
    fi
    FILE="${backups[$((selected - 1))]}"

    if [ ! -f "$FILE" ]; then
        echo "备份文件不存在"
        return 0
    fi

    local confirm
    echo "备份文件: $FILE"
    echo "恢复目标: $APP_DIR"
    echo "恢复会替换当前配置、认证数据及安装目录，并重新启动容器。"
    IFS= read -r -p "确认恢复请输入 yes（其他输入取消）: " confirm || { echo "已取消恢复"; return 0; }
    if [ "$confirm" != "yes" ]; then
        echo "已取消恢复"
        return 0
    fi

    echo
    echo "开始恢复:"
    echo "$FILE"
    echo

    # 如果已安装
    if [ -d "$APP_DIR" ]; then

        echo "检测到已安装"

        cd "$APP_DIR"

        echo "停止容器..."

        docker compose down || true

        echo "删除旧目录..."

        rm -rf "$APP_DIR"
    fi

    echo
    echo "恢复备份文件..."
    echo

    mkdir -p /home/docker

    tar -xzf "$FILE" -C /home/docker

    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        echo "恢复失败"
        return
    fi

    echo "启动容器..."

    cd "$APP_DIR"

    docker compose up -d

    echo
    echo "=================================="
    echo "恢复完成"
    echo "WebUI:"
    echo "http://你的IP:${PORT}/management.html"
    echo "=================================="
    echo
}

uninstall_app() {
    local confirm
    echo "⚠️ 卸载将删除 ${APP_NAME} 容器、镜像、数据卷及安装目录，配置和认证数据将丢失。"
    IFS= read -r -p "确认卸载请输入 yes（其他输入取消）: " confirm || return 0
    if [ "$confirm" != "yes" ]; then
        echo "已取消卸载"
        return 0
    fi

    echo
    echo "卸载 ${APP_NAME}"
    echo

    if [ ! -d "$APP_DIR" ]; then
        echo "未安装"
        return
    fi

    cd "$APP_DIR"

    docker compose down --rmi all --volumes || true

    cd /home/docker

    rm -rf "$APP_DIR"

    echo
    echo "已删除:"
    echo "- 容器"
    echo "- 网络"
    echo "- 卷"
    echo "- ${APP_DIR}"
    echo
}


REMOTE_APP_CONTAINER="cli-proxy-api"
RETENTION_FILE="/home/备份/CLIProxyAPI/config/local-retention.json"
LOCK_FILE="$BACKUP_DIR/config/backup.lock"
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
files=sorted((p for p in root.iterdir() if re.fullmatch(r'CPA-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name.replace('-',''),reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
REMOTE_DIR="/home/备份/CLIProxyAPI/config"
LOG_MAX_BYTES=2097152
LOG_BACKUPS=3
single_remote_engine() {
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
            dest=valid(ask('远端专用备份目录','/home/备份/CLIProxyAPI'))
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
            prefix=valid(ask('桶内专用备份前缀','备份/cliproxyapi')).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                keep=ask('S3远端备份保留数量','3')
                if keep.isdigit() and 1<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入1–100000的正整数。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份cliproxyapi时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+access+'\nsecret_access_key = '+secret+'\nendpoint = '+endpoint+'\nregion = '+region+'\nforce_path_style = true\nsign_accept_encoding = false\n'
        if d['action']=='backup':
            while True:
                print('备份间隔（1h/2h/4h/6h/8h/12h，1d/2d/3d/5d/7d/14d/30d）')
                interval=(input('h等于小时，d等于天[默认 7d]：').strip() or '7d')
                if interval in ('1h','2h','4h','6h','8h','12h','1d','2d','3d','5d','7d','14d','30d'): break
                print('请输入完整间隔，例如4h或2d。')
            d['interval']=interval
            if interval.endswith('h'):
                hours=int(interval[:-1])
                minute=ask('北京时间每个周期的分钟','0')
                if not minute.isdigit() or not 0<=int(minute)<=59: raise ValueError('分钟无效')
                d['calendar']='*-*-* 00/'+str(hours)+':'+f'{int(minute):02}'+':00 Asia/Shanghai'
            else:
                hour=ask('每日备份北京时间小时','5'); minute=ask('分钟','0')
                if not hour.isdigit() or not minute.isdigit() or not 0<=int(hour)<=23 or not 0<=int(minute)<=59: raise ValueError('时间无效')
                d['calendar']='*-*-* '+f'{int(hour):02}:{int(minute):02}:00 Asia/Shanghai'
                d['anchor_day']=int((time.time()+8*3600)//86400)
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
        d=load(); interval=d.get('interval','7d')
        if d.get('action','backup')=='backup' and interval.endswith('d'):
            days=int(interval[:-1]); today=int((time.time()+(8*3600 if 'Asia/Shanghai' in d.get('calendar','') else 0))//86400)
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
        d=load(); files=[x for x in backups.glob('CPA-*.tar.gz') if x.is_file() and not x.is_symlink()]
        if not files: print('暂无归档，等待新备份。'); sys.exit(0)
        f=max(files,key=lambda x:x.stat().st_mtime_ns)
        if not re.fullmatch(r'CPA-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',f.name): raise ValueError('归档名无效')
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
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(r'CPA-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',x.get('Path',''))],key=lambda name:name.replace('-',''),reverse=True)
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

# 配置修改顺序：配置锁→对应任务锁，均非阻塞；不同应用路径独立。
single_configuration_locked() (
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

delete_remote_task() {
    remote_schedule_unlocked "$1" remove && remote_engine delete "$1"
}
single_remote_schedule_unlocked() {
    local kind=$1 action=$2 calendar script unit="${AI_APP_ID}-backup-$1"
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
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != '# CLIProxyAPI managed remote backup' ]]; then error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" "${AIR_TASK_NAME:-}" <<'PY'
import sys,pathlib
unit,script,kind,calendar,task_name=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
remote_args=('--remote-task '+task_name+' '+kind) if task_name else ('--remote '+kind)
service_content=('# CLIProxyAPI managed remote backup\n[Unit]\nDescription=CLIProxyAPI remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' '+remote_args+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# CLIProxyAPI managed remote backup\n[Unit]\nDescription=CLIProxyAPI daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
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
    logger=logging.getLogger('cliproxyapi'); logger.setLevel(logging.INFO); logger.addHandler(h)
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
single_remote_locked_run() (
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




AI_APP_ID='cliproxyapi'
AI_APP_LABEL='CLIProxyAPI'
# Named-task context: old singleton configurations remain usable unchanged.
task_context() {
    local selector="$1"
    AIR_BASE_CONFIG="$BACKUP_DIR/config"
    AIR_BASE_APP_ID="${AIR_BASE_APP_ID:-$AI_APP_ID}"
    if [[ "$selector" == *@* ]]; then
        AIR_TASK_KIND="${selector%%@*}"
        AIR_TASK_NAME="${selector#*@}"
        [[ "$AIR_TASK_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { error '配置名称无效'; return 1; }
        [[ "$AIR_TASK_KIND" == ssh-backup || "$AIR_TASK_KIND" == ssh || "$AIR_TASK_KIND" == s3 ]] || return 1
        REMOTE_DIR="$AIR_BASE_CONFIG/tasks/$AIR_TASK_NAME"
        RETENTION_FILE="$REMOTE_DIR/local-retention.json"
        AI_APP_ID="$AIR_BASE_APP_ID-task-$AIR_TASK_NAME"
    else
        AIR_TASK_KIND="$selector"
    fi
}
remote_engine() (
    local mode="$1" selector="$2"; shift 2
    task_context "$selector" || exit 1
    single_remote_engine "$mode" "$AIR_TASK_KIND" "$@"
)
configuration_locked() (
    local selector="$1"; shift
    task_context "$selector" || exit 1
    single_configuration_locked "$AIR_TASK_KIND" "$@"
)
remote_schedule_unlocked() (
    local selector="$1"; shift
    task_context "$selector" || exit 1
    single_remote_schedule_unlocked "$AIR_TASK_KIND" "$@"
)
remote_locked_run() (
    local selector="$1"; shift
    task_context "$selector" || exit 1
    single_remote_locked_run "$AIR_TASK_KIND" "$@"
)
task_selectors() {
    python3 - "$BACKUP_DIR/config" "${1:-all}" <<'PY_NTASKS'
import sys,json,re
from pathlib import Path
root=Path(sys.argv[1]); scope=sys.argv[2]
kinds=['ssh-backup','ssh'] if scope=='ssh' else ['s3'] if scope=='s3' else ['ssh-backup','ssh','s3']
for kind in kinds:
    if (root/(kind+'.json')).is_file() and (root/(kind+'.conf')).is_file(): print(kind)
    for folder in sorted((root/'tasks').glob('*')):
        if folder.is_symlink() or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}',folder.name): continue
        if (folder/(kind+'.json')).is_file() and (folder/(kind+'.conf')).is_file(): print(kind+'@'+folder.name)
PY_NTASKS
}
named_summary() {
    local scope="${1:-all}" selector dir kind idx=0 title group
    local -a selectors=()
    mapfile -t selectors < <(task_selectors "$scope")
    for group in ssh-backup ssh s3; do
        [[ "$scope" != ssh || "$group" != s3 ]] || continue
        [[ "$scope" != s3 || "$group" == s3 ]] || continue
        case "$group" in ssh-backup) title=SSH备份;; ssh) title=传送任务;; s3) title='S3 API 兼容传送任务';; esac
        echo "$title"; echo '备注名   状态'
        local found=0
        for selector in "${selectors[@]}"; do
            kind="${selector%%@*}"; [ "$kind" = "$group" ] || continue
            idx=$((idx+1));found=1
            dir="$BACKUP_DIR/config"
            [[ "$selector" != *@* ]] || dir="$dir/tasks/${selector#*@}"
            python3 - "$dir/$kind.json" "$idx" "$selector" "$AI_APP_ID" <<'PY_NSUMMARY'
import sys,json,subprocess
p,index,selector,base_app=sys.argv[1:]; d=json.load(open(p));kind=selector.split('@')[0]
app=base_app+'-task-'+selector.split('@')[1] if '@' in selector else base_app
unit=app+'-backup-'+kind+'.timer'
try: active=subprocess.run(['systemctl','is-active','--quiet',unit],capture_output=True,timeout=2).returncode==0
except (OSError,subprocess.TimeoutExpired): active=False
state='\033[32m正常（定时运行中）\033[0m' if active else '\033[33m异常（定时未运行）\033[0m'
name=''.join(c for c in str(d.get('name',selector)) if c.isprintable())
interval=str(d.get('interval','7d')); unit_label='小时' if interval.endswith('h') else '天'
timing='每30秒检测新备份并传送' if d.get('action')=='transfer' else '每'+interval[:-1]+unit_label+' '+str(d.get('calendar',''))+'（按配置时区）'
print(index+'. '+name+'   '+state+'  '+timing)
PY_NSUMMARY
        done
        [ "$found" = 1 ] || echo 暂无
        [ "$group" != ssh-backup ] && echo '==================================' || echo '------------------------'
    done
}
repair_remote_schedules() {
    local selector failed=0
    while IFS= read -r selector; do
        [ -n "$selector" ] || continue
        remote_schedule "$selector" enable >/dev/null || { error "修复 $selector 失败"; failed=1; }
    done < <(task_selectors all)
    return "$failed"
}
remote_menu() {
    local scope="$1" choice name target selected confirm
    local -a selectors=()
    ensure_environment remote || return 1
    repair_remote_schedules
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo '=================================='
        echo "$AI_APP_LABEL ${scope^^} 远程备份配置"
        echo '=================================='
        named_summary "$scope"
        if [ "$scope" = ssh ]; then
            echo '1. 添加SSH备份任务（定时备份并上传）'
            echo '2. 添加传送任务（有新备份直接传送，不打包）'
        else echo '1. 添加S3任务（有新备份直接传送，不打包）'; fi
        echo '7. 测试远端读取';echo '8. 立即执行任务';echo '9. 删除任务（保留备份）';echo '0. 返回'
        read -r -p '请输入选项：' choice || return 0
        case "$choice" in
            1|2)
                if [ "$scope" = s3 ]; then [ "$choice" = 1 ] || continue; target=s3
                elif [ "$choice" = 1 ]; then target=ssh-backup; else target=ssh; fi
                read -r -p '配置名称（小写字母开头，数字/横线/下划线，最多32位）: ' name || return 0
                [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo '名称无效'; continue; }
                named_task_available "$name" || continue
                configuration_locked "$target@$name" named_configure "$target" || echo '任务添加未完成，已保存配置可在重开菜单时重试定时修复。'
                ;;
            7|8|9)
                mapfile -t selectors < <(task_selectors "$scope")
                read -r -p '任务编号（0返回）: ' selected || return 0
                [ "$selected" != 0 ] || continue
                [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#selectors[@]}" ] || { echo '编号无效'; continue; }
                target="${selectors[$((selected-1))]}"
                case "$choice" in
                    7) remote_engine test "$target" ;;
                    8) remote_locked_run "$target" ;;
                    9) read -r -p '输入yes删除该任务（保留备份）: ' confirm; [ "$confirm" != yes ] || configuration_locked "$target" delete_remote_task "${target%%@*}" ;;
                esac
                ;;
            0) return 0 ;;
            *) echo 无效选项 ;;
        esac
    done
}
named_task_available() {
    python3 - "$BACKUP_DIR/config/tasks/$1" <<'PY_AVAILABLE'
import os,sys,stat,fcntl,json
from pathlib import Path
p=Path(sys.argv[1]);held=[]
try:
    if p.is_symlink():raise ValueError('配置目录不能是链接')
    if not p.exists():sys.exit(0)
    if not p.is_dir():raise ValueError('配置路径不是目录')
    for f in p.iterdir():
        locks=('configuration.lock','ssh.lock','ssh-backup.lock','s3.lock')
        allowed=locks+('local-retention.json','ssh-known-hosts','ssh-backup-known-hosts','s3-known-hosts')
        if f.name not in allowed:raise ValueError('同名配置目录 '+str(p)+' 存在文件 '+repr(f.name)+'，未覆盖')
        fd=os.open(f,(os.O_RDWR if f.name in locks else os.O_RDONLY)|os.O_NOFOLLOW);held.append(fd)
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError('配置/锁文件不安全')
        if f.name in locks:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        elif f.name=='local-retention.json':
            if st.st_size>4096:raise ValueError('保留数量配置过大')
            with os.fdopen(os.dup(fd)) as stream:v=json.load(stream)
            if not isinstance(v,dict) or set(v)!={'keep'} or type(v['keep']) is not int or not 1<=v['keep']<=100000:raise ValueError('保留数量配置无效')
        elif st.st_size>1048576:raise ValueError('主机指纹文件过大')
except BlockingIOError:sys.exit('同名任务正在配置或执行，请稍后重试')
except (ValueError,OSError) as e:sys.exit(str(e))
finally:
    for fd in held:os.close(fd)
PY_AVAILABLE
}

named_configure() {
    local kind="$1" existing
    for existing in ssh ssh-backup s3; do
        if [[ -e "$REMOTE_DIR/$existing.json" || -e "$REMOTE_DIR/$existing.conf" ]]; then
            error '本应用同名任务配置已存在，未覆盖。'; return 1
        fi
    done
    if [ "$kind" = ssh-backup ]; then configure_local_retention || return 1; fi
    remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    remote_schedule_unlocked "$kind" enable
}



show_menu() {

    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear
    fi

    echo "=================================="
    echo "        CLIProxyAPI 管理脚本"
    echo "开源 AI API 代理，将 CLI 账号接入 OpenAI、Gemini、Claude 兼容接口"
    echo "部署组件：CLIProxyAPI（Docker）"
    echo "开源地址："
    echo "https://github.com/router-for-me/CLIProxyAPI"
    echo "=================================="
    named_summary all
    echo "默认访问端口：${PORT}"
    echo "管理页面：http://你的IP:${PORT}/management.html"
    echo "------------------------"
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份/home/备份/CLIProxyAPI/"
    echo "4. 恢复（自动扫描home及备份目录）"
    echo "5. SSH 远程备份配置"
    echo "6. S3 API 兼容备份配置"
    echo "9. 卸载"
    echo "0. 退出"
    echo
}

runtime_layout_init() {
    python3 - "$BACKUP_DIR/config" /home/docker/.cliproxyapi-backup.lock <<'PY_LAYOUT'
import os,sys,fcntl,stat
from pathlib import Path
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True,mode=0o700)
if root.is_symlink():raise SystemExit('config不能是链接')
os.chmod(root,0o700)
src=Path(sys.argv[2]);dst=root/'backup.lock'
with (root/'.layout-migration.lock').open('a') as guard:
 fcntl.flock(guard,fcntl.LOCK_EX)
 if src.is_symlink():
  if src.resolve()!=dst.resolve():raise SystemExit('旧锁链接冲突')
 elif src.exists():
  if dst.exists():raise SystemExit('新旧锁同时存在，拒绝迁移')
  fd=os.open(src,os.O_RDWR|os.O_NOFOLLOW)
  try:
   s=os.fstat(fd)
   if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1:raise SystemExit('锁文件不安全')
   fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
   src.rename(dst);src.symlink_to(dst)
  finally:os.close(fd)
PY_LAYOUT
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    runtime_layout_init || exit 1
    if [[ ${1:-} == --remote-task ]]; then
        remote_locked_run "${3:-}@${2:-}" "${4:-}"
        return $?
    fi
    if [[ ${1:-} == --remote ]]; then remote_locked_run "$2" "${3:-}"; exit $?; fi
    ensure_environment || exit 1
    repair_remote_schedules

while true; do

    show_menu

    read -r -p "请输入选项: " CHOICE || { echo "已退出"; exit 0; }

    case $CHOICE in

        1)
            locked install_app
            ;;

        2)
            locked update_app
            ;;

        3)
            locked manual_remote_backup
            ;;

        4)
            locked restore_app
            ;;

        5) remote_menu ssh; continue ;;
        6) remote_menu s3; continue ;;
        9)
            locked uninstall_app
            ;;

        0)
            echo
            echo "已退出"
            echo
            exit 0
            ;;

        *)
            echo
            echo "无效选项"
            echo
            ;;
    esac

    read -p "按回车继续..."

done

fi
