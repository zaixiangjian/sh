#!/usr/bin/env bash
# SSH 只投递备份：独立 SSH 服务；安装操作仅在明确选择后执行。
set -euo pipefail
# 修改此处统一设置新增A任务及首次B安装的默认端口（不迁移现有配置）。
SSH_BACKUP_PORT=22222
export SBR_DEFAULT_PORT="$SSH_BACKUP_PORT"
if ! command -v python3 >/dev/null 2>&1; then
    if [[ $EUID -ne 0 ]] || ! command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' '需要 Python 3；请以 root 在 Debian/Ubuntu 安装 python3。' >&2
        exit 1
    fi
    . /etc/os-release
    if [[ ${ID:-} != debian && ${ID:-} != ubuntu ]]; then
        printf '%s\n' '自动准备 Python 仅支持 Debian/Ubuntu。' >&2
        exit 1
    fi
    printf '%s\n' '缺少 Python 3，正在准备脚本基础运行环境...'
    apt-get -o DPkg::Lock::Timeout=120 update || exit 1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends python3 || exit 1
    command -v python3 >/dev/null 2>&1 || exit 1
fi
export SBR_SOURCE="$(readlink -f -- "$0")"
read -r -d '' SBR_CODE <<'PY' || true
import os, sys, json, re, stat, pwd, subprocess, hashlib, secrets, shutil
import tempfile, pathlib, getpass, shlex, fcntl, signal, socket
from datetime import datetime, timezone
P = pathlib.Path
BASE = P('/etc/ssh-backup-receiver')
INST = P('/usr/local/libexec/ssh-backup-receiver.sh')
UNIT = P('/etc/systemd/system/ssh-backup-receiver.service')
MARK = '# ssh-backup-receiver managed v1\n'
NAME = re.compile(r'sbr_[a-z][a-z0-9_]{0,23}\Z')
FILE = re.compile(r'[^/\\\x00-\x1f\x7f]{1,200}\Z')
class Cancel(Exception): pass

def ask(label, default=None, secret=False):
    suffix = (' [默认 '+str(default)+']') if default is not None else ''
    value = getpass.getpass(label+suffix+'：') if secret else input(label+suffix+'：')
    if value in (':quit', ':cancel', '退出配置向导'): raise Cancel()
    return value if value else default

def new_password():
    value=ask('设置新密码至少16字符（隐藏输入）',secret=True)
    if not value or len(value)<16 or any(ch in value for ch in '\r\n\x00:'): raise ValueError('密码至少16字符，不得含换行、空字符或冒号')
    if ask('再次输入新密码',secret=True)!=value: raise ValueError('两次密码不一致')
    return value


def root():
    if os.geteuid() != 0: raise ValueError('此操作需要 root。')

def run(args, **kw):
    return subprocess.run(args, check=True, **kw)

def secure_dir(path, create=False):
    path = P(path)
    if not path.is_absolute() or '..' in path.parts: raise ValueError('目录必须为绝对路径且不含 ..')
    for part in [*reversed(path.parents), path]:
        if not part.exists() and not part.is_symlink() and create:
            part.mkdir(mode=0o700)
        s = part.lstat()
        if not stat.S_ISDIR(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o022:
            raise ValueError('目录及父目录必须为 root 所有、非链接且不可被其他用户写入：'+str(part))
    return path

def write(path, data, mode=0o600):
    path = P(path)
    if path.is_symlink(): raise ValueError('拒绝符号链接：'+str(path))
    fd, tmp = tempfile.mkstemp(prefix='.sbr-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def configs():
    # Only exact login-account names are configs; .budget/.admission are runtime state.
    return sorted(p for p in BASE.glob('sbr_*.json') if NAME.fullmatch(p.stem))

def load(user):
    if not NAME.fullmatch(user): raise ValueError('非法投递账号')
    secure_dir(BASE)
    p = BASE/(user+'.json'); s = p.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_uid != 0 or s.st_mode & 0o077: raise ValueError('配置权限不安全')
    c = json.loads(p.read_text())
    secure_dir(c['path'])
    return c

def directory_sync(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)

def receive(user=None):
    """Trusted supervisor does not parse network input; jailed child has no archive access."""
    import resource, ctypes
    root()
    user=user or os.environ.get('SUDO_USER','')
    account=pwd.getpwnam(user)
    if account.pw_uid==0: raise ValueError('禁止 root 投递身份')
    c=load(user)
    dest=secure_dir(c['path'])
    os.umask(0o077)
    # 每账号最多一个接收；空闲客户端不能占住其他账号的接收锁。
    with open(BASE/(user+'.receive.lock'),'a') as guard:
        try: fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('该账号正在接收，请稍后重试')
        # 限制连续重新连接；只存服务端时间，不接受客户端计数。
        import time
        ratepath=BASE/(user+'.admission.json')
        now=time.time()
        previous=json.loads(ratepath.read_text()) if ratepath.exists() else {}
        if 0<=now-previous.get('started',0)<c.get('receive_min_interval',5):
            raise ValueError('该账号连接过于频繁，请稍后重试')
        write(ratepath,json.dumps({'started':now}))
        # 有界全服务接收槽；不等待锁，避免无限排队/进程堆积。
        slot=None
        for index in range(4):
            candidate=open(BASE/('receive-slot-'+str(index)+'.lock'),'a')
            try: fcntl.flock(candidate,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                candidate.close();continue
            slot=candidate;break
        if slot is None: raise ValueError('接收端并发已满，请稍后重试')
        try:
            return receive_account_locked(user,account,c,dest)
        finally:slot.close()


def receive_account_locked(user,account,c,dest):
    import resource,ctypes
    incoming=secure_dir(dest/'.incoming',True)
    # 兼容旧接收器；有旧上传持锁则拒绝切换。
    with open(incoming/'lock','a') as oldlock:
        fcntl.flock(oldlock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for stale in incoming.glob('upload-*'):
            s=stale.lstat()
            if stat.S_ISREG(s.st_mode) and s.st_uid==0: stale.unlink()
        used=0;count=0;existing_sizes={}
        for p in dest.iterdir():
            if p.name=='.incoming': continue
            s=p.lstat()
            if not stat.S_ISREG(s.st_mode): raise ValueError('归档区存在非普通文件')
            used+=s.st_size;count+=1;existing_sizes[p.name]=s.st_size
        space=shutil.disk_usage(dest)
        reserve=max(c.get('reserve_bytes',2*1024**3),int(space.total*.1))
        free_budget=max(0,space.free-reserve)
        statepath=BASE/(user+'.budget.json')
        budget=json.loads(statepath.read_text()) if statepath.exists() else {}
        day=datetime.now(timezone.utc).strftime('%Y-%m-%d')
        if budget.get('day')!=day:budget={'day':day,'bytes':0,'files':0}
        remaining_bytes=max(0,c.get('daily_bytes',c['max_total'])-budget['bytes'])
        remaining_files=max(0,c.get('daily_files',100)-budget['files'])
        fd,tmp=tempfile.mkstemp(prefix='upload-',dir=incoming)
        r,w=os.pipe()
        pid=None
        try:
            pid=os.fork()
            if pid==0:
                try:
                    os.close(r)
                    # 空根目录，无程序、网络凭据或历史归档；唯一可写对象为继承的临时文件。
                    jail=secure_dir(BASE/'empty-jail',True)
                    os.chroot(jail);os.chdir('/')
                    os.setgroups([]);os.setgid(account.pw_gid);os.setuid(account.pw_uid)
                    if ctypes.CDLL(None).prctl(38,1,0,0,0)!=0: os._exit(90)
                    keep={0,1,2,fd,w}
                    for n in range(3, min(resource.getrlimit(resource.RLIMIT_NOFILE)[0],65536)):
                        if n not in keep:
                            try:os.close(n)
                            except OSError:pass
                    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
                    resource.setrlimit(resource.RLIMIT_FSIZE,(c['max_file'],c['max_file']))
                    resource.setrlimit(resource.RLIMIT_AS,(256*1024**2,256*1024**2))
                    resource.setrlimit(resource.RLIMIT_CPU,(120,120))
                    resource.setrlimit(resource.RLIMIT_NOFILE,(32,32))
                    resource.setrlimit(resource.RLIMIT_NPROC,(0,0))
                    def expired(*_):raise TimeoutError('接收超时')
                    signal.signal(signal.SIGALRM,expired);signal.alarm(30)
                    stream=sys.stdin.buffer;line=stream.readline(4097)
                    if len(line)>4096 or not line.endswith(b'\n'): raise ValueError('无效协议头')
                    h=json.loads(line)
                    if isinstance(h,dict) and set(h)=={'version','action','nonce'} and h['version']==1 and h['action'] in ('probe','info'):
                        if not isinstance(h['nonce'],str) or not re.fullmatch('[0-9a-f]{32}',h['nonce']):raise ValueError('编号无效')
                        result={'probe':h['nonce']}
                        if h['action']=='info':result['info']=True
                    else:
                        if not isinstance(h,dict) or set(h)!={'version','name','size','sha256','nonce'}:raise ValueError('无效协议字段')
                        name,size,sha,nonce=h['name'],h['size'],h['sha256'],h['nonce']
                        if type(h['version']) is not int or h['version']!=1 or not isinstance(name,str) or not FILE.fullmatch(name) or name.startswith('.') or len(name.encode())>240:raise ValueError('文件名无效')
                        if type(size) is not int or not 0<size<=c['max_file']:raise ValueError('文件过大')
                        if not isinstance(sha,str) or not re.fullmatch('[0-9a-f]{64}',sha) or not isinstance(nonce,str) or not re.fullmatch('[0-9a-f]{32}',nonce):raise ValueError('摘要或编号无效')
                        retry=name in existing_sizes and existing_sizes[name]==size
                        if not retry and (used+size>c['max_total'] or count>=c.get('max_files',10000)):raise ValueError('归档配额不足，不删除历史备份')
                        if size>free_budget:raise ValueError('磁盘安全余量不足')
                        if not retry and (size>remaining_bytes or remaining_files<1):raise ValueError('B端每日额度不足')
                        signal.alarm(c['timeout'])
                        with os.fdopen(fd,'wb',closefd=False) as out:
                            left=size
                            while left:
                                block=stream.read(min(left,1024*1024))
                                if not block:raise ValueError('数据不足')
                                space_now=os.fstatvfs(fd)
                                if space_now.f_bavail*space_now.f_frsize<len(block)+reserve:raise ValueError('磁盘安全余量不足')
                                out.write(block);left-=len(block)
                            if stream.read(1):raise ValueError('数据过长')
                            out.flush();os.fsync(fd)
                        result=h
                    encoded=json.dumps(result).encode()
                    if len(encoded)>4096:raise ValueError('回执过长')
                    os.write(w,encoded);os._exit(0)
                except BaseException:
                    os._exit(91)
            os.close(w);w=None
            _,status=os.waitpid(pid,0);pid=None
            raw=os.read(r,4097)
            if status!=0:raise ValueError('受限接收失败：协议、配额、超时或数据异常')
            h=json.loads(raw)
            if set(h) in ({'probe'},{'probe','info'}) and re.fullmatch('[0-9a-f]{32}',h['probe']):
                response={'version':1,'status':'ready','nonce':h['probe'],'protocol':'backup-put-v1','verification':'sha256-readback','history_readable':False}
                if h.get('info') is True:response['target']=str(dest)
                print(json.dumps(response),flush=True)
                return
            # 不能信任降权子进程：归档监督器再次检查所有输出及真实文件。
            if set(h)!={'version','name','size','sha256','nonce'}:raise ValueError('内部协议异常')
            name,size,sha,nonce=h['name'],h['size'],h['sha256'],h['nonce']
            if type(h['version']) is not int or h['version']!=1 or not isinstance(name,str) or not FILE.fullmatch(name) or name.startswith('.') or len(name.encode())>240:raise ValueError('文件名无效')
            if type(size) is not int or not 0<size<=c['max_file']:raise ValueError('配额不足')
            if not isinstance(sha,str) or not re.fullmatch('[0-9a-f]{64}',sha) or not isinstance(nonce,str) or not re.fullmatch('[0-9a-f]{32}',nonce):raise ValueError('摘要/编号无效')
            reserve=max(c.get('reserve_bytes',2*1024**3),int(shutil.disk_usage(dest).total*.1))
            if shutil.disk_usage(dest).free<reserve:raise ValueError('磁盘安全余量不足，拒绝归档，不删除历史备份')
            statepath=BASE/(user+'.budget.json')
            budget=json.loads(statepath.read_text()) if statepath.exists() else {}
            day=datetime.now(timezone.utc).strftime('%Y-%m-%d')
            if budget.get('day')!=day:budget={'day':day,'bytes':0,'files':0}
            s=os.fstat(fd)
            if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_nlink!=1 or s.st_size!=size:raise ValueError('暂存文件异常')
            os.lseek(fd,0,0);digest=hashlib.sha256()
            while True:
                block=os.read(fd,1024*1024)
                if not block:break
                digest.update(block)
            if digest.hexdigest()!=sha:raise ValueError('独立读回摘要不一致')
            final=dest/name
            if final.exists() or final.is_symlink():
                # 完整重传证明持有相同内容；不提供只凭文件名/摘要查询历史的接口。
                oldfd=os.open(final,os.O_RDONLY|os.O_NOFOLLOW)
                try:
                    oldstat=os.fstat(oldfd)
                    if not stat.S_ISREG(oldstat.st_mode) or oldstat.st_uid!=0 or oldstat.st_nlink!=1:raise ValueError('归档身份异常，禁止覆盖')
                    if oldstat.st_size!=size:
                        print(json.dumps({**h,'status':'conflict'}),flush=True)
                        return
                    oldhash=hashlib.sha256()
                    while True:
                        block=os.read(oldfd,1024*1024)
                        if not block:break
                        oldhash.update(block)
                    if oldhash.hexdigest()!=sha:
                        print(json.dumps({**h,'status':'conflict'}),flush=True)
                        return
                    after=os.fstat(oldfd)
                    if (oldstat.st_size,oldstat.st_mtime_ns,oldstat.st_ctime_ns)!=(after.st_size,after.st_mtime_ns,after.st_ctime_ns):raise ValueError('归档被其他管理进程修改')
                    os.fsync(oldfd);directory_sync(dest)
                finally:os.close(oldfd)
                print(json.dumps({**h,'status':'archived'}),flush=True)
                return
            if used+size>c['max_total'] or count>=c.get('max_files',10000):raise ValueError('归档配额不足')
            if budget['files']>=c.get('daily_files',100) or budget['bytes']+size>c.get('daily_bytes',c['max_total']):raise ValueError('达到B端每日投递额度')
            os.fchmod(fd,0o400)
            os.link(tmp,final,follow_symlinks=False)
            os.unlink(tmp);directory_sync(dest);directory_sync(incoming)
            budget['files']+=1;budget['bytes']+=size
            write(statepath,json.dumps(budget))
            print(json.dumps({**h,'status':'archived'}),flush=True)
        finally:
            if pid:
                try:os.kill(pid,signal.SIGKILL)
                except ProcessLookupError:pass
                os.waitpid(pid,0)
            os.close(fd);os.close(r)
            if w is not None:os.close(w)
            if os.path.exists(tmp):os.unlink(tmp)

def ensure_environment(role):
    root()
    import shutil as environment_shutil
    commands=['systemctl','ssh','ssh-keygen','ssh-keyscan','sshpass'] if role=='sender' else ['systemctl','sshd','ssh-keygen','useradd','userdel','chpasswd','visudo','sudo']
    missing=[cmd for cmd in commands if not environment_shutil.which(cmd)]
    if not missing: return
    osinfo={}
    for line in P('/etc/os-release').read_text().splitlines():
        if '=' in line:
            k,v=line.split('=',1);osinfo[k]=v.strip('"')
    if osinfo.get('ID') not in ('debian','ubuntu'):
        raise ValueError('自动安装仅支持 Debian/Ubuntu；请手动安装缺失命令：'+', '.join(missing))
    if not environment_shutil.which('apt-get'):raise ValueError('未找到 apt-get，无法自动安装环境')
    packages=['openssh-client','sshpass','systemd'] if role=='sender' else ['openssh-server','openssh-client','sudo','passwd','systemd']
    print('正在安装缺失的'+('A端传送' if role=='sender' else 'B端账号管理')+'环境：'+', '.join(missing))
    env={**os.environ,'DEBIAN_FRONTEND':'noninteractive','NEEDRESTART_MODE':'l'}
    subprocess.run(['apt-get','-o','DPkg::Lock::Timeout=120','update'],check=True,env=env,timeout=600)
    subprocess.run(['apt-get','-o','DPkg::Lock::Timeout=120','install','-y','--no-install-recommends',*packages],check=True,env=env,timeout=900)
    missing=[cmd for cmd in commands if not environment_shutil.which(cmd)]
    if missing:raise ValueError('依赖安装后仍缺少：'+', '.join(missing))


def dependencies():
    for cmd in ('sshd','ssh-keygen','useradd','userdel','chpasswd','visudo','systemctl','sudo'):
        if not shutil.which(cmd): raise ValueError('缺少依赖：'+cmd+'；Debian/Ubuntu 安装 openssh-server sudo，其他发行版使用对应软件包。')

def reconcile_service():
    root()
    if not UNIT.exists() or not (BASE/'owner').exists(): return
    if not UNIT.read_text().startswith(MARK): raise ValueError('拒绝操作非本脚本服务')
    active_accounts=[]
    for p in configs():
        load(p.stem)
        try: account=pwd.getpwnam(p.stem)
        except KeyError: raise ValueError('配置对应的投递账号不存在：'+p.stem)
        if account.pw_uid==0 or account.pw_shell!=str(INST.parent/'ssh-backup-login'):
            raise ValueError('投递账号身份异常：'+p.stem)
        active_accounts.append(p.stem)
    if active_accounts:
        run(['systemctl','enable','--now','ssh-backup-receiver.service'],stdout=subprocess.DEVNULL)
        run(['systemctl','is-active','--quiet','ssh-backup-receiver.service'])
        run(['systemctl','is-enabled','--quiet','ssh-backup-receiver.service'])
    else:
        run(['systemctl','disable','--now','ssh-backup-receiver.service'],stdout=subprocess.DEVNULL)
        if subprocess.run(['systemctl','is-active','--quiet','ssh-backup-receiver.service']).returncode==0:
            raise ValueError('接收服务仍在运行，停止失败')
        if subprocess.run(['systemctl','is-enabled','--quiet','ssh-backup-receiver.service']).returncode==0:
            raise ValueError('开机启动仍启用，禁用失败')


def service_label():
    if not UNIT.exists() or not (BASE/'owner').exists(): return '未安装'
    result=subprocess.run(['systemctl','is-active','ssh-backup-receiver.service'],capture_output=True,text=True)
    if result.returncode==0 and result.stdout.strip()=='active': return '运行中'
    if result.stdout.strip()=='inactive': return '已停止，无账号' if not configs() else '已停止，有账号'
    return '检测异常'


def install():
    root(); ensure_environment('receiver'); dependencies()
    print('部署独立 SSH 接收服务；给系统 SSH 添加投递账号禁入片段，不改变管理账号登录。不自动开放防火墙。输入 :quit 取消。')
    port=int(ask('独立接收 SSH 端口',int(os.environ.get('SBR_DEFAULT_PORT','22222'))))
    if not 1024<=port<=65535: raise ValueError('端口须为 1024–65535')
    bind=ask('监听地址（公网接收选 0.0.0.0，或填本机 IPv4）','0.0.0.0')
    socket.inet_pton(socket.AF_INET,bind)
    for p in (UNIT, BASE/'sshd_config'):
        if p.exists() and not p.read_text().startswith(MARK): raise ValueError('拒绝覆盖非本脚本文件：'+str(p))
    if INST.exists() and not (BASE/'owner').exists(): raise ValueError('安装路径已被其他文件占用')
    with socket.socket() as s: s.bind((bind,port))
    if not re.search(r'^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf\s*$',P('/etc/ssh/sshd_config').read_text(),re.M):
        raise ValueError('系统 SSH 未启用标准配置片段目录；为防止投递账号从原 SSH 端口绕过限制，本脚本拒绝自动安装。')
    deny=P('/etc/ssh/sshd_config.d/90-backup-receiver-deny.conf')
    if deny.exists() and not deny.read_text().startswith(MARK): raise ValueError('系统 SSH 限制片段已被占用')
    if ask('确认安装、限制投递账号不得登录原 SSH 服务，并启动独立服务，输入 yes')!='yes': return
    write(deny,MARK+'DenyUsers sbr_*\n',0o644)
    try:
        run([shutil.which('sshd'),'-t'])
    except BaseException:
        deny.unlink(); raise
    mainservice='ssh.service'
    if subprocess.run(['systemctl','is-active','--quiet',mainservice]).returncode:
        mainservice='sshd.service'
    run(['systemctl','reload',mainservice])
    secure_dir(BASE,True); secure_dir(INST.parent,True)
    source=P(os.environ['SBR_SOURCE']).read_text()
    write(INST,source,0o755); write(BASE/'owner',MARK)
    # 账号即使连到系统原有 SSH 端口，也只能进入接收器，不能得到 Shell。
    gate=INST.parent/'ssh-backup-login'
    if gate.exists() and not gate.read_text().startswith('#!/bin/sh\n'+MARK):
        raise ValueError('登录入口路径已占用')
    write(gate,'#!/bin/sh\n'+MARK+'exec /usr/bin/sudo -n -- '+str(INST)+' --receive\n',0o755)
    secure_dir(BASE/'keys',True)
    host=BASE/'host_ed25519'
    if not host.exists(): run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(host)])
    cfg=MARK+f'''Port {port}
ListenAddress {bind}
HostKey {host}
PidFile /run/ssh-backup-receiver.pid
AuthorizedKeysFile {BASE}/keys/%u
PermitRootLogin no
AllowUsers sbr_*
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods any
PermitEmptyPasswords no
UsePAM no
StrictModes yes
DisableForwarding yes
PermitTTY no
PermitUserRC no
PermitUserEnvironment no
X11Forwarding no
MaxAuthTries 3
MaxSessions 1
MaxStartups 5:30:10
LoginGraceTime 30
LogLevel VERBOSE
ForceCommand /usr/bin/sudo -n -- {INST} --receive
'''
    # OpenSSH root-owned authorized_keys 目录需要可遍历，密钥文件只读。
    os.chmod(BASE,0o755); os.chmod(BASE/'keys',0o755)
    write(BASE/'sshd_config',cfg)
    P('/run/sshd').mkdir(mode=0o755,exist_ok=True)
    run([shutil.which('sshd'),'-t','-f',str(BASE/'sshd_config')])
    unit=MARK+f'''[Unit]
Description=Write-only SSH backup receiver
After=network.target
[Service]
Type=simple
ExecStart={shutil.which('sshd')} -D -e -f {BASE}/sshd_config
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
'''
    write(UNIT,unit,0o644)
    run(['systemctl','daemon-reload'])
    reconcile_service()
    print('接收服务：'+service_label()+'。端口：'+str(port)+'；仅向 A 的 IP 开放防火墙。无账号时不监听。')
    print('B 主机指纹（在 A 首次连接时独立核对）：')
    run(['ssh-keygen','-lf',str(host)+'.pub'])

def parse_ips(text):
    import ipaddress
    tokens=[v for v in re.split(r'[,，、\s]+',text or '') if v]
    if not tokens: raise ValueError('至少填写一个允许的公网 IP，不能留空')
    result=[]
    for value in tokens:
        ip=str(ipaddress.ip_address(value))
        if ip not in result: result.append(ip)
    return result


def apply_ip_rules():
    root()
    path=BASE/'sshd_config'
    original=path.read_text()
    begin='# BEGIN SBR ACCOUNT IP RULES\n';end='# END SBR ACCOUNT IP RULES\n'
    config=original
    if begin in config:
        if config.count(begin)!=1 or config.count(end)!=1: raise ValueError('IP规则标记异常')
        start=config.index(begin);stop=config.index(end,start)+len(end)
        config=config[:start]+config[stop:]
    rules=''
    for p in configs():
        c=load(p.stem)
        if 'allowed_ips' not in c: continue # 旧账号未配置不擅自断开
        ips=parse_ips(','.join(c['allowed_ips']))
        rules+='Match User '+p.stem+' Address *,!'+',!'.join(ips)+'\n    DenyUsers '+p.stem+'\nMatch all\n'
    updated=config.rstrip()+'\n'+begin+rules+end
    write(path,updated)
    try:
        run([shutil.which('sshd'),'-t','-f',str(path)])
        running=subprocess.run(['systemctl','is-active','--quiet','ssh-backup-receiver.service']).returncode==0
        if running:
            run(['systemctl','kill','--kill-whom=main','--signal=HUP','ssh-backup-receiver.service'])
        reconcile_service()
    except BaseException:
        write(path,original)
        subprocess.run(['systemctl','kill','--kill-whom=main','--signal=HUP','ssh-backup-receiver.service'],check=False)
        raise


def configure_ips():
    root();home_mappings();entries=configs()
    if not entries: return
    choice=ask('选择设置来源 IP 的账号编号（0返回）','0')
    if choice=='0': return
    if not choice.isascii() or not choice.isdecimal() or not 1<=int(choice)<=len(entries): raise ValueError('编号无效')
    user=entries[int(choice)-1].stem;c=load(user)
    print('当前允许来源：'+('、'.join(c['allowed_ips']) if 'allowed_ips' in c else '尚未限制（旧账号）'))
    ips=parse_ips(ask('允许来源公网IP，多个用逗号分隔；不支持全网通配'))
    print(user+' 仅允许：'+'、'.join(ips)+'；端口不变。已有会话不会强制断开。')
    if ask('确认应用，输入 yes')!='yes': return
    old=json.dumps(c,ensure_ascii=False)
    c['allowed_ips']=ips;write(BASE/(user+'.json'),json.dumps(c,ensure_ascii=False))
    try: apply_ip_rules()
    except BaseException:
        write(BASE/(user+'.json'),old);raise
    print('来源 IP 限制已生效，密码和公钥均受限制。')


def add():
    root(); ensure_environment('receiver'); dependencies(); secure_dir(BASE)
    if not (BASE/'owner').exists(): raise ValueError('请先安装接收服务')
    print('每个账号绑定一个独立归档目录；输入 :quit 取消。')
    short=ask('账号名称（小写字母开头，可含数字和下划线）')
    user='sbr_'+str(short)
    if not NAME.fullmatch(user): raise ValueError('账号名称无效或过长')
    try: pwd.getpwnam(user)
    except KeyError: pass
    else: raise ValueError('账号已存在，不覆盖')
    if (BASE/(user+'.json')).exists(): raise ValueError('配置已存在')
    path=P(ask('最终归档专用目录','/home/备份/'+short))
    if path.exists() or path.is_symlink(): raise ValueError('为避免接管已有数据，必须指定尚不存在的专用目录')
    if not path.is_absolute() or '..' in path.parts or str(path).strip()!=str(path): raise ValueError('目录无效')
    # 不接管系统安装目录/配置目录。
    if not str(path).startswith(('/home/','/srv/','/mnt/','/data/')): raise ValueError('归档目录仅允许位于 /home、/srv、/mnt、/data 下')
    allowed_ips=parse_ips(ask('允许来源公网IP（多个用逗号分隔，必须填写）'))
    mode=ask('登录方式：1 密码，2 公钥，3 两者均可','1')
    if mode not in ('1','2','3'): raise ValueError('登录方式无效')
    password=None; key=None
    if mode in ('1','3'):
        password=new_password()
    if mode in ('2','3'):
        key=ask('粘贴 SSH 公钥（不是私钥）')
        if not key or '\n' in key or not re.match(r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) [A-Za-z0-9+/]+=*(?: .*)?$',key): raise ValueError('公钥格式错误；不接受自带 options 的公钥行')
        with tempfile.NamedTemporaryFile(mode='w',dir=BASE) as f:
            f.write(key+'\n'); f.flush()
            run(['ssh-keygen','-lf',f.name],stdout=subprocess.DEVNULL)
    max_file=int(ask('单文件上限 GiB',10))*1024**3
    max_total=int(ask('本账号归档总量上限 GiB',100))*1024**3
    timeout=int(ask('单次上传最长秒数',3600))
    if not 0<max_file<=max_total or not 30<=timeout<=86400: raise ValueError('配额或超时无效')
    if ask('确认创建投递账号和归档目录，输入 yes')!='yes': return
    secure_dir(path,True); os.chmod(path,0o700)
    sudoers=P('/etc/sudoers.d')/('ssh-backup-'+user)
    if sudoers.exists() or sudoers.is_symlink(): raise ValueError('sudoers 路径已占用')
    daily_files=int(ask('每日最多接收文件数（仅B管理员可改）',100))
    daily_bytes=int(ask('每日最多接收 GiB（仅B管理员可改）',10))*1024**3
    max_files=int(ask('归档最多文件数（达到后拒收，不删除历史）',10000))
    if not 1<=daily_files<=100000 or not 0<daily_bytes<=max_total or not 1<=max_files<=1000000: raise ValueError('接收额度无效')
    c={'allowed_ips':allowed_ips,'path':str(path),'max_file':max_file,'max_total':max_total,'timeout':timeout,'auth':mode,'daily_files':daily_files,'daily_bytes':daily_bytes,'max_files':max_files,'reserve_bytes':2*1024**3}
    created=False
    try:
        run(['useradd','--no-create-home','--home-dir','/nonexistent','--shell',str(INST.parent/'ssh-backup-login'),user]); created=True
        # 仅公钥账户也设置不可知随机密码，避免锁定账户导致公钥被拒；sudo 禁止修改密码。
        pw=password if password is not None else secrets.token_urlsafe(48)
        run(['chpasswd'],input=user+':'+pw+'\n',text=True)
        write(BASE/(user+'.json'),json.dumps(c,ensure_ascii=False)+'\n')
        if key: write(BASE/'keys'/user,'restrict '+key+'\n',0o644)
        write(sudoers,MARK+f'Defaults:{user} !requiretty\n{user} ALL=(root) NOPASSWD: {INST} --receive\n',0o440)
        run(['visudo','-cf',str(sudoers)],stdout=subprocess.DEVNULL)
        # 验证服务配置及真实账号匹配，不能只认为写入成功。
        run([shutil.which('sshd'),'-t','-f',str(BASE/'sshd_config')])
        apply_ip_rules()
        print('已添加：'+user+' → '+str(path)+'；密码与公钥均受同一 ForceCommand 和来源IP限制。')

    except BaseException:
        for p in (sudoers,BASE/(user+'.json'),BASE/'keys'/user):
            if p.exists(): p.unlink()
        if created: subprocess.run(['userdel',user],check=False)
        print('创建失败，已撤销本次账号与授权；保留已创建目录供管理员检查。',file=sys.stderr)
        raise

def listing():
    root()
    if not BASE.exists(): print('尚未安装'); return
    for p in configs():
        c=load(p.stem)
        print(p.stem+' → '+c['path']+'；登录方式 '+{'1':'密码','2':'公钥','3':'密码或公钥'}[c['auth']])
    if not configs(): print('暂无投递账号')
    subprocess.run(['systemctl','is-active','ssh-backup-receiver.service'],check=False)

def revoke():
    root()
    if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):
        print('\033[2J\033[H',end='',flush=True)
    entries=configs()
    print('==================================')
    home_mappings()
    if not entries: return
    print('删除所选投递登录用户及其授权配置，保留全部备份和归档目录。')
    selection=ask('输入要删除的账号编号（0 或回车取消）','0')
    if selection=='0': return
    if not selection.isascii() or not selection.isdecimal() or not 1<=int(selection)<=len(entries):
        raise ValueError('编号无效，未删除任何账号')
    user=entries[int(selection)-1].stem
    c=load(user)
    print('将删除账号：'+user+'；保留归档：'+c['path'])
    if ask('禁止后续登录。若为最后一个账号，将停止接收服务并结束其未完成上传（不影响已归档备份）。确认删除请输入 yes')!='yes': return
    # 删除授权及账号；不删除归档或修改已有数据。
    for p in (P('/etc/sudoers.d')/('ssh-backup-'+user),BASE/'keys'/user):
        if p.exists(): p.unlink()
    run(['userdel',user]); (BASE/(user+'.json')).unlink()
    apply_ip_rules()
    try: pwd.getpwnam(user)
    except KeyError: print('账号已撤销；归档保留：'+c['path'])
    else: raise ValueError('账号撤销验证失败')

def identity(path):
    s=path.stat(); return (s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns)

def upload():
    print('A 端安全投递；输入 :quit 取消。不会保存密码，不会删除本地文件。')
    path=P(ask('本地备份文件路径')).resolve(strict=True)
    if not path.is_file() or not FILE.fullmatch(path.name) or path.name.startswith('.'): raise ValueError('备份文件名无效')
    host=ask('B 服务器地址')
    if not host or host.startswith('-') or any(ch.isspace() for ch in host) or any(ch in host for ch in '@\x00'): raise ValueError('地址无效')
    port=int(ask('B 接收 SSH 端口',int(os.environ.get('SBR_DEFAULT_PORT','22222'))))
    if not 1<=port<=65535: raise ValueError('端口无效')
    user=ask('B 投递账号（sbr_ 开头）')
    if not NAME.fullmatch(user): raise ValueError('账号格式无效')
    mode=ask('登录方式：1 密码，2 私钥','1')
    if mode not in ('1','2'): raise ValueError('登录方式无效')
    args=['ssh','-F','/dev/null','-T','-p',str(port),'-o','StrictHostKeyChecking=ask','-o','ConnectTimeout=15','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-o','ClearAllForwardings=yes']
    password=None
    if mode=='2':
        key=P(ask('SSH 私钥绝对路径')).expanduser().resolve(strict=True)
        args+=['-i',str(key),'-o','IdentitiesOnly=yes','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no']
    else:
        if not shutil.which('sshpass'): raise ValueError('密码上传需要 sshpass；Debian/Ubuntu：apt install sshpass')
        password=ask('B 投递密码（隐藏输入）',secret=True)
        if not password or '\n' in password or '\x00' in password: raise ValueError('密码无效')
        args+=['-o','PubkeyAuthentication=no','-o','PreferredAuthentications=password','-o','KbdInteractiveAuthentication=no']
    before=identity(path); digest=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): digest.update(block)
    if identity(path)!=before: raise ValueError('文件在计算摘要时变化')
    nonce=secrets.token_hex(16)
    header={'version':1,'name':path.name,'size':before[2],'sha256':digest.hexdigest(),'nonce':nonce}
    # sshpass 遇未知指纹不会自行接受，用户必须手动核对并登记。
    known_host=('['+host+']:'+str(port)) if port!=22 else host
    known=P.home()/'.ssh/known_hosts'
    args+=['-o','UserKnownHostsFile='+str(known)]
    found=subprocess.run(['ssh-keygen','-F',known_host,'-f',str(known)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if found.returncode!=0:
        print('尚未信任 B 主机。请先在终端运行下列命令，与 B 管理员提供的指纹核对后再上传：')
        print(shlex.join(['ssh','-F','/dev/null','-p',str(port),user+'@'+host]))
        raise ValueError('未登记主机指纹；禁止自动信任')
    args[args.index('StrictHostKeyChecking=ask')]='StrictHostKeyChecking=yes'
    fds=(); readfd=writefd=None
    try:
        if password is not None:
            readfd,writefd=os.pipe(); os.write(writefd,(password+'\n').encode()); os.close(writefd); writefd=None
            args=['sshpass','-d',str(readfd),*args]; fds=(readfd,)
        args += [user+'@'+host,'backup-put']
        # stdout 回执很小；stderr 继承终端，避免错误管道死锁。
        proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,pass_fds=fds)
        try:
            proc.stdin.write((json.dumps(header)+'\n').encode())
            with path.open('rb') as f:
                for block in iter(lambda:f.read(1024*1024),b''): proc.stdin.write(block)
            proc.stdin.close(); proc.stdin=None
            out,_=proc.communicate(timeout=86460)
        except BaseException:
            proc.kill(); proc.wait(); raise
        if proc.returncode: raise ValueError('上传失败；本地备份保留。若回执丢失，需 B 管理员检查是否已归档，不可覆盖重试。')
        receipt=json.loads(out)
        if receipt!={**header,'status':'archived'} or identity(path)!=before: raise ValueError('回执不匹配或本地文件变化，不记录成功')
        print('上传并核验成功：'+path.name+'；SHA-256：'+digest.hexdigest())
    finally:
        if readfd is not None: os.close(readfd)
        if writefd is not None: os.close(writefd)

def home_mappings(title='已添加的传送端口与用户映射目录'):
    import unicodedata
    def safe(value):
        return ''.join(ch if not unicodedata.category(ch).startswith('C') else '?' for ch in str(value))
    def width(value):
        return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in ('W','F') else 1 for ch in value)
    def pad(value, length):
        return value+' '*max(0,length-width(value))
    if title is not None: print(title)
    rows=[]
    ip_rows=[]
    port='未配置'
    cfg=BASE/'sshd_config'
    if cfg.exists():
        try:
            match=re.search(r'^\s*Port\s+(\d+)\s*(?:#.*)?$',cfg.read_text(),re.M)
            port=match.group(1) if match and 1<=int(match.group(1))<=65535 else '配置异常'
        except (OSError,ValueError): port='读取失败'
    for index,p in enumerate(configs(),1):
        try:
            c=load(p.stem)
            method={'1':'密码','2':'公钥','3':'密码或公钥'}.get(c.get('auth'),'未知')
            password='已设置' if c.get('auth') in ('1','3') else '不适用'
            ip_info=('，'.join(parse_ips(','.join(c['allowed_ips']))),'32') if c.get('allowed_ips') else ('暂无','31')
            rows.append([str(index)+'. '+port,p.stem,safe(c['path']),method,password])
            ip_rows.append(ip_info)
        except Exception:
            rows.append([str(index)+'. '+port,safe(p.stem),'配置不可读或目录异常','读取失败','—'])
            ip_rows.append(('读取失败','31'))
    headers=['端口','用户名','路径','方式','密码']
    lengths=[max([width(headers[i])]+[width(row[i]) for row in rows])+3 for i in range(4)]
    print(''.join(pad(headers[i],lengths[i]) for i in range(4))+headers[4])
    for row,(ip_text,ip_color) in zip(rows,ip_rows):
        print(''.join(pad(row[i],lengths[i]) for i in range(4))+row[4])
        if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):
            ip_text='\033['+ip_color+'m'+ip_text+'\033[0m'
        print('允许连接 IP ：'+ip_text)
    if not rows: print('暂无')
    print('==================================')


def change_password():
    root();home_mappings();entries=configs()
    if not entries: return
    selection=ask('选择修改密码的账号编号（0返回）','0')
    if selection=='0': return
    if not selection.isascii() or not selection.isdecimal() or not 1<=int(selection)<=len(entries): raise ValueError('编号无效')
    user=entries[int(selection)-1].stem;c=load(user)
    account=pwd.getpwnam(user)
    if account.pw_uid==0 or account.pw_shell!=str(INST.parent/'ssh-backup-login'): raise ValueError('账号身份异常，拒绝修改')
    password=new_password()
    if c['auth']=='2': print('此账号目前仅公钥登录；设置密码后将允许密码或公钥登录。')
    if ask('确认修改 '+user+' 的密码，输入 yes')!='yes': return
    run(['chpasswd'],input=user+':'+password+'\n',text=True)
    c['auth']='3' if c['auth'] in ('2','3') else '1'
    write(BASE/(user+'.json'),json.dumps(c,ensure_ascii=False))
    print('密码已修改；允许IP、公钥和归档目录不变。A端已保存的旧密码需同步更新。')



def accounts_menu():
    root()
    while True:
        if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):
            print('\033[2J\033[H',end='',flush=True)
        print('==================================')
        print('管理现有的 B 端账号')
        print('==================================')
        home_mappings(None)
        print('1. 添加投递账号（密码 / 公钥 / 两者）')
        print('2. 修改密码')
        print('3. 修改允许IP')
        print('4. B 端：查看账号与服务状态')
        print('9. 删除账号（保留备份）')
        print('------------------------')
        print('0. 返回上一级')
        print('------------------------')
        choice=input('请输入选项：')
        if choice=='0': return
        action={'1':add,'2':change_password,'3':configure_ips,'4':listing,'9':revoke}.get(choice)
        try:
            if action: action()
            else: print('无效选项')
        except (Cancel,EOFError,KeyboardInterrupt): print('\n已取消')
        except Exception as e: print('失败：'+str(e),file=sys.stderr)
        input('按回车继续...')


def colored_service_label():
    label=service_label()
    if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):
        code={'运行中':'32','已停止，无账号':'33','未安装':'31'}.get(label,'33')
        return '\033['+code+'m'+label+'\033[0m'
    return label


def service_action():
    if UNIT.exists() and (BASE/'owner').exists():
        reconcile_service()
        print('接收服务：'+service_label()+'；程序、配置、主机密钥及备份保留。')
    else: install()


def parse_connection_stats(records,user):
    import ipaddress
    stats={}
    for d in records:
        message=d.get('MESSAGE','')
        if not isinstance(message,str): continue
        identifier=d.get('SYSLOG_IDENTIFIER','')
        if identifier not in ('sshd','sshd-session','sshd-auth','') and d.get('_COMM') not in ('sshd','sshd-session','sshd-auth'):continue
        try:stamp=int(d['__REALTIME_TIMESTAMP'])/1000000
        except (KeyError,ValueError,TypeError):continue
        matched=re.search(r'\b(?:Accepted|Failed) \S+ for (?:invalid user )?(\S+) from (\S+) port \d+',message)
        kind=None;ip=None;account=None
        if matched:
            account,ip=matched.groups()
            kind='ok' if message.startswith('Accepted ') else 'fail'
        else:
            denied=re.search(r'\bUser (\S+) from (\S+) not allowed because',message)
            if denied:
                account,ip=denied.groups();kind='fail'
            elif 'authentication failure' in message:
                um=re.search(r'\buser=(\S+)',message);im=re.search(r'\brhost=(\S+)',message)
                if um and im:account,ip,kind=um.group(1),im.group(1),'fail'
        if kind is None or account!=user:continue
        try:ip=str(ipaddress.ip_address(ip))
        except ValueError:continue
        row=stats.setdefault(ip,{'ok':0,'fail':0,'last':None})
        row[kind]+=1
        if kind=='ok':row['last']=stamp if row['last'] is None else max(stamp,row['last'])
    return stats


def connection_report(user,days,mode):
    root()
    proc=subprocess.Popen(['journalctl','-u','ssh-backup-receiver.service','--since',str(days)+' days ago','--no-pager','-o','json'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    # Stream journal rather than loading up to30 days of raw logs into memory.
    def entries():
        for line in proc.stdout:
            try:yield json.loads(line)
            except (ValueError,TypeError):continue
    stats=parse_connection_stats(entries(),user)
    proc.stderr.read();code=proc.wait()
    if code:raise ValueError('读取接收服务日志失败，请检查 journalctl 权限和日志服务')
    chosen=[(ip,row) for ip,row in stats.items() if row['ok' if mode=='1' else 'fail']>0]
    chosen.sort(key=lambda item:(-item[1]['ok' if mode=='1' else 'fail'],-item[1]['ok']-item[1]['fail'],item[0]))
    if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):
        print('\033[2J\033[H',end='',flush=True)
    print('==================================')
    print(('成功' if mode=='1' else '失败')+'统计 TOP50；账号：'+user+'；最近'+str(days)+'天')
    print('来源IP    成功    失败    最后成功时间')
    if not chosen:
        text='暂无'
        if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):text='\033[31m'+text+'\033[0m'
        print(text)
    from zoneinfo import ZoneInfo
    for ip,row in chosen[:50]:
        last=datetime.fromtimestamp(row['last'],ZoneInfo('Asia/Shanghai')).strftime('%Y-%m-%d %H:%M:%S') if row['last'] is not None else '—'
        print(ip+'    '+str(row['ok'])+'    '+str(row['fail'])+'    '+last)
    print('最后成功时间为北京时间；次数按可归属到此账号的认证/拒绝日志事件统计，不等于独立会话数。')
    print('仅查询本服务已有日志；日志保留不足时无法补回历史。登录成功不代表备份上传成功。')


def connection_menu():
    root()
    while True:
        if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):print('\033[2J\033[H',end='')
        print('1. 查看成功统计 TOP50')
        print('2. 查看失败统计 TOP50')
        print('0. 返回上一级')
        mode=ask('请输入选项','0')
        if mode=='0':return
        if mode not in ('1','2'):print('无效选项');continue
        print('==================================')
        home_mappings()
        entries=configs()
        if not entries:
            input('按回车继续...');continue
        selection=ask('输入要查询的账号编号（0 或回车取消）','0')
        if selection=='0':continue
        if not selection.isascii() or not selection.isdecimal() or not 1<=int(selection)<=len(entries):
            print('账号编号无效');continue
        user=entries[int(selection)-1].stem
        print('统计范围:')
        print('1. 最近7天')
        print('2. 最近15天')
        print('3. 最近30天')
        print('0. 返回上一级')
        span=ask('请输入你的选择（回车默认1）','1')
        if span=='0':continue
        if span not in ('1','2','3'):print('无效统计范围');continue
        try:connection_report(user,{'1':7,'2':15,'3':30}[span],mode)
        except Exception as e:print('失败：'+str(e),file=sys.stderr)
        input('按回车继续...')


def uninstall_receiver():
    root()
    if not (BASE/'owner').exists():print('接收端未安装或缺少所有权标记，未删除任何文件。');return
    if (BASE/'owner').read_text()!=MARK:raise ValueError('接收端所有权标记异常')
    if not UNIT.exists() or UNIT.is_symlink() or not UNIT.read_text().startswith(MARK):raise ValueError('接收服务身份异常，拒绝卸载')
    users=[p.stem for p in configs()]
    gate=INST.parent/'ssh-backup-login'
    deny=P('/etc/ssh/sshd_config.d/90-backup-receiver-deny.conf')
    targets=[UNIT,INST,gate]
    for p in (INST,gate):
        if p.is_symlink() or not p.is_file():raise ValueError('安装程序路径异常：'+str(p))
    if not gate.read_text().startswith('#!/bin/sh\n'+MARK):raise ValueError('账号登录入口身份异常')
    if deny.exists() and (deny.is_symlink() or not deny.read_text().startswith(MARK)):raise ValueError('原SSH限制片段不属于本脚本')
    for user in users:
        load(user);account=pwd.getpwnam(user)
        if account.pw_uid==0 or account.pw_shell!=str(gate):raise ValueError('投递账号身份异常')
        sudoers=P('/etc/sudoers.d')/('ssh-backup-'+user)
        if sudoers.is_symlink() or not sudoers.is_file() or not sudoers.read_text().startswith(MARK):raise ValueError('账号授权文件身份异常')
    print('将卸载B接收端：接收服务、投递账号、公钥授权、专用主机密钥、接收配置和安装程序。')
    print('保留全部归档、A端任务、当前管理脚本、系统OpenSSH及其他账号的公私钥。')
    print('涉及投递账号：'+('、'.join(users) if users else '暂无'))
    if ask('确认卸载请输入精确小写 yes')!='yes':return
    import contextlib
    with contextlib.ExitStack() as locks:
        # Guard both versions; active receivers fail closed instead of being terminated.
        for path in [BASE/'receive-global.lock',*[BASE/(u+'.receive.lock') for u in users]]:
            lock=locks.enter_context(open(path,'a'));fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for user in users:
            account=pwd.getpwnam(user)
            result=subprocess.run(['pgrep','-u',str(account.pw_uid)],stdout=subprocess.DEVNULL)
            if result.returncode==0:raise ValueError('投递账号仍有会话/进程，请结束后重试：'+user)
            if result.returncode!=1:raise ValueError('无法确认账号会话状态，取消卸载')
        run(['systemctl','disable','--now','ssh-backup-receiver.service'])
        if subprocess.run(['systemctl','is-active','--quiet','ssh-backup-receiver.service']).returncode==0:raise ValueError('接收服务停止失败')
        for user in users:
            run(['userdel',user])
            (P('/etc/sudoers.d')/('ssh-backup-'+user)).unlink()
        # Accounts removed first, so removing old-service denial cannot expose them.
        if deny.exists():
            previous=deny.read_text();deny.unlink()
            try:run([shutil.which('sshd'),'-t'])
            except BaseException:
                write(deny,previous,0o644);raise
            main='ssh.service' if subprocess.run(['systemctl','is-active','--quiet','ssh.service']).returncode==0 else 'sshd.service'
            run(['systemctl','reload',main])
        for path in targets:path.unlink()
        # BASE is root-owned; don't follow links when removing owned receiver tree.
        secure_dir(BASE);shutil.rmtree(BASE)
        run(['systemctl','daemon-reload'])
    if UNIT.exists() or BASE.exists():raise ValueError('卸载校验失败，仍有接收配置残留')
    print('B接收端已卸载，历史备份和A端配置保留。')


def menu():
    while True:
        if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'): print('\033[2J\033[H',end='')
        print('==================================')
        print('      SSH 安全备份投递管理')
        print('仅新增上传；B 独立读回核验；历史归档不对 A 开放')
        print('==================================')
        sender_command(['summary'])
        print('==================================')
        home_mappings()
        print('1. A 端：备份传送配置（对接 B 端接收服务）')
        print('2. A 端：上传并核验一个备份文件')
        print('==================================')
        print('11. B 接收端：接收服务（'+colored_service_label()+'）')
        print('12. B 接收端：添加账号与管理账号')
        print('13. B 接收端：SSH 登录统计')
        print('19. B 接收端：卸载')
        print('------------------------')
        print('0. 退出')
        print('------------------------')
        choice=input('请输入选项：')
        if choice=='0': print('已退出'); return
        if choice=='1':
            sender_menu()
            continue
        if choice=='13':
            connection_menu()
            continue
        if choice=='12':
            accounts_menu()
            continue
        action={'11':service_action,'2':upload,'19':uninstall_receiver}.get(choice)
        try:
            if action: action()
            else: print('无效选项')
        except (Cancel,EOFError,KeyboardInterrupt): print('\n已取消')
        except Exception as e: print('失败：'+str(e),file=sys.stderr)
        input('按回车继续...')

SENDER_SOURCE='#!/usr/bin/python3\n"""Independent safe-drop tasks; no changes to ordinary SSH/S3 categories."""\nimport os,sys,json,re,stat,pathlib,tempfile,subprocess,hashlib,secrets,time,fcntl,getpass,tarfile,gzip,logging,logging.handlers\nP=pathlib.Path\nROOT=P(\'/etc/ssh-backup-receiver-sender\')\nENGINE=P(os.environ[\'SBR_SOURCE\'])\nUNITDIR=P(\'/etc/systemd/system\')\nMARK=\'# ssh-backup-receiver-sender owned v1\\n\'\nclass Cancel(Exception):pass\nclass Conflict(Exception):pass\n\ndef prompt(label,default=None,secret=False):\n    v=getpass.getpass(label+\'：\') if secret else input(label+(\' [默认 \'+str(default)+\']\' if default is not None else \'\')+\'：\')\n    if v in (\':quit\',\':cancel\',\'退出配置向导\'):raise Cancel()\n    return v if v else default\n\ndef safe_dir(p,create=False):\n    p=P(p)\n    if not p.is_absolute() or \'..\' in p.parts:raise ValueError(\'必须使用不含 .. 的绝对路径\')\n    for part in [*reversed(p.parents),p]:\n        if not part.exists() and not part.is_symlink() and create:part.mkdir(mode=0o700)\n        s=part.lstat()\n        if not stat.S_ISDIR(s.st_mode) or s.st_uid!=0 or s.st_mode&0o022:raise ValueError(\'目录须为 root 所有、非链接且不可被其他用户写入：\'+str(part))\n    return p\n\ndef init():\n    if os.geteuid()!=0:raise ValueError(\'请以 root 运行任务管理\')\n    safe_dir(ROOT,True)\n\ndef atomic(p,value):\n    if p.is_symlink():raise ValueError(\'拒绝配置链接\')\n    fd,tmp=tempfile.mkstemp(dir=p.parent,prefix=\'.write-\')\n    try:\n        with os.fdopen(fd,\'w\') as f:\n            os.fchmod(f.fileno(),0o600);json.dump(value,f,ensure_ascii=False);f.flush();os.fsync(f.fileno())\n        os.replace(tmp,p)\n    finally:\n        if os.path.exists(tmp):os.unlink(tmp)\n\ndef read_json(p):\n    s=p.lstat()\n    if not stat.S_ISREG(s.st_mode) or s.st_uid!=0 or s.st_mode&0o077:raise ValueError(\'配置/凭据权限异常\')\n    return json.loads(p.read_text())\n\ndef taskpath(name):\n    if not re.fullmatch(\'[a-z][a-z0-9_-]{0,31}\',name):raise ValueError(\'名称须小写字母开头，只含小写字母/数字/_/-，最多32字符\')\n    locator=ROOT/(name+\'.json\')\n    if locator.exists():\n        data=read_json(locator);return safe_dir(P(data.get(\'config_base\',data[\'local\']))/\'ssh_backup_receiver\'/name)\n    return ROOT/name\n\ndef rows():\n    result=[]\n    for locator in sorted(ROOT.glob(\'*.json\')):\n        try:\n            task=taskpath(locator.stem);c=read_json(task/\'config.json\');result.append((task,c))\n        except Exception: print(\'任务配置异常：\'+locator.stem,file=sys.stderr)\n    return result\n\ndef emit(task,message):\n    path=task/\'transfer.log\'\n    if path.is_symlink() or (task/\'log.lock\').is_symlink():raise ValueError(\'日志/锁不能是符号链接\')\n    with open(task/\'log.lock\',\'a\') as lock:\n        os.chmod(task/\'log.lock\',0o600);fcntl.flock(lock,fcntl.LOCK_EX)\n        if not path.exists():\n            fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600);os.close(fd)\n        os.chmod(path,0o600)\n        h=logging.handlers.RotatingFileHandler(path,maxBytes=2*1024*1024,backupCount=3,encoding=\'utf-8\')\n        try:\n            h.setFormatter(logging.Formatter(\'%(asctime)s %(message)s\'))\n            h.emit(logging.LogRecord(\'safe-drop\',20,\'\',0,message,(),None))\n            os.chmod(path,0o600)\n        finally:h.close()\n\ndef run(args,**kw):return subprocess.run(args,check=True,**kw)\n\ndef ssh(task,c):\n    args=[\'ssh\',\'-F\',\'/dev/null\',\'-T\',\'-p\',str(c[\'port\']),\'-o\',\'StrictHostKeyChecking=yes\',\'-o\',\'UserKnownHostsFile=\'+str(task/\'known_hosts\'),\'-o\',\'ConnectTimeout=15\',\'-o\',\'ServerAliveInterval=15\',\'-o\',\'ServerAliveCountMax=3\',\'-o\',\'ClearAllForwardings=yes\',\'-o\',\'BatchMode=yes\']\n    fd=None\n    if c[\'auth\']==\'key\':args+=[\'-i\',c[\'key\'],\'-o\',\'IdentitiesOnly=yes\',\'-o\',\'PasswordAuthentication=no\',\'-o\',\'KbdInteractiveAuthentication=no\']\n    else:\n        args[args.index(\'BatchMode=yes\')]=\'BatchMode=no\'\n        args+=[\'-o\',\'PubkeyAuthentication=no\',\'-o\',\'PreferredAuthentications=password\',\'-o\',\'KbdInteractiveAuthentication=no\',\'-o\',\'NumberOfPasswordPrompts=1\']\n        # 不将秘密放到 argv、环境变量或日志；FD 为受保护的匿名临时文件。\n        password=read_json(task/\'password.json\')[\'password\']\n        f=tempfile.TemporaryFile(dir=task);f.write((password+\'\\n\').encode());f.seek(0)\n        fd=f.fileno();args=[\'sshpass\',\'-d\',str(fd),*args]\n    args+=[c[\'user\']+\'@\'+c[\'host\'],\'backup-put\']\n    return args,(f if fd is not None else None)\n\ndef exchange(task,c,header,path=None):\n    args,secret=ssh(task,c)\n    # 单笔传输硬超时：独立进程组 watchdog 负责阻断可能阻塞的 stdin 写入。\n    proc=None\n    import threading,signal\n    def abort():\n        if proc and proc.poll() is None:\n            try:os.killpg(proc.pid,signal.SIGKILL)\n            except ProcessLookupError:pass\n    timer=None\n    try:\n        with tempfile.TemporaryFile(dir=task) as err:\n            proc=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=err,pass_fds=(() if secret is None else (secret.fileno(),)),start_new_session=True)\n            timer=threading.Timer(c.get(\'timeout\',3600),abort);timer.daemon=True;timer.start()\n            try:\n                proc.stdin.write((json.dumps(header)+\'\\n\').encode())\n                if path:\n                    with path.open(\'rb\') as f:\n                        for block in iter(lambda:f.read(1024*1024),b\'\'):proc.stdin.write(block)\n                proc.stdin.close();proc.stdin=None\n                out,_=proc.communicate()\n            except BaseException:\n                abort();proc.wait();raise\n            if proc.returncode:\n                err.seek(0);detail=err.read(65536).decode(\'utf-8\',\'replace\').lower()\n                if \'无效协议字段\' in detail or \'invalid protocol\' in detail:\n                    reason=\'B 已安装接收程序不支持探测协议，需更新 /usr/local/libexec/ssh-backup-receiver.sh（不重建账号）\'\n                elif \'permission denied\' in detail or proc.returncode==5:\n                    reason=\'SSH 认证失败，请检查 B 专用账号、密码和该账号是否允许登录\'\n                elif \'host key verification failed\' in detail or \'remote host identification has changed\' in detail:\n                    reason=\'B 主机密钥校验失败，禁止自动更换已信任指纹\'\n                elif \'connection refused\' in detail:\n                    reason=\'B 接收端口拒绝连接，请检查独立接收服务及端口\'\n                elif \'timed out\' in detail or proc.returncode<0:\n                    reason=\'SSH 连接或接收超时\'\n                elif \'sudo:\' in detail:\n                    reason=\'B 接收账号的 sudo 接收授权或安装程序异常\'\n                else:reason=\'B 认证或接收处理失败，请检查 B 接收服务日志（退出码 \'+str(proc.returncode)+\'）\'\n                raise ValueError(reason)\n            if len(out)>8192:raise ValueError(\'接收回执过长\')\n            return json.loads(out)\n    finally:\n        if timer:timer.cancel()\n        if secret:secret.close()\n\ndef probe(task,c):\n    nonce=secrets.token_hex(16)\n    response=exchange(task,c,{\'version\':1,\'action\':\'info\',\'nonce\':nonce})\n    if response.get(\'nonce\')!=nonce or response.get(\'status\')!=\'ready\' or response.get(\'history_readable\') is not False or not isinstance(response.get(\'target\'),str):\n        raise ValueError(\'B需更新接收程序以支持绑定目录查询\')\n    c[\'target\']=response[\'target\'];atomic(task/\'config.json\',c)\n    return response\n\ndef trust(task,c):\n    print(\'将显示 B SSH 主机指纹，必须与 B 管理员独立核对；不上传备份。\')\n    r=run([\'ssh-keyscan\',\'-T\',\'10\',\'-p\',str(c[\'port\']),\'--\',c[\'host\']],capture_output=True,timeout=40)\n    lines=[l for l in r.stdout.decode().splitlines() if l and not l.startswith(\'#\')]\n    if not lines:raise ValueError(\'未获取到主机公钥\')\n    fd,tmp=tempfile.mkstemp(dir=task)\n    try:\n        with os.fdopen(fd,\'w\') as f:f.write(\'\\n\'.join(lines)+\'\\n\')\n        run([\'ssh-keygen\',\'-lf\',tmp])\n        if prompt(\'已独立核对以上指纹，输入 yes 信任\')!=\'yes\':raise Cancel()\n        os.replace(tmp,task/\'known_hosts\');os.chmod(task/\'known_hosts\',0o600)\n    finally:\n        if os.path.exists(tmp):os.unlink(tmp)\n\ndef unit_paths(name):\n    stem=\'ssh-backup-send-\'+name\n    return UNITDIR/(stem+\'.service\'),UNITDIR/(stem+\'.timer\')\n\ndef schedule(task,c,delete=False):\n    service,timer=unit_paths(task.name)\n    for path in (service,timer):\n        if path.is_symlink() or (path.exists() and not path.read_text().startswith(MARK)):raise ValueError(\'拒绝接管其他服务：\'+str(path))\n    if delete:\n        if timer.exists():run([\'systemctl\',\'disable\',\'--now\',timer.name],stdout=subprocess.DEVNULL)\n        if service.exists():run([\'systemctl\',\'stop\',service.name])\n        for p in (service,timer):\n            if p.exists():p.unlink()\n        run([\'systemctl\',\'daemon-reload\']);return\n    text=MARK+\'[Unit]\\nDescription=Safe backup drop \'+task.name+\'\\n[Service]\\nType=oneshot\\nUMask=0077\\nExecStart=/bin/bash \'+str(ENGINE)+\' --sender tick \'+task.name+\'\\n\'\n    tim=MARK+\'[Unit]\\nDescription=Safe backup drop timer\\n[Timer]\\nOnBootSec=60s\\nOnUnitInactiveSec=60s\\nAccuracySec=1s\\n[Install]\\nWantedBy=timers.target\\n\'\n    for p,body in ((service,text),(timer,tim)):\n        if not p.exists() or p.read_text()!=body:p.write_text(body);p.chmod(0o644)\n    run([\'systemctl\',\'daemon-reload\']);run([\'systemctl\',\'enable\',\'--now\',timer.name],stdout=subprocess.DEVNULL)\n    run([\'systemctl\',\'is-enabled\',\'--quiet\',timer.name]);run([\'systemctl\',\'is-active\',\'--quiet\',timer.name])\n\ndef reusable(task):\n    if not task.exists() and not task.is_symlink():return\n    safe_dir(task)\n    for p in task.iterdir():\n        s=p.lstat()\n        if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or (p.name not in (\'run.lock\',\'log.lock\') and not re.fullmatch(r\'transfer\\.log(?:\\.[1-3])?\',p.name)):\n            raise ValueError(\'同名配置或未知文件已存在：\'+str(p))\n    with open(task/\'run.lock\',\'a\') as lock:\n        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n\ndef create():\n    init();print(\'输入 :quit 取消。安全投递不会改动普通 SSH/S3 任务。\')\n    name=prompt(\'任务名（小写安全名称）\');task=taskpath(name)\n    reusable(task)\n    c={\'mode\':\'transfer\',\'name\':name,\'generation\':secrets.token_hex(16)}\n    c[\'host\']=prompt(\'B 服务器 IP 或域名\')\n    if not c[\'host\'] or not re.fullmatch(r\'[A-Za-z0-9:.\\-]+\',c[\'host\']) or c[\'host\'].startswith(\'-\'):raise ValueError(\'主机名无效\')\n    c[\'port\']=int(prompt(\'B 安全接收 SSH 端口\',int(os.environ.get(\'SBR_DEFAULT_PORT\',\'22222\'))))\n    if not 1<=c[\'port\']<=65535:raise ValueError(\'端口无效\')\n    c[\'user\']=prompt(\'B 专用投递账号（完整用户名）\')\n    if not re.fullmatch(\'sbr_[a-z][a-z0-9_]{0,23}\',c[\'user\']):raise ValueError(\'投递用户名无效\')\n    auth=prompt(\'认证方式：1 私钥，2 密码\',\'1\');password=None\n    if auth==\'1\':\n        c[\'auth\']=\'key\';key=P(prompt(\'SSH 私钥路径\',\'/root/.ssh/id_ed25519\')).expanduser().resolve(strict=True)\n        s=key.stat()\n        if not key.is_file() or s.st_uid!=0 or s.st_mode&0o077:raise ValueError(\'私钥须 root 所有，权限 0600 或更严格\')\n        c[\'key\']=str(key)\n    elif auth==\'2\':\n        if not shutil_which(\'sshpass\'):raise ValueError(\'请先安装 sshpass\')\n        if prompt(\'密码将明文保存在本地0600凭据文件，输入 yes 同意\')!=\'yes\':raise Cancel()\n        c[\'auth\']=\'password\';password=prompt(\'B 投递账号密码（隐藏输入）\',secret=True)\n        if not password or any(x in password for x in \'\\r\\n\\x00\'):raise ValueError(\'密码无效\')\n    else:raise ValueError(\'认证方式无效\')\n    config_base=P(prompt(\'配置本地保存路径\',\'/home/备份/\'+name)).expanduser()\n    if not config_base.is_absolute() or \'..\' in config_base.parts:raise ValueError(\'配置路径必须为安全绝对路径\')\n    print(color(\'Discourse论坛生成的备份目录应输入\',\'33\')+\'（\'+color(\'需实际查看真实路径\',\'31\')+\'）\')\n    print(color(\'/var/discourse/shared/standalone/backups/default\',\'32\'))\n    print(\'本地备份读取目录（仅此目录直接子文件 *.tar.gz）\')\n    local=P(prompt(\'请输入你的选择\',\'/home/备份/\'+name)).expanduser()\n    safe_dir(local);c[\'local\']=str(local);c[\'config_base\']=str(config_base)\n    # Do not create configuration folders under archive input; source stays read-only.\n    task=config_base/\'ssh_backup_receiver\'/name\n    if task.exists():reusable(task)\n    reusable(task)\n    print(\'B 最终目录由 B 的投递账号绑定，A 不填写远端路径；不清理本地或远端历史备份。\')\n    print(\'任务配置：\'+str(task)+\'；本地目录：\'+str(local))\n    if prompt(\'确认创建，输入 yes\')!=\'yes\':return\n    # 独立注册锁，防止两个向导覆盖同名配置。\n    with open(ROOT/\'.registry.lock\',\'a\') as registry:\n        fcntl.flock(registry,fcntl.LOCK_EX)\n        safe_dir(config_base/\'ssh_backup_receiver\',True)\n        reusable(task)\n        task.mkdir(mode=0o700,exist_ok=True)\n        with open(task/\'run.lock\',\'a\') as guard:\n            fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB)\n            atomic(task/\'config.json\',c)\n            atomic(ROOT/(name+\'.json\'),{\'local\':str(local),\'config_base\':str(config_base)})\n            if password is not None:atomic(task/\'password.json\',{\'password\':password})\n    try:\n        trust(task,c);probe(task,c);atomic(task/\'trusted.json\',{\'generation\':c[\'generation\']})\n        schedule(task,c)\n        print(\'已验证并启用60秒检查定时器；未立即上传。传送文件须稳定10秒。\')\n    except BaseException:\n        print(\'配置已保留，尚未确认任务调度正常；可选2重新验证并修复调度。\',file=sys.stderr);raise\n\ndef shutil_which(cmd):\n    import shutil\n    return shutil.which(cmd)\n\ndef identity(path):\n    s=path.lstat()\n    if not stat.S_ISREG(s.st_mode):raise ValueError(\'不是普通文件\')\n    return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns]\n\ndef digest_archive(path):\n    before=identity(path)\n    # 读取全部成员及 gzip 尾部，拒绝损坏归档；不解压。\n    with gzip.open(path,\'rb\') as g:\n        with tarfile.open(fileobj=g,mode=\'r|\') as tar:\n            for member in tar:\n                if member.isfile():\n                    f=tar.extractfile(member)\n                    while f.read(1024*1024):pass\n        while g.read(1024*1024):pass\n    h=hashlib.sha256()\n    with path.open(\'rb\') as f:\n        for b in iter(lambda:f.read(1024*1024),b\'\'):h.update(b)\n    if identity(path)!=before:raise ValueError(\'归档校验时变化\')\n    return before,h.hexdigest()\n\ndef send(task,c,path):\n    before,digest=digest_archive(path)\n    header={\'version\':1,\'name\':path.name,\'size\':before[2],\'sha256\':digest,\'nonce\':secrets.token_hex(16)}\n    receipt=exchange(task,c,header,path)\n    if receipt=={**header,\'status\':\'conflict\'} and identity(path)==before:raise Conflict(\'同名归档内容不同，自动重试已暂停\')\n    if receipt!={**header,\'status\':\'archived\'} or identity(path)!=before:raise ValueError(\'归档回执不匹配或源文件发生变化\')\n    return before\n\n\ndef tick(name,force=False):\n    init();task=taskpath(name);safe_dir(task)\n    with open(task/\'run.lock\',\'a\') as lock:\n        os.chmod(task/\'run.lock\',0o600)\n        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n        except BlockingIOError:\n            if force:raise ValueError(\'此任务正在运行\')\n            return\n        c=read_json(task/\'config.json\')\n        if read_json(task/\'trusted.json\').get(\'generation\')!=c[\'generation\']:raise ValueError(\'未验证远端，请选2\')\n        state=read_json(task/\'state.json\') if (task/\'state.json\').exists() else {\'files\':{}}\n        if c.get(\'mode\')!=\'transfer\':raise ValueError(\'独立投递任务只支持传送模式\')\n        now=time.time()\n        paths=sorted(P(c[\'local\']).glob(\'*.tar.gz\'),key=lambda p:p.name)\n        changed=False;failed=False\n        for path in paths:\n            if path.is_symlink() or not path.is_file():continue\n            record=state[\'files\'].get(path.name,{})\n            # 成功名称为不可重传的历史身份；源文件即使变化也不得覆盖B端。\n            if record.get(\'done\') or record.get(\'conflict\'):continue\n            sig=identity(path)\n            if record.get(\'identity\')!=sig:\n                record={\'identity\':sig,\'seen\':now,\'attempts\':0};state[\'files\'][path.name]=record;changed=True\n            if now-record[\'seen\']<10:continue\n            if not force and now<record.get(\'next\',0):continue\n            try:\n                emit(task,\'开始上传 \'+path.name)\n                record[\'done\']=send(task,c,path);record[\'finished\']=time.time();record.pop(\'next\',None)\n                emit(task,\'上传并独立读回核验成功 \'+path.name)\n                if force:print(\'上传并核验成功：\'+path.name)\n            except Conflict:\n                record[\'conflict\']=True;record[\'conflict_at\']=time.time();record.pop(\'next\',None)\n                emit(task,\'同名冲突，停止此文件自动重试 \'+path.name);failed=True\n                if force:print(\'同名冲突已暂停：\'+path.name,file=sys.stderr)\n            except Exception as ex:\n                record[\'attempts\']+=1;record[\'next\']=time.time()+(60 if record[\'attempts\']<3 else 3600)\n                emit(task,\'传送失败 \'+path.name+\' \'+type(ex).__name__);failed=True\n                if force:print(\'传送失败：\'+path.name+\'（\'+type(ex).__name__+\'，查看任务日志）\',file=sys.stderr)\n            changed=True;atomic(task/\'state.json\',state)\n        if changed:atomic(task/\'state.json\',state)\n        if failed:raise ValueError(\'部分备份传送失败；冲突文件已暂停，其余临时失败按退避规则重试\')\n        if force and not changed:print(\'暂无新的稳定备份可传送；传送任务不打包，首次发现需稳定10秒。\')\n\ndef color(text,code):\n    return \'\\033[\'+code+\'m\'+text+\'\\033[0m\' if sys.stdout.isatty() and os.environ.get(\'TERM\') not in (None,\'dumb\') else text\n\ndef summary():\n    print(\'备份传送\')\n    print(\'备注名      状态        本地传送检测目录           目标目录\')\n    records=rows()\n    if not records: print(color(\'暂无\',\'31\'))\n    for i,(task,c) in enumerate(records,1):\n        service,timer=unit_paths(task.name)\n        good=(task/\'trusted.json\').exists() and subprocess.run([\'systemctl\',\'is-active\',\'--quiet\',timer.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0\n        state=read_json(task/\'state.json\') if (task/\'state.json\').exists() else {\'files\':{}}\n        if any(v.get(\'conflict\') or (v.get(\'attempts\',0)>0 and not v.get(\'done\')) for v in state.get(\'files\',{}).values()):good=False\n        status=color(\'正常\',\'32\') if good else color(\'异常\',\'33\')\n        print(str(i)+\'. \'+task.name+\'    \'+status+\'    \'+c[\'local\']+\'    \'+c.get(\'target\',\'待测试确认\'))\n\ndef select(action):\n    init();records=rows();summary()\n    if not records:return\n    choice=prompt(\'选择任务编号（0返回）\',\'0\')\n    if choice==\'0\':return\n    if not choice.isascii() or not choice.isdecimal() or not 1<=int(choice)<=len(records):raise ValueError(\'编号无效\')\n    task,c=records[int(choice)-1]\n    if action==\'test\':\n        print(\'只读取本次探测回执，不读取或下载历史备份。\')\n        if not (task/\'known_hosts\').exists():trust(task,c)\n        probe(task,c);atomic(task/\'trusted.json\',{\'generation\':c[\'generation\']});schedule(task,c)\n        print(\'接收端响应正常，支持 SHA-256 独立读回核验；历史备份读取被禁止。调度已修复。\')\n    elif action==\'run\':tick(task.name,True)\n    elif action==\'delete\':\n        if prompt(\'删除 \'+task.name+\' 的调度和本地配置，保留本地/B端备份及外部私钥。输入 yes\')!=\'yes\':return\n        # 先停止本任务，不影响其他分类；保留锁 inode。\n        schedule(task,c,True)\n        with open(task/\'run.lock\',\'a\') as lock:\n            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n            allowed={\'config.json\',\'password.json\',\'known_hosts\',\'trusted.json\',\'state.json\'}\n            remove=[]\n            for p in task.iterdir():\n                st=p.lstat()\n                if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError(\'发现链接或非普通文件，未清理：\'+str(p))\n                if p.name in (\'run.lock\',\'log.lock\') or re.fullmatch(r\'transfer\\.log(?:\\.[1-3])?\',p.name):continue\n                if p.name not in allowed:raise ValueError(\'发现未知文件，未清理：\'+str(p))\n                remove.append(p)\n            for p in remove:p.unlink()\n        (ROOT/(task.name+\'.json\')).unlink()\n        print(\'任务已删除，备份及日志保留；B端账号未删除。\')\n\ndef repair():\n    init()\n    for task,c in rows():\n        if (task/\'trusted.json\').exists():schedule(task,c)\n\n\ndef sender_main(args):\n    if args==[\'summary\']:\n        if ROOT.exists(): summary()\n        else:\n            print(\'备份传送\');print(\'备注名      状态        本地传送检测目录           目标目录\');print(color(\'暂无\',\'31\'))\n        return\n    init()\n    if args==[\'create-transfer\']:create()\n    elif args==[\'test\']:select(\'test\')\n    elif args==[\'run\']:select(\'run\')\n    elif args==[\'delete\']:select(\'delete\')\n    elif args==[\'repair\']:repair()\n    elif len(args)==2 and args[0]==\'tick\':tick(args[1])\n    else:raise ValueError(\'无效传送命令\')\n'

def sender_command(args):
    if args==['create-transfer']: ensure_environment('sender')
    namespace={'__name__':'sbr_sender'}
    exec(compile(SENDER_SOURCE,'embedded-sender','exec'),namespace)
    namespace['sender_main'](args)


def sender_menu():
    sender_command(['repair'])
    while True:
        if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb'):print('\033[2J\033[H',end='')
        print('==================================')
        sender_command(['summary'])
        print('==================================')
        print('1. 添加传送任务（本地自动检测备份直接传送，不打包）')
        print('2. 测试远端读取')
        print('3. 立即执行任务')
        print('9. 删除任务（保留备份）')
        print('0. 返回')
        choice=input('请输入选项：')
        if choice=='0':return
        action={'1':'create-transfer','2':'test','3':'run','9':'delete'}.get(choice)
        try:
            if action:sender_command([action])
            else:print('无效选项')
        except (Cancel,EOFError,KeyboardInterrupt):print('已取消')
        except Exception as e:print('失败：'+str(e),file=sys.stderr)
        input('按回车继续...')


if __name__=='__main__':
    try:
        if sys.argv[1:2]==['--sender']: sender_command(sys.argv[2:])
        elif sys.argv[1:]==['--receive']: receive()
        elif sys.argv[1:] in ([],['--menu']): menu()
        elif sys.argv[1:]==['--upload']: upload()
        elif sys.argv[1:]==['--help']:
            print('bash ssh_backup_receiver.sh [--menu | --upload | --help]\nB 安装与添加账号需要 root；A 上传不需要 root。仅 --receive 供强制接收入口使用。')
        else: raise ValueError('无效参数，使用 --help')
    except (Cancel,EOFError,KeyboardInterrupt): sys.exit(1)
    except Exception as e:
        print('失败：'+str(e),file=sys.stderr); sys.exit(1)
PY
exec python3 -c "$SBR_CODE" "$@"
