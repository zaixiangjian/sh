#!/usr/bin/env bash
# Emby Docker manager. Back up configuration only, never mounted media.
set -o pipefail
umask 077
APP_DIR=/home/docker/Emby
BACKUP_DIR=/home/备份/Emby
BACKUP_PREFIX=Emby-
IMAGE=emby/embyserver:latest
NAME=emby
PORT=8096
AI_APP_ID=emby
AI_APP_LABEL=Emby
REMOTE_DIR="$BACKUP_DIR/config"
LOCK_FILE="$BACKUP_DIR/config/backup.lock"
RETENTION_FILE="$REMOTE_DIR/local-retention.json"
confirm() { local answer; IFS= read -r -p '输入小写yes确认：' answer && [[ $answer == yes ]]; }
native() {
python3 - "$1" "$APP_DIR" "$BACKUP_DIR" "$NAME" "$IMAGE" "${2:-}" "${3:-}" <<'PY_EMBY'
import sys,os,json,subprocess,pathlib,time,urllib.request,tarfile,tempfile,datetime,shutil,sqlite3
mode,root,backups,name,image,arg,media=sys.argv[1:];root=pathlib.Path(root);backups=pathlib.Path(backups)
def docker(*args):
 p=subprocess.run(['docker',*args],capture_output=True,text=True)
 if p.returncode:raise RuntimeError('Docker '+args[0]+' 失败，请在本机检查；未回显配置或凭据')
 return p.stdout.strip()
def inspect():return json.loads(docker('inspect',name))[0]
def exists():return subprocess.run(['docker','container','inspect',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
def paths():
 for p in (root,root/'config',backups,backups/'config'):
  if any(q.is_symlink() for q in (p,*p.parents)):raise RuntimeError('拒绝符号链接应用/备份路径')
def owned(x):
 if (x['Config'].get('Labels') or {}).get('org.emby.manager')!='Emby.sh' or not any(m.get('Source')==str(root/'config') and m.get('Destination')=='/config' for m in x['Mounts']):raise RuntimeError('同名容器不属于本脚本，拒绝操作')
def ready():
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
 for _ in range(60):
  x=inspect()
  if not x['State']['Running']:raise RuntimeError('Emby容器未运行')
  for b in x['NetworkSettings'].get('Ports',{}).get('8096/tcp') or []:
   ip=b['HostIp'];ip='127.0.0.1' if ip in ('','0.0.0.0') else '::1' if ip=='::' else ip
   if ':' in ip:ip='['+ip+']'
   try:
    with opener.open('http://'+ip+':'+b['HostPort']+'/web/index.html',timeout=2) as r:
     if r.status==200 and r.read(1):return
   except OSError:pass
  time.sleep(1)
 raise RuntimeError('Emby HTTP启动验证超时')
def create(settings,img):
 os.chmod(root,0o755)
 for p in [root/'config',*(root/'config').rglob('*')]:
  if p.is_symlink():raise RuntimeError('配置包含符号链接，拒绝启动')
  os.chown(p,1000,1000)
 args=['create','--name',name,'--restart','unless-stopped','--label','org.emby.manager=Emby.sh','--log-opt','max-size=10m','--log-opt','max-file=3','--ulimit','core=0:0','-p',settings['bind']+':'+str(settings['port'])+':8096','-e','UID=1000','-e','GID=1000','-v',str(root/'config')+':/config']
 if settings.get('media'):args+=['-v',settings['media']+':/media:ro']
 return docker(*args,img)
def validate_archive(path):
 with tarfile.open(path,'r:gz') as t:
  members=t.getmembers();seen=set()
  if not members:raise RuntimeError('空备份')
  for m in members:
   p=pathlib.PurePosixPath(m.name)
   if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='Emby' or m.name in seen or not(m.isfile() or m.isdir()):raise RuntimeError('不安全或非Emby备份：'+m.name)
   seen.add(m.name)
  if 'Emby/deploy.json' not in seen or not any(m.name.startswith('Emby/config/') for m in members):raise RuntimeError('备份缺少部署配置或数据')
 return members
def settings_check(s):
 if s.get('bind') not in ('127.0.0.1','0.0.0.0') or type(s.get('port')) is not int or not 1<=s['port']<=65535:raise RuntimeError('部署地址/端口无效')
 m=s.get('media','')
 if m and (not pathlib.Path(m).is_absolute() or not pathlib.Path(m).is_dir() or ':' in m or '\n' in m or m=='/'):raise RuntimeError('本地媒体目录不存在或无效，请先挂载远程存储')
 return s
def verify_databases(base):
 for p in base.rglob('*'):
  if p.is_file() and not p.is_symlink():
   with p.open('rb') as f:header=f.read(16)
   if header==b'SQLite format 3\x00':
    conn=sqlite3.connect(p.as_uri()+'?mode=ro',uri=True)
    try:
     if conn.execute('pragma integrity_check').fetchone()[0]!='ok':raise RuntimeError('SQLite校验失败：'+p.name)
    finally:conn.close()
try:
 paths()
 if mode=='install':
  if root.exists() or exists():raise RuntimeError('应用目录/容器已存在，拒绝覆盖')
  s=settings_check(json.loads(arg));docker('pull',image);root.mkdir(parents=True,mode=0o700);(root/'config').mkdir(mode=0o755)
  (root/'deploy.json').write_text(json.dumps(s));os.chmod(root/'deploy.json',0o600)
  create(s,image);docker('start',name);ready();print('安装完成，HTTP已验证。请打开 http://服务器IP:'+str(s['port'])+'/web 完成初始化。')
 elif mode=='update':
  x=inspect();owned(x)
  # Recreate only if every runtime option matches our creation contract.
  s=settings_check(json.loads((root/'deploy.json').read_text()));docker('pull',image);target=json.loads(docker('image','inspect',image))[0]['Id']
  if target==x['Image']:print('镜像已一致，无需更新');sys.exit(0)
  old=name+'-before-update-'+str(time.time_ns());docker('stop',name);docker('rename',name,old)
  try:
   create(s,target);docker('start',name);ready()
  except BaseException:
   if exists():docker('rm','-f',name)
   docker('rename',old,name)
   if x['State']['Running']:docker('start',name)
   raise
  docker('rm',old)
  if not x['State']['Running']:docker('stop',name)
  print('更新完成；保留配置、媒体映射。数据迁移不保证可降级。')
 elif mode=='backup':
  x=inspect();owned(x);backups.mkdir(parents=True,exist_ok=True,mode=0o700)
  stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S');final=backups/('Emby-'+stamp+'.tar.gz');partial=pathlib.Path(str(final)+'.partial')
  fd=os.open(partial,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd);running=x['State']['Running']
  if running:docker('stop',name)
  try:
   verify_databases(root/'config')
   # Reject links and special files instead of archiving external media/secrets.
   for p in (root/'config').rglob('*'):
    if p.is_symlink() or not(p.is_file() or p.is_dir()):raise RuntimeError('配置包含链接/特殊文件，备份已停止：'+str(p))
   with tarfile.open(partial,'w:gz') as t:
    t.add(root/'deploy.json',arcname='Emby/deploy.json');t.add(root/'config',arcname='Emby/config')
   validate_archive(partial)
   with partial.open('rb') as f:os.fsync(f.fileno())
   os.link(partial,final);partial.unlink()
  finally:
   if running:docker('start',name);ready()
  print(str(final))
 elif mode=='list':
  found={}
  for base in (backups,pathlib.Path('/home'),pathlib.Path('/root')):
   if base.is_dir():
    for p in base.glob('*.tar.gz'):
     if p.is_file() and not p.is_symlink():found[str(p)]=p.stat().st_mtime_ns
  for p in sorted(found,key=found.get,reverse=True):print(p)
 elif mode=='restore':
  archive=pathlib.Path(arg);members=validate_archive(archive);root.parent.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(prefix='.emby-restore-',dir=root.parent) as tmp:
   stage=pathlib.Path(tmp)
   with tarfile.open(archive,'r:gz') as t:t.extractall(stage,filter='data')
   restored=stage/'Emby';s=settings_check(json.loads((restored/'deploy.json').read_text()));verify_databases(restored/'config')
   x=inspect() if exists() else None
   if x:owned(x)
   docker('pull',image);old=root.parent/('.emby-before-restore-'+str(time.time_ns()));oldname=name+'-before-restore-'+str(time.time_ns());moved=False
   if x:docker('stop',name);docker('rename',name,oldname)
   try:
    if root.exists():root.rename(old);moved=True
    restored.rename(root);create(s,image);docker('start',name);ready()
   except BaseException:
    if exists():docker('rm','-f',name)
    if root.exists():root.rename(root.parent/('.emby-failed-restore-'+str(time.time_ns())))
    if moved:old.rename(root)
    if x:
     docker('rename',oldname,name)
     if x['State']['Running']:docker('start',name)
    raise
   if x:docker('rm',oldname)
   if moved:shutil.rmtree(old)
  print('恢复完成，HTTP启动验证通过；未验证媒体播放。')
 elif mode=='uninstall':
  if exists():owned(inspect());docker('rm','-f',name)
  if exists():raise RuntimeError('容器仍存在，保留数据')
  ids=docker('ps','-aq').split()
  for ident in ids:
   x=json.loads(docker('inspect',ident))[0]
   if any(m.get('Source','')==str(root) or m.get('Source','').startswith(str(root)+'/') for m in x['Mounts']):raise RuntimeError('其他容器引用应用目录，保留数据')
  if root.exists():shutil.rmtree(root)
  print('已卸载Emby；备份、远程存储和媒体源文件保留。SSH/S3任务配置保留。')
 else:raise RuntimeError('未知操作')
except Exception as e:
 print('操作失败：'+str(e),file=sys.stderr);sys.exit(1)
PY_EMBY
}
ai_local_backup() {
 local result rc=0
 result=$(native backup) || rc=$?
 [[ $rc == 0 && -f $result && $result == "$BACKUP_DIR/"Emby-*.tar.gz ]] || return 1
 AI_NEW_ARCHIVE="$result"
 echo "备份完成：$result" >&2
}
install_app() {
 command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo '请先安装并启动Docker。'; return 1; }
 local bind port media settings
 IFS= read -r -p '监听地址（回车0.0.0.0；可填127.0.0.1）：' bind || return 1
 IFS= read -r -p '网页端口（回车8096）：' port || return 1
 IFS= read -r -p '本地媒体目录（须提前挂载WebDAV/S3；回车暂不映射）：' media || return 1
 settings=$(python3 -c 'import json,sys;print(json.dumps(dict(bind=sys.argv[1],port=int(sys.argv[2]),media=sys.argv[3])))' "${bind:-0.0.0.0}" "${port:-8096}" "$media") || return 1
 echo '将新建Emby容器和 /home/docker/Emby；媒体目录只读映射为 /media。公网访问请配置HTTPS及防火墙。'
 confirm && native install "$settings"
}
restore_app() {
 local selected choice;local -a files=()
 mapfile -t files < <(native list)
 ((${#files[@]})) || { echo '未找到备份'; return 1; }
 for selected in "${!files[@]}"; do printf '%s. %s\n' "$((selected+1))" "${files[$selected]}"; done
 IFS= read -r -p '选择恢复编号（0取消）：' choice || return 1
 [[ $choice != 0 ]] || return 0
 [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && ((choice<=${#files[@]})) || return 1
 echo '将验证备份后替换Emby配置；成功后清理本次临时旧目录。媒体不在备份内，源目录须提前挂载。'
 confirm && native restore "${files[$((choice-1))]}"
}

air_init() {
    [[ ${AI_APP_ID:-} == emby ]] || return 1
    [[ -n ${AI_APP_LABEL:-} && ${BACKUP_DIR:-} == /* && -n ${BACKUP_PREFIX:-} && $BACKUP_PREFIX != */* ]] || return 1
    [[ ${REMOTE_DIR:-} == "$BACKUP_DIR/config" && ${LOCK_FILE:-} == "$BACKUP_DIR/config/backup.lock" && ${RETENTION_FILE:-} == "$REMOTE_DIR/local-retention.json" ]] || return 1
    declare -F ai_local_backup >/dev/null
}
air_error() { echo "错误：$*" >&2; }
air_locked() (
    umask 077
    mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || { air_error "应用备份操作正在执行。"; exit 1; }
    "$@"
)
air_ensure_environment() {
    local cmd
    for cmd in python3 flock; do command -v "$cmd" >/dev/null || { air_error "请先安装$cmd"; return 1; }; done
    if [[ ${1:-} == remote ]]; then
        if ! command -v rclone >/dev/null; then
            if command -v apt-get >/dev/null; then apt-get update && apt-get install -y rclone openssh-client || return 1
            else air_error "请先安装rclone和OpenSSH客户端。"; return 1; fi
        fi
    fi
}
air_remote_backup_app() (
    umask 077
    mkdir -p "$BACKUP_DIR" || exit 1
    AI_NEW_ARCHIVE=
    ai_local_backup >&2 || exit 1
    [[ -n ${AI_NEW_ARCHIVE:-} && -f $AI_NEW_ARCHIVE && ! -L $AI_NEW_ARCHIVE ]] || { air_error "本地备份未返回完整归档路径。"; exit 1; }
    python3 - "$AI_NEW_ARCHIVE" "$BACKUP_DIR" "$BACKUP_PREFIX" <<'PY'
import sys,pathlib,re,tarfile,gzip
p=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2])
if p.resolve().parent!=root.resolve() or not re.fullmatch(re.escape(sys.argv[3])+r'\d{8}-\d{6}\.tar\.gz',p.name): raise ValueError('新归档路径不属于当前应用')
with tarfile.open(p,'r:gz') as a: a.getmembers()
with gzip.open(p,'rb') as f:
    while f.read(1024*1024): pass
PY
    [[ $? == 0 ]] || exit 1
    if [[ -z ${AIR_EXACT_RESULT_FILE:-} ]]; then air_prune_local_backups >&2 || exit 1; fi
    if [[ -n ${AIR_EXACT_RESULT_FILE:-} ]]; then
        printf '%s\n' "$AI_NEW_ARCHIVE" > "$AIR_EXACT_RESULT_FILE" || exit 1
    else
        printf '%s\n' "$AI_NEW_ARCHIVE"
    fi
)
air_manual_remote_backup() { air_configure_local_retention && air_locked air_remote_backup_app; }
air_configure_local_retention() {
    local count
    while true; do
        IFS= read -r -p "本地备份保留数量（回车默认3）：" count || return 1
        count=${count:-3}
        if [[ $count =~ ^[1-9][0-9]{0,5}$ ]] && (( count <= 100000 )); then break; fi
        air_error "请输入1–100000的正整数。"
    done
    python3 - "$RETENTION_FILE" "$count" <<'PY'
import pathlib,os,json,sys
p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
fd=os.open(p,os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f: json.dump({'keep':int(sys.argv[2])},f)
os.chmod(p,0o600)
PY
}
air_prune_local_backups() {
    python3 - "$BACKUP_DIR" "$RETENTION_FILE" "$BACKUP_PREFIX" "${1:-}" <<'PY'
import pathlib,sys,json,re
root=pathlib.Path(sys.argv[1]); setting=pathlib.Path(sys.argv[2])
keep=int(sys.argv[4]) if len(sys.argv)>4 and sys.argv[4] else (json.loads(setting.read_text()).get('keep',3) if setting.exists() else 3)
if not isinstance(keep,int) or isinstance(keep,bool) or not 1<=keep<=100000: raise ValueError('本地保留数量无效，不执行删除')
files=sorted((p for p in root.iterdir() if re.fullmatch(re.escape(sys.argv[3])+r'\d{8}-\d{6}\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name.replace('-',''),reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
AI_LOG_MAX_BYTES=2097152
AI_LOG_BACKUPS=3
air_single_remote_engine() {
    python3 - "$REMOTE_DIR" "$BACKUP_DIR" "$BACKUP_PREFIX" "$AI_APP_ID" "$AI_APP_LABEL" "$@" 3<&0 <<'PY'
import os,sys,pathlib,json,re,subprocess,getpass,urllib.parse,tempfile,time,hashlib,tarfile
sys.stdin=os.fdopen(3)
root=pathlib.Path(sys.argv[1]); backups=pathlib.Path(sys.argv[2]); prefix=sys.argv[3]; app_id=sys.argv[4]; label=sys.argv[5]; mode=sys.argv[6]; kind=sys.argv[7]
owned_pattern=re.escape(prefix)+r"\d{8}-\d{6}\.tar\.gz"
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
        if kind=='ssh':
            while True:
                local_keep=ask('检查本地备份数量（回车默认3）','3')
                if local_keep.isdigit() and 1<=int(local_keep)<=100000:
                    d['local_keep']=int(local_keep); break
                print('请输入1–100000的整数。')
        if kind in ('ssh-backup','ssh'):
            while True:
                keep=ask('远程保留数量（回车默认 3 输入 0 不删除远程备份）','3')
                if keep.isdigit() and 0<=int(keep)<=100000:
                    d['keep']=int(keep); break
                print('请输入0–100000的整数，0表示不删除。')
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
            dest=valid(ask('远端专用备份目录',str(backups)))
            if not dest.startswith('/') or '..' in pathlib.PurePosixPath(dest).parts or dest=='/': raise ValueError('远端目录无效')
            print('将通过SFTP上传：'+dest+'；'+('不删除远程备份' if d['keep']==0 else '仅保留最新'+str(d['keep'])+'份当前前缀的远程归档'))
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = sftp\nhost = '+host+'\nuser = '+user+'\nport = '+port+'\nknown_hosts_file = \n'
            if auth=='1': text+='key_file = '+str(key)+'\n'
            else:
                # 密码经stdin传入obscure，不进入命令行参数或日志。
                obscured=run(['rclone','obscure','-'],input=password+'\n').stdout.strip()
                if not obscured or '\n' in obscured: raise ValueError('密码处理失败')
                text+='pass = '+obscured+'\n'
            d['auth']='key' if auth=='1' else 'password'
            d['dest']='remote:'+dest
        else:
            endpoint=valid(ask('S3 API Endpoint（非管理网页）'))
            u=urllib.parse.urlsplit(endpoint)
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('','/'): raise ValueError('Endpoint必须为HTTPS API地址，无用户名/路径/查询参数')
            bucket=valid(ask('存储桶名称（需提前创建）'))
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,62}',bucket): raise ValueError('桶名无效')
            prefix=valid(ask('桶内专用备份前缀','备份/'+app_id)).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                local_keep=ask('检查本地备份数量（回车默认3）','3')
                if local_keep.isdigit() and 1<=int(local_keep)<=100000:
                    d['local_keep']=int(local_keep); break
                print('请输入1–100000的整数。')
            while True:
                keep=ask('S3远程保留数量（回车默认 3 输入 0 不删除远程备份）','3')
                if keep.isdigit() and 0<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入0–100000的整数，0表示不删除。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份'+label+'时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+access+'\nsecret_access_key = '+secret+'\nendpoint = '+endpoint+'\nregion = '+region+'\nforce_path_style = true\nsign_accept_encoding = false\n'
        if d['action']=='backup':
            while True:
                interval=ask('备份间隔（1d/2d/3d/5d/7d/14d/30d）','7d')
                if interval in ('1d','2d','3d','5d','7d','14d','30d'): break
                print('请输入完整间隔，例如7d或14d。')
            d['interval']=interval
            hour=ask('每日备份北京时间小时（UTC+8）','5'); minute=ask('分钟','0')
            if not hour.isdigit() or not minute.isdigit() or not 0<=int(hour)<=23 or not 0<=int(minute)<=59: raise ValueError('时间无效')
            d['calendar']='*-*-* '+f'{int(hour):02}:{int(minute):02}:00 Asia/Shanghai'
            d['anchor_day']=int((time.time()+8*3600)//86400)
        else:
            d['calendar']='*:*:00/30'
            print('传送监控每30秒检查；仅发送最新完整归档，已成功发送的不重复上传。')
        # Validate SSH mkdir and readback using a temporary candidate config before replacing saved credentials.
        if kind in ('ssh','ssh-backup'):
            fd,candidate=tempfile.mkstemp(prefix=kind+'-candidate-',suffix='.conf',dir=root)
            os.close(fd)
            try:
                save(pathlib.Path(candidate),text)
                args=['rclone','--config',candidate,'--contimeout','15s','--timeout','2m','--retries','2']
                run(args+['mkdir',d['dest']])
                run(args+['lsjson',d['dest'],'--max-depth','1'])
            finally: os.unlink(candidate)
        save(conf,text); save(p,json.dumps(d,ensure_ascii=False))
        state=root/(kind+'-sent.json')
        if state.exists(): state.unlink()
        print('配置已保存，权限0600；凭据不进入备份包。')
    elif mode=='calendar': print(load()['calendar'])
    elif mode=='action': print(load().get('action','backup'))
    elif mode=='local-keep': print(load().get('local_keep',3))
    elif mode=='due':
        d=load(); interval=d.get('interval','7d')
        if d.get('action','backup')=='backup' and interval.endswith('d'):
            days=int(interval[:-1]); today=int((time.time()+8*3600)//86400)
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
        d=load()
        explicit=sys.argv[8] if len(sys.argv)>8 else ''
        if explicit:
            f=pathlib.Path(explicit)
            if not f.is_file() or f.is_symlink() or f.resolve().parent!=backups.resolve() or not re.fullmatch(owned_pattern,f.name): raise ValueError('指定归档路径或名称无效')
        else:
            files=[x for x in backups.glob('*.tar.gz') if x.is_file() and not x.is_symlink()]
            if not files: print('暂无归档，等待新备份。'); sys.exit(0)
            f=max(files,key=lambda x:x.stat().st_mtime_ns)
        st=f.stat()
        if not explicit and time.time()-st.st_mtime<60: print('最新归档尚未稳定，稍后再传。'); sys.exit(0)
        state=root/(kind+'-sent.json')
        identity=[f.name,st.st_size,st.st_mtime_ns,st.st_ctime_ns,st.st_dev,st.st_ino]
        previous=json.loads(state.read_text()) if state.exists() else None
        if isinstance(previous,dict) and previous.get('version')==2 and previous.get('identity')==identity:
            print('最新归档已传送且未变化，跳过。'); sys.exit(0)
        with tarfile.open(f,'r:gz') as archive: archive.getmembers()
        import gzip
        with gzip.open(f,'rb') as stream:
            while stream.read(1024*1024): pass
        digest_hash=hashlib.sha256()
        with f.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''): digest_hash.update(chunk)
        digest=digest_hash.hexdigest()
        signature=[f.name,st.st_size,digest]
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity:
            raise ValueError('归档在校验中发生变化；未上传或升级记录')
        record={'version':2,'identity':identity,'signature':signature}
        if previous==signature or (isinstance(previous,dict) and previous.get('signature')==signature):
            save(state,json.dumps(record))
            print('最新归档已传送，已更新快速检测记录，跳过。'); sys.exit(0)
        target=d['dest'].rstrip('/')+'/'+f.name
        if kind in ('ssh','ssh-backup'):
            rc(['mkdir',d['dest']]); rc(['lsjson',d['dest'],'--max-depth','1'])
        rc(['copyto',str(f),target,'--immutable','--ignore-existing','--s3-upload-cutoff','32Mi','--s3-chunk-size','8Mi'])
        info=json.loads(rc(['lsjson',target,'--stat']).stdout)
        if info.get('IsDir') or info.get('Size')!=f.stat().st_size: raise ValueError('上传后远端大小校验失败；未执行清理')
        # 按字节比较本次归档；成功后才允许远端保留清理。
        rc(['check',str(f.parent),d['dest'],'--include',f.name,'--one-way','--download'])
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化；未清理')
        if kind in ('s3','ssh-backup','ssh') and d.get('keep',0)!=0:
            listing=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(owned_pattern,x.get('Path',''))],key=lambda name:name.replace('-',''),reverse=True)
            keep=d.get('keep',3)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('远程保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化')
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity: raise ValueError('归档在传送中发生变化；未提交成功记录')
        save(state,json.dumps(record))
        retention='远端不删除' if d.get('keep',0)==0 else '远端保留最新'+str(d['keep'])+'份当前前缀归档'
        print('上传并校验成功：'+f.name+'；'+retention+'；本地数量由本地备份设置独立控制。')
    else: raise ValueError('未知操作')
except (EOFError,KeyboardInterrupt):
    print('已取消。'); sys.exit(1)
except subprocess.CalledProcessError as e:
    diagnostic=(e.stderr or '').lower()
    if 'known_hosts' in diagnostic or 'knownhosts' in diagnostic:
        reason='SSH主机校验配置不兼容，请重新保存远程配置。'
    elif 'unable to authenticate' in diagnostic or 'authentication failed' in diagnostic:
        reason='SSH认证失败，请核对用户名、密码或私钥及服务端权限。'
    elif 'connection refused' in diagnostic:
        reason='远端拒绝连接，请检查SSH端口及服务。'
    elif 'timeout' in diagnostic or 'timed out' in diagnostic:
        reason='连接超时，请检查网络、防火墙或地址。'
    elif 'permission denied' in diagnostic:
        reason='远端目录权限不足，无法创建或读取。'
    elif 'directory not found' in diagnostic or 'no such file' in diagnostic:
        reason='远程目录或本地私钥文件不存在。'
    else:
        reason='远端命令失败（退出码'+str(e.returncode)+'），请检查连接、权限与配置。'
    print('远程备份失败：'+reason,file=sys.stderr); sys.exit(1)
except Exception as e:
    # 不回显rclone原始输出、S3凭据或完整配置。
    print('远程备份失败：'+(str(e) if isinstance(e,ValueError) else type(e).__name__),file=sys.stderr); sys.exit(1)
PY
}

# 配置修改顺序：配置锁→对应任务锁，均非阻塞；不同应用路径独立。
air_single_configuration_locked() (
    local kind=$1
    shift
    umask 077
    mkdir -p "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { air_error "配置正在修改，请稍后重试。"; exit 1; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { air_error "该任务正在执行，未修改配置。"; exit 1; }
    "$@"
)
air_remote_schedule() { air_configuration_locked "$1" air_remote_schedule_unlocked "$@"; }
air_configure_remote_task() {
    air_remote_engine configure "$1" && air_remote_schedule_unlocked "$1" enable
}
air_delete_remote_task() {
    air_remote_schedule_unlocked "$1" remove && air_remote_engine delete "$1"
}
air_single_remote_schedule_unlocked() {
    local kind=$1 action=$2 calendar script unit="ai-${AI_APP_ID}-backup-$1"
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || return 1
    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { air_error "定时备份需要systemd；配置可保留，仍可手动执行。"; return 1; }
    local owned_target
    for owned_target in "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"; do
        if [[ -e $owned_target ]] && [[ $(IFS= read -r line < "$owned_target"; printf '%s' "$line") != "# AI_APP_ID=$AI_APP_ID managed remote backup" ]]; then
            air_error "同名外部unit，拒绝修改：$owned_target"; return 1
        fi
    done
    if [[ $action == remove ]]; then
        systemctl disable --now "$unit.timer" || return 1
        # 不强行终止正在传送的service；删除配置前检查。
        systemctl is-active --quiet "$unit.service" && { air_error "任务正在运行，请完成后再删除配置。"; return 1; }
        rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
        systemctl daemon-reload
        return
    fi
    calendar=$(air_remote_engine calendar "$kind") || return 1
    script=$(readlink -f "${AI_MANAGER_SCRIPT:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}") || return 1
    [[ $script =~ ^/[A-Za-z0-9_./-]+$ ]] || { air_error "定时运行的脚本路径不支持空格或特殊字符。"; return 1; }
    local target
    for target in "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"; do
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != "# AI_APP_ID=$AI_APP_ID managed remote backup" ]]; then air_error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" "$AI_APP_ID" "$AI_APP_LABEL" "${AIR_TASK_NAME:-}" <<'PY'
import sys,pathlib
unit,script,kind,calendar,app_id,label,task_name=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
remote_args=('--remote-task '+task_name+' '+kind) if task_name else ('--remote '+kind)
service_content=('# AI_APP_ID='+app_id+' managed remote backup\n[Unit]\nDescription='+label+' remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' '+remote_args+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# AI_APP_ID='+app_id+' managed remote backup\n[Unit]\nDescription='+label+' daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
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
air_backup_event_log() {
    python3 - "$REMOTE_DIR" "$AI_LOG_MAX_BYTES" "$AI_LOG_BACKUPS" "$1" "$2" <<'PY'
import pathlib,sys,logging,logging.handlers,fcntl,os
root=pathlib.Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True,mode=0o700)
with (root/'log.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    h=logging.handlers.RotatingFileHandler(root/'backup-transfer.log',maxBytes=int(sys.argv[2]),backupCount=int(sys.argv[3]),encoding='utf-8')
    h.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
    logger=logging.getLogger('ai-remote'); logger.setLevel(logging.INFO); logger.addHandler(h)
    logger.info('%s %s',sys.argv[4],sys.argv[5]); h.close()
    for p in root.glob('backup-transfer.log*'): os.chmod(p,0o600)
PY
}
air_remote_run() {
    local kind=$1
    [[ -f $REMOTE_DIR/$kind.json ]] || { air_error "尚未配置远端。"; return 1; }
    local action rc=0 result archive=""
    action=$(air_remote_engine action "$kind") || return 1
    if [[ $action == backup ]]; then
        air_backup_event_log "$kind" "本地备份开始" || return 1
        local AIR_EXACT_RESULT_FILE
        AIR_EXACT_RESULT_FILE=$(mktemp "$REMOTE_DIR/.producer-result.XXXXXX") || return 1
        chmod 600 "$AIR_EXACT_RESULT_FILE"
        if ! air_locked air_remote_backup_app; then
            rm -f "$AIR_EXACT_RESULT_FILE"
            air_backup_event_log "$kind" "本地备份失败"; return 1
        fi
        IFS= read -r archive < "$AIR_EXACT_RESULT_FILE"
        rm -f "$AIR_EXACT_RESULT_FILE"
        [[ -n $archive && -f $archive ]] || { air_error "未获得本次完整归档路径。"; return 1; }
        air_backup_event_log "$kind" "本地完整备份完成（可能包含应用凭据）" || return 1
        # 本地备份先完成并恢复容器，再检查传送工具和连接远端。
    fi
    command -v rclone >/dev/null || {
        air_error "缺少rclone；本地备份保留，可由其他传送任务发送。"
        air_backup_event_log "$kind" "传送工具缺失，本地备份保留"; return 1;
    }
    result=$(air_remote_engine upload "$kind" "$archive" 2>&1) || rc=$?
    [[ -z $result ]] || printf '%s\n' "$result"
    if (( rc )); then
        air_backup_event_log "$kind" "传送失败，本地备份保留" || return 1
    elif [[ $result == *'上传并校验成功'* ]]; then
        air_backup_event_log "$kind" "传送校验完成" || return 1
    fi
    # 无新文件/稳定等待/已发送跳过不写日志，防止空闲日志膨胀。
    # Cleanup only after verified upload or verified unchanged sent signature.
    if [[ $rc == 0 && ( $result == *'上传并校验成功'* || $result == *'最新归档已传送，跳过。'* ) ]]; then
        if [[ $action == backup ]]; then
            air_locked air_prune_local_backups || return 1
        elif [[ $kind == ssh || $kind == s3 ]]; then
            local transfer_keep
            transfer_keep=$(air_remote_engine local-keep "$kind") || return 1
            if [[ $transfer_keep =~ ^[1-9][0-9]*$ ]]; then
                air_locked air_prune_local_backups "$transfer_keep" || return 1
            fi
        fi
    fi
    return "$rc"
}
air_single_remote_locked_run() (
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
        air_remote_engine due "$kind" || due_rc=$?
        [[ $due_rc != 3 ]] || exit 0
        [[ $due_rc == 0 ]] || exit "$due_rc"
    fi
    air_remote_run "$kind"
)
air_remote_choose_ssh() {
    local selection
    echo "1. SSH备份上传任务"
    echo "2. SSH仅传送任务"
    IFS= read -r -p "选择任务（0取消）：" selection || return 1
    case "$selection" in 1) AI_SELECTED_REMOTE=ssh-backup ;; 2) AI_SELECTED_REMOTE=ssh ;; *) return 1 ;; esac
}


air_remote_summary() {
    # 主菜单仅读取本地配置及timer状态，不连接远端，不显示凭据。
    python3 - "$REMOTE_DIR" "${1:-all}" "$AI_APP_ID" <<'PY'
import pathlib,json,subprocess,sys
root=pathlib.Path(sys.argv[1]); scope=sys.argv[2]
def color(text,code): return '\033['+code+'m'+text+'\033[0m'
def schedule(d):
    if d.get('action','backup')=='transfer': return '每30秒检测新备份并传送'
    interval=d.get('interval','7d'); calendar=d.get('calendar','')
    import re
    match=re.search(r'(\d{2}):(\d{2}):00 Asia/Shanghai$',calendar)
    if interval.endswith('h'):
        minute=int(match.group(2)) if match else 0
        return '每'+interval[:-1]+'小时，第'+str(minute)+'分运行（北京时间 UTC+8）'
    if interval.endswith('d') and match:
        return '每'+interval[:-1]+'天 '+str(int(match.group(1)))+'时 '+str(int(match.group(2)))+'分运行（北京时间 UTC+8）'
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
                unit='ai-'+sys.argv[3]+'-backup-'+kind
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

# Named-task context: old singleton configurations remain usable unchanged.
air_task_context() {
    local selector="$1"
    AIR_BASE_CONFIG="$BACKUP_DIR/config"
    AIR_BASE_APP_ID="${AIR_BASE_APP_ID:-$AI_APP_ID}"
    if [[ "$selector" == *@* ]]; then
        AIR_TASK_KIND="${selector%%@*}"
        AIR_TASK_NAME="${selector#*@}"
        [[ "$AIR_TASK_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { air_error '配置名称无效'; return 1; }
        [[ "$AIR_TASK_KIND" == ssh-backup || "$AIR_TASK_KIND" == ssh || "$AIR_TASK_KIND" == s3 ]] || return 1
        REMOTE_DIR="$AIR_BASE_CONFIG/tasks/$AIR_TASK_NAME"
        RETENTION_FILE="$REMOTE_DIR/local-retention.json"
        AI_APP_ID="$AIR_BASE_APP_ID-task-$AIR_TASK_NAME"
    else
        AIR_TASK_KIND="$selector"
    fi
}
air_remote_engine() (
    local mode="$1" selector="$2"; shift 2
    air_task_context "$selector" || exit 1
    air_single_remote_engine "$mode" "$AIR_TASK_KIND" "$@"
)
air_configuration_locked() (
    local selector="$1"; shift
    air_task_context "$selector" || exit 1
    air_single_configuration_locked "$AIR_TASK_KIND" "$@"
)
air_remote_schedule_unlocked() (
    local selector="$1"; shift
    air_task_context "$selector" || exit 1
    air_single_remote_schedule_unlocked "$AIR_TASK_KIND" "$@"
)
air_remote_locked_run() (
    local selector="$1"; shift
    air_task_context "$selector" || exit 1
    air_single_remote_locked_run "$AIR_TASK_KIND" "$@"
)
air_task_selectors() {
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
air_named_summary() {
    local scope="${1:-all}" selector dir kind idx=0 title group
    local -a selectors=()
    mapfile -t selectors < <(air_task_selectors "$scope")
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
unit='ai-'+app+'-backup-'+kind+'.timer'
try: active=subprocess.run(['systemctl','is-active','--quiet',unit],capture_output=True,timeout=2).returncode==0
except (OSError,subprocess.TimeoutExpired): active=False
state='\033[32m正常（定时运行中）\033[0m' if active else '\033[33m异常（定时未运行）\033[0m'
name=''.join(c for c in str(d.get('name',selector)) if c.isprintable())
timing='每30秒检测新备份并传送' if d.get('action')=='transfer' else '每'+str(d.get('interval','7d')).removesuffix('d')+'天 '+str(d.get('calendar',''))+'（北京时间）'
print(index+'. '+name+'   '+state+'  '+timing)
PY_NSUMMARY
        done
        [ "$found" = 1 ] || echo 暂无
        [ "$group" != ssh-backup ] && echo '==================================' || echo '------------------------'
    done
}

air_remote_menu() {
    local scope="$1" choice name target selected confirm
    local -a selectors=()
    air_ensure_environment remote || return 1
    air_repair_remote_schedules
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo '=================================='
        echo "$AI_APP_LABEL ${scope^^} 远程备份配置"
        echo '=================================='
        air_named_summary "$scope"
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
                air_named_task_available "$name" || continue
                air_configuration_locked "$target@$name" air_named_configure "$target" || echo '任务添加未完成，已保存配置可在重开菜单时重试定时修复。'
                ;;
            7|8|9)
                mapfile -t selectors < <(air_task_selectors "$scope")
                read -r -p '任务编号（0返回）: ' selected || return 0
                [ "$selected" != 0 ] || continue
                [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#selectors[@]}" ] || { echo '编号无效'; continue; }
                target="${selectors[$((selected-1))]}"
                case "$choice" in
                    7) air_remote_engine test "$target" ;;
                    8) air_remote_locked_run "$target" ;;
                    9) read -r -p '输入yes删除该任务（保留备份）: ' confirm; [ "$confirm" != yes ] || air_configuration_locked "$target" air_delete_remote_task "${target%%@*}" ;;
                esac
                ;;
            0) return 0 ;;
            *) echo 无效选项 ;;
        esac
    done
}
air_named_task_available() {
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

air_named_configure() {
    local kind="$1" existing
    for existing in ssh ssh-backup s3; do
        if [[ -e "$REMOTE_DIR/$existing.json" || -e "$REMOTE_DIR/$existing.conf" ]]; then
            air_error '本应用同名任务配置已存在，未覆盖。'; return 1
        fi
    done
    if [ "$kind" = ssh-backup ]; then air_configure_local_retention || return 1; fi
    air_remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    air_remote_schedule_unlocked "$kind" enable
}





air_repair_remote_schedules() {
 local selector failed=0
 while IFS= read -r selector; do
  [[ -z $selector ]] || air_remote_schedule "$selector" enable >/dev/null || failed=1
 done < <(air_task_selectors all)
 return "$failed"
}
show_menu() {
 [[ ! -t 1 || ${TERM:-dumb} == dumb ]] || clear
 echo '=================================='
 echo '        Emby 管理脚本'
 echo '媒体服务器，集中管理电影、剧集、音乐和照片'
 echo '部署组件：Emby Server（Docker；官方镜像）'
 echo '官方地址：https://emby.media'
 echo '发布地址：https://github.com/MediaBrowser/Emby.Releases'
 echo 'Emby Server 并非完全开源；部分功能需要 Emby Premiere'
 echo '=================================='
 air_named_summary all
 echo '默认访问端口：8096'
 echo '管理页面：http://你的IP:8096/web'
 echo '媒体源须提前在宿主机挂载，本脚本不收集WebDAV/S3媒体账号'
 echo '------------------------'
 echo '1. 安装'
 echo '2. 更新'
 echo '3. 备份/home/备份/Emby/'
 echo '4. 恢复（自动扫描home及备份目录）'
 echo '5. SSH 远程备份配置'
 echo '6. S3 API 兼容备份配置'
 echo '9. 卸载'
 echo '0. 退出'
}
main() {
 [[ $EUID == 0 ]] || { echo '请用root运行'; return 1; }
 air_ensure_environment || return 1
 mkdir -p "$REMOTE_DIR" || return 1
 chmod 700 "$REMOTE_DIR"
 AI_MANAGER_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
 air_init || return 1
 case ${1:-} in
 --remote-task) air_remote_locked_run "${3:-}@${2:-}" "${4:-}"; return $? ;;
 --remote) air_remote_locked_run "${2:-}" "${3:-}"; return $? ;;
 --check) echo '脚本环境检查通过'; return 0 ;;
 '') ;;
 *) echo '未知参数'; return 1 ;;
 esac
 air_repair_remote_schedules || echo '部分任务定时修复失败，请检查配置。'
 local choice
 while true; do
  show_menu
  IFS= read -r -p '请输入选项: ' choice || return 0
  case $choice in
   1) air_locked install_app ;;
   2) echo '将更新官方镜像并短暂中断服务；保留配置和媒体映射。'; confirm && air_locked native update ;;
   3) air_manual_remote_backup ;;
   4) air_locked restore_app ;;
   5) air_remote_menu ssh; continue ;;
   6) air_remote_menu s3; continue ;;
   9) echo '删除Emby容器和应用配置；保留备份、媒体文件及SSH/S3任务。'; confirm && air_locked native uninstall ;;
   0) return 0 ;;
   *) echo '无效选项' ;;
  esac
  IFS= read -r -p '按回车继续...' _ || return 0
 done
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
