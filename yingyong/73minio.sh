#!/usr/bin/env bash
# 从 /root/kejilion.sh 应用市场 88 导出；构建选项已改为源码编译。

# 从指定仓库真正编译；不下载已失效的官方二进制。
minio_build_source() (
    set -euo pipefail
    for tool in git docker tee mktemp; do
        command -v "$tool" >/dev/null || { echo "❌ 缺少依赖：$tool，请先安装环境"; exit 1; }
    done
    docker info >/dev/null
    mkdir -p "$build_dir"
    local work log go_version
    work=$(mktemp -d "$build_dir/minio-source.XXXXXX")
    log="$work/build.log"
    echo "源码及日志目录：$work"
    git clone --depth 1 "$my_github_url" "$work/source"
    cd "$work/source"
    go_version=$(sed -n 's/^toolchain go//p' go.mod)
    if [ -z "$go_version" ]; then
        go_version=$(sed -n 's/^go //p' go.mod)
    fi
    [[ "$go_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "❌ 无法识别 Go 版本"; exit 1; }
    echo "--- 源码提交：$(git rev-parse HEAD)，Go：$go_version ---"
    # 仓库 .dockerignore 排除了 .git；版本生成器需要它。
    printf '.git/objects/pack/*.keep\n' > Dockerfile.source.dockerignore
    cat > Dockerfile.source <<'DOCKERFILE'
ARG GO_VERSION=1.24.8
FROM golang:${GO_VERSION}-bookworm AS builder
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local GOMAXPROCS=2
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    ldflags=$(go run buildscripts/gen-ldflags.go) && \
    go build -p 2 -trimpath -tags kqueue -ldflags="$ldflags" -o /out/minio .

FROM debian:bookworm-slim
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /out/minio /usr/bin/minio
COPY dockerscripts/docker-entrypoint.sh /usr/bin/docker-entrypoint.sh
RUN chmod 755 /usr/bin/minio /usr/bin/docker-entrypoint.sh
EXPOSE 9000 9001
VOLUME ["/data"]
ENTRYPOINT ["/usr/bin/docker-entrypoint.sh"]
CMD ["minio"]
DOCKERFILE
    echo "--- 开始源码编译（并行数 2，首次下载依赖可能较慢）---"
    if ! DOCKER_BUILDKIT=1 docker build --progress=plain --build-arg "GO_VERSION=$go_version" \
        -f Dockerfile.source -t "$my_docker_img" . 2>&1 | tee "$log"; then
        echo "❌ 构建失败，日志：$log"
        exit 1
    fi
    docker run --rm --network none "$my_docker_img" --version
    echo "✅ 源码编译及镜像版本验证成功：$my_docker_img"
    echo "日志：$log"
    echo "未推送镜像，也未替换现有 MinIO 容器。"
)

APP_DIR=/home/docker/minio
NAME=minio
build_dir=/home/docker/build
install_dir="$APP_DIR"
my_github_url="https://github.com/zaixiangjian/minio.git"
my_docker_img="zaixiangjian/minio:latest"
TARGETARCH=amd64
RELEASE=latest
pause() { IFS= read -r -p "按回车继续..." _; }
confirm() {
    local answer
    IFS= read -r -p "确认请输入小写 yes：" answer || return 1
    [ "$answer" = yes ]
}
# 有任务时禁止重部署/卸载，避免凭证变化或 cron 悬空；检查失败也不放行。
minio_tasks_clear() {
    local status
    replication has-tasks
    status=$?
    case "$status" in
        1) return 0 ;;
        0) echo "请先在同步子菜单删除全部任务，以移除对应 cron，再重部署或卸载。" ;;
        *) echo "任务检查失败，拒绝重部署或卸载。" ;;
    esac
    return 1
}

# 自包含任务管理器；配置为 JSON，绝不 source/eval 凭证。
replication() {
    python3 - "$APP_DIR" "$(readlink -f "${BASH_SOURCE[0]}")" "$NAME" "$@" <<'PY'
import os, sys, json, re, stat, subprocess, pathlib, tempfile, fcntl, shlex, getpass, time, socket, signal
from urllib.parse import urlsplit, unquote
import ipaddress
# 终端 locale 或 PYTHONIOENCODING 可能为 latin-1；中文交互统一 UTF-8，不改系统环境。
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, 'reconfigure'):
        stream.reconfigure(encoding='utf-8', errors='replace')
# Python stdin 用于程序，交互始终从 /dev/tty 或独立的 fd 3 读取。
app, script, appname, action = sys.argv[1:5]
args=sys.argv[5:]
root=pathlib.Path(app)
marker='.replication-task'
lockpath='/run/lock/'+appname+'-replication.lock'
valid_name=lambda n: bool(re.fullmatch(r'[a-z][a-z0-9_-]{0,47}',n)) and n not in {'data','logs','tmp','temp','runtime','config','backup','compose','locks'}
def fail(message):
    print(message,file=sys.stderr); raise SystemExit(1)
def need(*names):
    import shutil
    for name in names:
        if not shutil.which(name): fail('缺少依赖：'+name+'；请自行安装，不自动安装。')
def ask(prompt,secret=False,default=None):
    try:
        if os.isatty(3):
            with os.fdopen(os.dup(3),'r') as stream:
                if secret: value=getpass.getpass(prompt,stream=open('/dev/tty','w'))
                else:
                    print(prompt,end='',flush=True); value=stream.readline()
        else:
            if not secret: print(prompt,end='',flush=True)
            # 每次直接读 fd，避免缓冲预读吞掉下一项。
            data=bytearray()
            while True:
                b=os.read(3,1)
                if not b: fail('输入结束，已取消。')
                if b==b'\n': break
                data+=b
            value=data.decode()
    except (EOFError,KeyboardInterrupt): fail('已取消。')
    value=value.rstrip('\r\n')
    return default if value=='' and default is not None else value
def yes(prompt):
    return ask(prompt+'（输入精确小写 yes）：')=='yes'
def port(v):
    if not re.fullmatch(r'[0-9]{1,5}',str(v)) or not 1<=int(v)<=65535: fail('端口无效。')
    return int(v)
def https_url(value):
    # urlsplit strips some controls: reject before parsing, never normalize unsafe input.
    if not isinstance(value,str) or not value or any(ord(ch)<33 or ord(ch)==127 for ch in value) or '\\' in value:
        fail('S3 端点 URL 无效，须为不含空白的 HTTPS API 地址。')
    try:
        u=urlsplit(value)
        if u.scheme!='https' or not u.netloc or not u.hostname or u.username is not None or u.password is not None or '?' in value or '#' in value:
            fail('S3 端点仅允许 HTTPS，不允许用户信息、查询或片段。')
        if u.port is not None: port(u.port)
        if u.netloc.endswith(':'): fail('S3 端点端口无效。')
        host=u.hostname
        if ':' in host: ipaddress.IPv6Address(host)
        elif not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?',host) or '..' in host:
            fail('S3 端点主机名无效。')
        if re.search(r'%(?![0-9a-fA-F]{2})',u.path): fail('S3 端点路径编码无效。')
        decoded=unquote(u.path)
        if any(ord(ch)<32 or ord(ch)==127 for ch in decoded) or '\\' in decoded or any(p in ('.','..') for p in decoded.split('/')):
            fail('S3 端点路径无效。')
    except ValueError: fail('S3 端点 URL 或端口无效。')
    return value
def validate(c):
    if c.get('version')!=1 or c.get('mode') not in ('rsync','s3'): fail('任务配置无效。')
    connection=c.get('connection','ssh') if c['mode']=='s3' else 'ssh'
    if connection not in ('https','ssh'): fail('S3 连接方式无效。')
    if connection=='ssh':
        if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}',c['host']): fail('SSH 主机无效，只接受主机名/IPv4。')
        if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}',c['user']): fail('SSH 用户无效。')
        c['port']=port(c['port'])
        auth=c.get('auth','key')
        if auth not in ('key','password'): fail('SSH 认证方式无效。')
        if auth=='password':
            if not c.get('ssh_password') or any(ch in c['ssh_password'] for ch in '\r\n\x00'): fail('SSH 密码不能为空或含换行。')
        else:
            key=pathlib.Path(c['key'])
            if not key.is_absolute() or not re.fullmatch(r'/[a-zA-Z0-9_./-]+',str(key)) or key.is_symlink() or not key.is_file(): fail('密钥须为现有绝对路径普通文件（不含空格）。')
            if key.stat().st_uid!=os.getuid() or key.stat().st_mode&0o077: fail('SSH 私钥必须由当前用户持有，权限 600 或更严格。')
            if key.resolve().is_relative_to(root.resolve()): fail('SSH 私钥必须放在应用目录之外。')
    if c['mode']=='rsync':
        dest=c['destination']
        parts=pathlib.PurePosixPath(dest).parts
        if not re.fullmatch(r'/[a-zA-Z0-9_/-]+',dest) or len(parts)<4 or '..' in parts or '.' in parts or dest.endswith('/'): fail('目标必须为至少两级父目录下的专用绝对目录，例如 /home/docker/minio-mirror；禁止根目录和路径穿越。')
    else:
        if connection=='ssh':
            for k in ('source_port','remote_port','tunnel_port'): c[k]=port(c[k])
        else:
            c['destination_endpoint']=https_url(c['destination_endpoint'])
            if c.get('source_endpoint'):
                c['source_endpoint']=https_url(c['source_endpoint'])
            else:
                c['source_port']=port(c['source_port'])
        for k in ('source_bucket','destination_bucket'):
            if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]',c[k]) or '..' in c[k]: fail('桶名无效。')
        for k in ('source_access','source_secret','destination_access','destination_secret'):
            if not c.get(k) or any(ch in c[k] for ch in '\r\n\x00'): fail('凭证不能为空或含换行。')
    return c
def taskpath(name):
    if not valid_name(name): fail('名称须为小写字母开头、最多48位的小写字母/数字/_/-，禁止 data/logs 等保留名。')
    p=root/name
    if root.is_symlink() or p.is_symlink(): fail('拒绝符号链接任务目录。')
    return p
def load(name):
    p=taskpath(name)
    if not (p/marker).is_file() or (p/marker).is_symlink() or (p/marker).read_text()!=appname+' replication v1\n': fail('非本应用的任务目录，拒绝操作。')
    f=p/'task.json'
    if f.is_symlink() or not f.is_file() or f.stat().st_uid!=os.getuid() or f.stat().st_mode&0o077: fail('任务配置权限必须为 600 或更严格。')
    try: return validate(json.loads(f.read_text()))
    except (KeyError,ValueError,TypeError): fail('任务配置损坏。')
def tasks():
    if not root.is_dir(): return []
    return sorted(p.name for p in root.iterdir() if valid_name(p.name) and p.is_dir() and not p.is_symlink() and (p/marker).is_file() and not (p/marker).is_symlink() and (p/marker).read_text()==appname+' replication v1\n')
def cron_line(name):
    return '*/2 * * * * /bin/bash '+shlex.quote(script)+' --task '+name+' >/dev/null 2>&1'
def cron_read():
    need('crontab')
    p=subprocess.run(['crontab','-l'],capture_output=True,text=True,env={**os.environ,'LC_ALL':'C'})
    if p.returncode:
        if p.returncode==1 and re.fullmatch(r'no crontab for [^\n]+\n?',p.stderr.strip()): return ''
        fail('读取 crontab 失败，未修改任何任务。请检查 cron 权限/安装。')
    return p.stdout
def cron_set(old,name=None,add=None):
    cronfd=os.open('/run/lock/object-replication-cron.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    fcntl.flock(cronfd,fcntl.LOCK_EX)
    old=cron_read()
    display={'rustfs':'RustFS','seaweedfs':'SeaweedFS','minio':'minio'}[appname]
    header='# '+display+' 2分钟复制（勿删）'
    configs={}
    for task in tasks():
        c=load(task)
        configs[task]=c['mode']
    if add is False: configs.pop(name,None)
    owned_names=set(configs)
    if name is not None: owned_names.add(name)
    rows=old.splitlines()
    indices=[]
    legacy_display='MinIO' if appname=='minio' else display
    header_variants={header,'# '+display+' 2分钟传送（勿删）','# '+legacy_display+' 2分钟传送（勿删）'}
    header_variants.update('# '+legacy_display+' '+kind+' 2分钟传送'+suffix for kind in ('s3','rsync') for suffix in ('','（勿删）'))
    kept=[]
    for line in rows:
        owned=line in header_variants or any(line in (cron_line(task),cron_line(task)+' # '+appname+':replication:'+task) for task in owned_names)
        if owned: indices.append(len(kept))
        else: kept.append(line)
    block=([header]+[cron_line(task) for task in sorted(configs)]) if configs else []
    # 在原有托管块位置插入，不把任务散落到其他说明下。
    position=indices[0] if indices else len(kept)
    kept[position:position]=block
    new='\n'.join(kept)+ ('\n' if kept else '')
    if new!=old:
        p=subprocess.run(['crontab','-'],input=new,text=True,capture_output=True)
        if p.returncode: fail('写入 crontab 失败，配置未删除。')
    if cron_read()!=new: fail('crontab 回读不一致，请检查；不宣称成功。')
    os.close(cronfd)

def reconcile_cron():
    if not root.is_dir() or not tasks(): return
    fd=acquire()
    need('crontab')
    cron_set(None)

def task_rows(mode=None,connection=None):
    rows=[]
    for name in tasks():
        try:
            c=json.loads((taskpath(name)/'task.json').read_text())
            kind=c.get('mode'); method=c.get('connection','ssh') if kind=='s3' else 'ssh'
            if (mode is None or kind==mode) and (connection is None or method==connection): rows.append((name,kind,method))
        except (OSError,ValueError,TypeError,AttributeError):
            if mode is None: rows.append((name,'配置损坏','配置损坏'))
    # The same central order drives both display and numbered actions.
    return sorted(rows,key=lambda row: (0 if row[1]=='s3' and row[2]=='https' else 1 if row[1]=='s3' else 2,row[0]))

def listing(mode=None,connection=None):
    print('已配置同步任务（本机 cron 时区，每2分钟；每个任务独立非阻塞锁）：')
    rows=task_rows(mode,connection)
    number=0
    def section(label,group):
        nonlocal number
        print('------------------------')
        print(label)
        if not group: print('暂无')
        for name,kind,method in group:
            number+=1
            print(str(number)+'. '+name+' | '+method+' | */2 * * * * | '+str(root/name)+'/')
    if mode=='rsync':
        section('SSH/rsync 镜像传送',rows)
    else:
        for method,label in (('https','HTTPS S3 域名直连'),('ssh','SSH 隧道连接')):
            if connection is None or connection==method:
                section(label,[r for r in rows if r[1]=='s3' and r[2]==method])
        other=[r for r in rows if r[1]!='s3']
        if other: section('SSH/rsync 镜像传送',other)
    print('==================================')

def delete_number(mode,connection=None):
    # 在同一应用锁内生成与列表相同的排序并解析编号，避免选中其他类型任务。
    fd=acquire()
    rows=task_rows(mode,connection)
    if not rows: print('暂无可删除任务'); return
    value=ask('请输入要删除编号（0取消）：')
    if value=='0': print('已取消'); return
    if not re.fullmatch(r'[1-9][0-9]*',value) or int(value)>len(rows): fail('编号无效，未删除。')
    delete(rows[int(value)-1][0],locked=True)
def run_number(mode,connection=None):
    rows=task_rows(mode,connection)
    if not rows: print('暂无可运行任务'); return
    value=ask('请输入任务序号（0取消，回车全部执行）：')
    if value=='0': print('已取消'); return
    if value=='':
        selected=[name for name,kind,method in rows]
        failed=False
        for name in selected:
            print('正在执行：'+name)
            try: run(name)
            except SystemExit as e:
                if e.code!=0: failed=True; print('任务失败：'+name+'；继续下一任务。')
            except Exception as e:
                failed=True; print('任务失败：'+name+'（'+type(e).__name__+'）；继续下一任务。')
            finally:
                global active_lock,password_temp,password_file
                if active_lock is not None:
                    os.close(active_lock); active_lock=None
                if password_temp is not None:
                    password_temp.cleanup(); password_temp=None; password_file=None
        if failed: fail('全部任务已尝试执行，部分失败。')
        print('全部任务执行结束（正在运行的任务会跳过）。')
        return
    if not re.fullmatch(r'[1-9][0-9]*',value) or int(value)>len(rows): fail('序号无效，未执行。')
    name=rows[int(value)-1][0]
    run(name)

def acquire(name=None):
    path=lockpath if name is None else "/run/lock/"+appname+"-replication-"+name+".lock"
    fd=os.open(path,os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: os.close(fd); print('对应任务或配置操作正在运行，跳过本次操作。'); raise SystemExit(0)
    return fd
password_temp=None
password_file=None
def ssh_options(c):
    global password_temp,password_file
    base=['ssh','-F','/dev/null','-p',str(c['port']),'-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15','-o','ServerAliveInterval=30','-o','ServerAliveCountMax=3']
    if c.get('auth','key')=='key':
        return base+['-i',c['key'],'-o','BatchMode=yes','-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','IdentitiesOnly=yes']
    need('sshpass')
    if password_temp is None:
        import atexit
        password_temp=tempfile.TemporaryDirectory(prefix=appname+'-ssh-auth-',dir='/run')
        atexit.register(password_temp.cleanup)
        password_file=pathlib.Path(password_temp.name)/'password'
        fd=os.open(password_file,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as stream: stream.write(c['ssh_password']+'\n')
    return ['sshpass','-f',str(password_file)]+base+['-o','BatchMode=no','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','-o','PasswordAuthentication=yes','-o','KbdInteractiveAuthentication=no','-o','NumberOfPasswordPrompts=1']
active_lock=None
def checked(cmd,**kw):
    # 第三方错误输出可能含端点/凭证，故不转发；只报告状态。
    p=subprocess.run(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(active_lock,) if active_lock is not None else (),**kw)
    if p.returncode: fail('传送命令失败（退出码 '+str(p.returncode)+'），未宣称成功；检查依赖/信任/端点/权限。')
def run(name):
    global active_lock
    taskpath(name)
    guard=acquire()
    try:
        fd=acquire(name); active_lock=fd; c=load(name); need('flock')
    finally: os.close(guard)
    direct=c['mode']=='s3' and c.get('connection','ssh')=='https'
    if not direct:
        need('ssh')
        target=c['user']+'@'+c['host']; options=ssh_options(c)
    if c['mode']=='rsync':
        need('rsync')
        dest=pathlib.PurePosixPath(c['destination'])
        tests=['test -d '+shlex.quote(str(dest)), 'test "$(stat -c %a '+shlex.quote(str(dest))+')" = 700']
        tests += ['test ! -L '+shlex.quote(str(p)) for p in [dest,*dest.parents] if str(p)!='/']
        # 必须预先创建离线专用目录；禁止目标及其父目录为符号链接。
        checked(options+[target,' && '.join(tests)])
        exclusions=['--exclude=/runtime.env.replication','--exclude=**/.ssh/***','--exclude=**/id_*','--exclude=*.key','--exclude=*.pem','--exclude=*.p12','--exclude=*.pfx','--exclude=**/credentials*','--exclude=**/task.json','--exclude=**/'+marker,'--exclude=*.lock','--exclude=*.tmp','--exclude=/.replication-*/***']
        exclusions += ['--exclude=/'+n+'/***' for n in tasks()]
        exclusions += ['--exclude=**/.replication-*/***','--exclude=**/*.tmp/***','--exclude=**/.staging*/***','--exclude=**/tmp/***','--exclude=**/temp/***']
        # 避免任意文件名的 PEM/OpenSSH 私钥进入镜像；不读取/输出 runtime.env。
        for directory, dirs, files in os.walk(root,followlinks=False):
            if pathlib.Path(directory)==root: dirs[:]=[d for d in dirs if d not in tasks()]
            for filename in files:
                f=pathlib.Path(directory)/filename
                if f.is_symlink() or f.name=='runtime.env': continue
                try:
                    with f.open('rb') as stream: header=stream.read(4096)
                except OSError: fail('源文件不可读取，取消同步以防不完整镜像。')
                if b'PRIVATE KEY-----' in header:
                    exclusions.append('--exclude=/'+f.relative_to(root).as_posix())
        # 不解引用符号链接；排除部署凭证以外的复制凭证。runtime.env/compose.yaml 明确保留。
        checked(['rsync','-a','--safe-links','--delete','--protect-args','--chmod=Du=rwx,Dgo=,Fu=rw,Fgo=']+exclusions+['-e',shlex.join(options),'--',str(root)+'/',target+':'+c['destination']+'/'])
    else:
        need('rclone')
        # 只同步明确选择的一对桶；不对 S3 根路径 sync，也不删除其他桶。
        with tempfile.TemporaryDirectory(prefix=appname+'-replication-',dir='/run') as temp:
            temp=pathlib.Path(temp); os.chmod(temp,0o700)
            conf=temp/'rclone.conf'; control=temp/'ssh.sock'
            text=''
            source_endpoint=c.get('source_endpoint') if direct else None
            source_endpoint=source_endpoint or 'http://127.0.0.1:'+str(c['source_port'])
            destination_endpoint=c['destination_endpoint'] if direct else 'http://127.0.0.1:'+str(c['tunnel_port'])
            for section,prefix,endpoint in [('source','source',source_endpoint),('destination','destination',destination_endpoint)]:
                text+='['+section+']\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+c[prefix+'_access']+'\nsecret_access_key = '+c[prefix+'_secret']+'\nendpoint = '+endpoint+'\nregion = us-east-1\nforce_path_style = true\nsign_accept_encoding = false\n\n'
            conf.write_text(text); os.chmod(conf,0o600)
            def sync_bucket():
                base=['rclone','--config',str(conf)]
                src='source:'+c['source_bucket']; dst='destination:'+c['destination_bucket']
                checked(base+['lsf',src,'--max-depth','1'])
                checked(base+['mkdir',dst])
                checked(base+['sync',src,dst,'--delete-after','--create-empty-src-dirs'])
            if direct:
                sync_bucket()
            else:
                tunnel=subprocess.Popen(options+['-M','-S',str(control),'-N','-o','ExitOnForwardFailure=yes','-L','127.0.0.1:'+str(c['tunnel_port'])+':127.0.0.1:'+str(c['remote_port']),target],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(fd,))
                def stop(*unused):
                    if tunnel.poll() is None:
                        tunnel.terminate()
                        try: tunnel.wait(timeout=10)
                        except subprocess.TimeoutExpired: tunnel.kill(); tunnel.wait()
                previous={sig:signal.signal(sig,lambda s,f: sys.exit(128+s)) for sig in (signal.SIGTERM,signal.SIGINT)}
                try:
                    ready=False
                    for _ in range(100):
                        if tunnel.poll() is not None: break
                        p=subprocess.run(options+['-S',str(control),'-O','check',target],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,pass_fds=(fd,))
                        if p.returncode==0: ready=True; break
                        time.sleep(.1)
                    if not ready: fail('SSH 隧道建立失败，未执行对象删除。')
                    sync_bucket()
                finally:
                    stop()
                    for sig,handler in previous.items(): signal.signal(sig,handler)
    print('同步完成：'+name)
def tunnel_default():
    used=set()
    for app_root in (pathlib.Path('/home/docker/rustfs'),pathlib.Path('/home/docker/seaweedfs'),pathlib.Path('/home/docker/minio'),root):
        for config in app_root.glob('*/task.json'):
            if config.is_symlink() or not (config.parent/marker).is_file(): continue
            try:
                c=json.loads(config.read_text())
                if c.get('mode')=='s3' and c.get('connection','ssh')=='ssh': used.add(int(c['tunnel_port']))
            except (OSError,ValueError,KeyError,TypeError): pass
    for candidate in range(19101,65536):
        if candidate in used: continue
        with socket.socket() as sock:
            try: sock.bind(('127.0.0.1',candidate))
            except OSError: continue
        return str(candidate)
    fail('没有可用隧道端口。')

def check_tunnel_port(value):
    value=port(value)
    for app_root in (pathlib.Path('/home/docker/rustfs'),pathlib.Path('/home/docker/seaweedfs'),pathlib.Path('/home/docker/minio'),root):
        for config in app_root.glob('*/task.json'):
            if config.is_symlink() or not (config.parent/marker).is_file(): continue
            try:
                c=json.loads(config.read_text())
                if c.get('mode')=='s3' and c.get('connection','ssh')=='ssh' and int(c['tunnel_port'])==value: fail('隧道端口已被任务 '+config.parent.name+' 使用，请选择其他端口。')
            except (OSError,ValueError,KeyError,TypeError): pass
    with socket.socket() as sock:
        try: sock.bind(('127.0.0.1',value))
        except OSError: fail('隧道端口已占用，请选择其他端口。')
    return value

def local_api_default():
    fallback={'rustfs':'9100','seaweedfs':'9200','minio':'9000'}[appname]
    try:
        container_port='8333/tcp' if appname=='seaweedfs' else '9000/tcp'
        p=subprocess.run(['docker','port',appname,container_port],capture_output=True,text=True,timeout=10)
        if p.returncode==0 and p.stdout.strip():
            return str(port(p.stdout.splitlines()[0].rsplit(':',1)[-1]))
    except (OSError,subprocess.TimeoutExpired): pass
    return fallback

def verify_ssh(c):
    # 首次信任必须由用户通过独立渠道确认；不使用 StrictHostKeyChecking=no。
    need('ssh-keygen','ssh-keyscan')
    home=pathlib.Path.home()/'.ssh'; known=home/'known_hosts'
    if home.is_symlink() or known.is_symlink(): fail('拒绝符号链接 SSH 信任文件。')
    host=c['host'] if c['port']==22 else '['+c['host']+']:'+str(c['port'])
    found=subprocess.run(['ssh-keygen','-F',host,'-f',str(known)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if found.returncode!=0:
        scan=subprocess.run(['ssh-keyscan','-T','10','-p',str(c['port']),'-t','ed25519,ecdsa,rsa',c['host']],capture_output=True,text=True,timeout=20)
        lines=[l for l in scan.stdout.splitlines() if l.startswith(host+' ') and len(l.split())==3 and l.split()[1] in ('ssh-ed25519','ecdsa-sha2-nistp256','ecdsa-sha2-nistp384','ecdsa-sha2-nistp521','ssh-rsa')]
        if not lines: fail('无法获取远端支持的 SSH 主机密钥，未注册任务。')
        with tempfile.TemporaryDirectory(prefix=appname+'-host-check-',dir='/run') as tmp:
            f=pathlib.Path(tmp)/'key';f.write_text('\n'.join(lines)+'\n')
            fp=subprocess.run(['ssh-keygen','-lf',str(f)],capture_output=True,text=True,check=True)
            print('远端提供的主机指纹（尚未验证）：\n'+fp.stdout.strip())
            print('请在远端可信控制台自动列出所有主机公钥指纹，核对上面扫描到的指纹：')
            print('for key in /etc/ssh/ssh_host_*_key.pub; do [ -f "$key" ] && ssh-keygen -lf "$key"; done')
            if not yes('确认已独立核验指纹完全一致，保存信任'): fail('未确认主机指纹，未注册任务。')
            home.mkdir(mode=0o700,exist_ok=True)
            fd=os.open(known,os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW,0o600)
            with os.fdopen(fd,'w') as stream: stream.write('\n'.join(lines)+'\n')
    options=ssh_options(c)
    p=subprocess.run(options+[c['user']+'@'+c['host'],'true'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=35)
    if p.returncode: fail('SSH 认证或主机指纹校验失败，未注册任务；检查密码、密钥、SSH端口和 known_hosts。')
    print('SSH 主机信任与认证检查通过。')

def add(mode,connection='ssh'):
    if mode not in ('rsync','s3') or connection not in ('https','ssh'): fail('任务类型或连接方式无效。')
    direct=mode=='s3' and connection=='https'
    fd=acquire(); need('flock','crontab', 'rsync' if mode=='rsync' else 'rclone')
    if not direct: need('ssh')
    allocation_fd=os.open('/run/lock/object-replication-allocation.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    fcntl.flock(allocation_fd,fcntl.LOCK_EX)
    if not root.is_dir(): fail('应用目录不存在，请先安装。')
    old=cron_read()
    name=ask('任务名称（小写安全名称）：'); p=taskpath(name)
    if p.exists(): fail('同名目录已存在，拒绝覆盖。')
    c={'version':1,'mode':mode}
    if mode=='s3': c['connection']=connection
    if not direct:
        print('严格校验 SSH 主机密钥；首次连接会显示指纹供独立核验确认。')
        c.update(host=ask('远端 SSH 主机：'),user=ask('SSH 用户（回车默认 root）：',default='root'),port=ask('SSH 端口（回车默认 22）：',default='22'))
        auth=ask('SSH 认证：1. 密钥  2. 密码（回车 1）：',default='1')
        if auth=='1':
            c['auth']='key'; c['key']=ask('本机私钥绝对路径（600，应用目录外）：')
        elif auth=='2':
            need('sshpass')
            c['auth']='password'; c['ssh_password']=ask('SSH 密码（隐藏输入）：',True)
            print('密码认证需在本机任务配置中保存密码（权限600）；任务目录不会通过 rsync 传送。')
        else: fail('认证选项无效。')
    if mode=='rsync':
        c['destination']=ask('远端专用实例目录（例如 /home/docker/'+appname+'-mirror）：')
        print('警告：复制运行中的完整目录可能不一致，不是原子快照；远端实例必须离线。包含 runtime.env/compose.yaml 和应用凭证；目标目录须预先创建为 700 且父路径无符号链接，并预先配置远端凭证。排除同步任务、密钥、锁与临时文件。--delete 会删除目标中源端不存在的非排除文件。')
    else:
        source_default=local_api_default()
        if direct:
            print('请输入 S3 API HTTPS 地址，不是管理控制台；保留证书校验。源端回车使用当前本地容器 API。')
            c['source_endpoint']=ask('源 HTTPS S3 API URL（可选，回车本地 http://127.0.0.1:'+source_default+'）：')
            if not c['source_endpoint']: c['source_port']=int(source_default)
            c['destination_endpoint']=ask('目标 HTTPS S3 API URL（必填）：')
        else:
            default={'rustfs':'9100','seaweedfs':'9200','minio':'9000'}[appname]
            tunnel_port_default=tunnel_default()
            print('本地 API 默认值按当前容器映射读取；远端端口请按远端实际部署确认。')
            c.update(source_port=ask('本地回环 S3 API 端口（回车默认 '+source_default+'）：',default=source_default),remote_port=ask('远端回环 S3 API 端口（回车默认 '+default+'）：',default=default),tunnel_port=ask('本地隧道空闲端口（自动检测，回车默认 '+tunnel_port_default+'，可手动指定）：',default=tunnel_port_default))
            c['tunnel_port']=check_tunnel_port(c['tunnel_port'])
        c['source_bucket']=ask('源桶名：')
        c['destination_bucket']=ask('目标桶名（回车默认与源桶名一致）：',default=c['source_bucket'])
        for k,label in [('source_access','本地 Access Key'),('source_secret','本地 Secret Key'),('destination_access','目标 Access Key'),('destination_secret','目标 Secret Key')]: c[k]=ask(label+'（隐藏输入）：',True)
        print('范围：仅此源桶 → 此目标桶，目标桶内多余对象会删除；不删除其他桶。不复制完整 IAM、历史版本或服务器配置。HTTPS 直连保持证书校验；SSH 模式经回环隧道；异步同步并非实时/原子备份。')
    validate(c)
    if not direct:
        print('密码认证不代表自动信任远端；SSH 主机指纹必须核验。')
        print('请在远端服务器控制台执行：')
        print('for key in /etc/ssh/ssh_host_*_key.pub; do [ -f "$key" ] && ssh-keygen -lf "$key"; done')
        print('将结果与接下来显示的指纹核对；已有信任时直接检查登录。')
        ask('按回车继续核验 SSH 主机指纹与认证：')
        verify_ssh(c)
    if not yes('确认远端删除范围与权限（rsync 目标必须离线），注册每2分钟任务'): print('已取消'); return
    os.mkdir(p,0o700)
    try:
        for filename,content in [(marker,appname+' replication v1\n'),('task.json',json.dumps(c,ensure_ascii=False)+'\n')]:
            f=os.open(p/filename,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
            with os.fdopen(f,'w') as stream: stream.write(content)
        cron_set(old,name,True)
    except BaseException:
        # 写 cron 后回读失败时保留配置，避免产生无配置的已注册任务。
        print('注册未完全验证，配置保留供检查：'+str(p),file=sys.stderr); raise
    print('任务已注册并回读验证：'+name+'（每2分钟；本次不执行同步）')
    print('不保存传送日志；可在子菜单选择立即运行，查看现场成功或错误提示。')
def delete(name,locked=False):
    fd=None if locked else acquire()
    taskfd=acquire(name)
    load(name); old=cron_read()
    if not yes('仅删除任务配置及精确所属 cron，不删除远端数据：'+name): print('已取消'); return
    cron_set(old,name,False)
    p=taskpath(name)
    (p/'task.json').unlink(); (p/marker).unlink()
    try: p.rmdir()
    except OSError: print('目录有其他文件，保留目录，仅移除托管配置。')
    print('任务已删除；远端数据未操作。')
os.umask(0o077)
if action=='has-tasks': sys.exit(0 if tasks() else 1)
elif action=='list': listing(args[0] if args else None,args[1] if len(args)>1 else None)
elif action=='reconcile': reconcile_cron()
elif action=='run':
    if len(args)!=1: fail('用法：--task 名称')
    run(args[0])
elif action=='add': add(args[0],args[1]) if len(args)>1 else add(args[0])
elif action=='delete': delete(args[0])
elif action=='delete-number': delete_number(args[0],args[1]) if len(args)>1 else delete_number(args[0])
elif action=='run-number': run_number(args[0],args[1]) if len(args)>1 else run_number(args[0])
else: fail('未知任务动作。')
PY
}
find_replication_tasks() { replication has-tasks; }
install_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        echo "rclone 已安装：$(command -v rclone)"
        rclone version
        return 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y --no-install-recommends rclone || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y rclone || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y rclone || return 1
    elif command -v apk >/dev/null 2>&1; then
        apk add rclone || return 1
    else
        echo "未找到支持的包管理器，请手动安装 rclone。"; return 1
    fi
    command -v rclone >/dev/null && rclone version || return 1
    echo "rclone 安装完成（系统工具，三个脚本共用）。"
}
uninstall_rclone() {
    echo "将卸载系统 rclone，MinIO/RustFS/SeaweedFS 的 S3 同步任务会无法执行。"
    echo "不删除存储数据、同步任务配置和 rclone 用户配置。"
    confirm || { echo "已取消"; return 0; }
    if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' rclone 2>/dev/null | grep -qx 'install ok installed'; then
        apt-get remove -y rclone || return 1
    elif command -v rpm >/dev/null 2>&1 && rpm -q rclone >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then dnf remove -y rclone || return 1
        else yum remove -y rclone || return 1; fi
    elif command -v apk >/dev/null 2>&1 && apk info -e rclone >/dev/null 2>&1; then
        apk del rclone || return 1
    elif command -v rclone >/dev/null 2>&1; then
        echo "rclone 非本脚本支持的系统包安装，不自动删除：$(command -v rclone)"; return 1
    else
        echo "rclone 未安装。"; return 0
    fi
    if command -v rclone >/dev/null 2>&1; then
        echo "系统包已移除，但 PATH 中仍有其他 rclone：$(command -v rclone)"; return 1
    fi
    echo "rclone 已卸载，任务与数据保留。"
}

s3_connection_menu() {
    local choice
    while true; do
        [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
        echo "=================================="
        echo "S3 API 异步同步（单桶映射）"
        replication list s3 || return 1
        echo "1. HTTPS S3 域名直连"
        echo "2. SSH 隧道连接"
        echo "8. 安装 rclone"
        echo "9. 卸载 rclone（需 yes 确认）"
        echo "0. 返回"
        IFS= read -r -p "请选择连接方式：" choice || return 0
        case "$choice" in
            1|2)
                if ! command -v rclone >/dev/null 2>&1; then
                    echo "未安装 rclone，请使用本菜单 8 号安装后再进入。"
                    pause || return 0
                    continue
                fi
                if [ "$choice" = 1 ]; then replication_menu s3 https
                else replication_menu s3 ssh; fi
                ;;
            8) install_rclone; pause || return 0 ;;
            9) uninstall_rclone; pause || return 0 ;;
            0) return 0 ;;
            *) echo "无效选项"; pause || return 0 ;;
        esac
    done
}

replication_menu() {
    local mode="$1" connection="${2:-}" choice task
    if [ "$mode" = s3 ] && [ -z "$connection" ]; then s3_connection_menu; return $?; fi
    while true; do
        [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
        echo "=================================="
        if [ "$mode" = rsync ]; then echo "SSH/rsync 镜像传送"; else echo "S3 API 异步同步（单桶映射）"; fi
        replication list "$mode" ${connection:+"$connection"} || return 1
        echo "1. 添加任务（每2分钟）"
        echo "2. 删除任务（仅配置/cron）"
        echo "3. 列出任务"
        echo "4. 立即运行已有任务"
        echo "0. 返回"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) replication add "$mode" ${connection:+"$connection"} 3<&0 ;;
            2) replication delete-number "$mode" ${connection:+"$connection"} 3<&0 ;;
            3) replication list "$mode" ${connection:+"$connection"} ;;
            4) replication run-number "$mode" ${connection:+"$connection"} 3<&0 ;;
            0) return 0 ;;
            *) echo "无效选项" ;;
        esac
        pause || return 0
    done
}
main() {
    command -v python3 >/dev/null || { echo "缺少依赖：python3"; return 1; }
    replication reconcile || echo "定时任务检查失败，请检查 cron 或任务配置；未宣称修复。"
while true; do
    [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
    echo "------------------------------------------------"
    echo "      MinIO 自编译管理脚本 (源码构建)"
    echo "------------------------------------------------"
    replication list
    echo "【源码与镜像管理】"
    echo "1. 安装环境并修复 Docker"
    echo "2. 一键克隆源码并编译 Docker 镜像"
    echo "3. 登录 Docker Hub"
    echo "4. 推送镜像到 Docker Hub"
    echo "------------------------------------------------"
    echo "【容器部署管理】"
    echo "11. 部署/启动 MinIO (/home/docker/minio)"
    echo "12. 更新镜像到最新版本"
    echo "13. SSH/rsync 镜像传送"
    echo "14. S3 API 异步同步"
    echo "19. 卸载 MinIO"
    echo "0. 返回主菜单"
    echo "------------------------------------------------"
    IFS= read -r -p "请输入操作编号: " ct_choice || break

    build_dir="/home/docker/build"
    install_dir="/home/docker/minio"
    my_github_url="https://github.com/zaixiangjian/minio.git"
    my_docker_img="zaixiangjian/minio:latest"
    TARGETARCH=amd64
    RELEASE=latest

    case $ct_choice in
        1)
            echo -e "\n--- [1/3] 修复系统基础环境 ---"
            sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock &>/dev/null
            sudo dpkg --configure -a
            sudo apt --fix-broken install -y

            echo -e "\n--- [2/3] 安装基础工具 ---"
            sudo apt update
            sudo apt install -y git curl ca-certificates build-essential make golang

            echo -e "\n--- [3/3] 检查并启动 Docker ---"
            if ! command -v docker &> /dev/null; then
                curl -fsSL https://get.docker.com | bash -
            fi
            sudo systemctl enable --now docker
            sudo chmod 666 /var/run/docker.sock
            echo -e "\n✅ 环境准备就绪！"
            read -n1 -r -p "回车继续..." key
            ;;

        2)
            minio_build_source
            if [ $? -ne 0 ]; then
                echo "❌ 源码构建未完成，请查看上方错误及日志"
            fi
            read -n1 -r -p "回车继续..." key
            ;;

        3)
            sudo docker login
            read -n1 -r -p "回车继续..." key
            ;;

        4)
            echo "正在推送镜像到 Docker Hub..."
            sudo docker push "$my_docker_img"
            read -n1 -r -p "回车继续..." key
            ;;

11)
            minio_tasks_clear || { pause; continue; }
            echo "--- 部署/启动 MinIO ---"
            
            # 1. 交互式获取账号
            read -p "请输入 MinIO 管理员账号 (直接回车将随机生成): " input_user
            if [ -z "$input_user" ]; then
                MINIO_ROOT_USER=$(tr -dc 'A-Z0-9' </dev/urandom | head -c 20)
                echo "-> 使用随机账号: $MINIO_ROOT_USER"
            else
                MINIO_ROOT_USER=$input_user
            fi

            # 2. 交互式获取密码
            read -p "请输入 MinIO 管理员密码 (直接回车将随机生成): " input_pass
            if [ -z "$input_pass" ]; then
                MINIO_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40)
                echo "-> 使用随机密码: $MINIO_ROOT_PASSWORD"
            else
                MINIO_ROOT_PASSWORD=$input_pass
            fi

            # 3. 执行部署
            sudo docker rm -f minio &>/dev/null
            mkdir -p "$install_dir/data"
            sudo chmod -R 777 "$install_dir/data"

            sudo docker run -d \
                --name minio \
                --restart unless-stopped \
                -p 9000:9000 \
                -p 9001:9001 \
                -v "$install_dir/data:/data" \
                -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
                -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
                "$my_docker_img" server /data --console-address ":9001"

            if [ $? -eq 0 ]; then
                loc_v4=$(hostname -I | awk '{print $1}')
                echo "------------------------------------------------"
                echo "✅ 启动成功！"
                echo "管理界面: http://$loc_v4:9001"
                echo "API 地址: http://$loc_v4:9000"
                echo "管理员账号: $MINIO_ROOT_USER"
                echo "管理员密码: $MINIO_ROOT_PASSWORD"
                echo "------------------------------------------------"
                echo "请务必妥善保存上述信息！"
            else
                echo "❌ 启动失败，请检查 Docker 日志"
            fi
            read -n1 -r -p "回车继续..." key
            ;;

        12)
            echo "--- 拉取最新镜像 ---"
            sudo docker pull "$my_docker_img"
            echo "✅ 镜像已更新"
            read -n1 -r -p "回车继续..." key
            ;;

        13) replication_menu rsync ;;
        14) replication_menu s3 ;;
        19)
            minio_tasks_clear || { pause; continue; }
            echo "--- 卸载 MinIO（删除容器与镜像，保留本地数据）---"

            confirm || { echo "已取消"; pause; continue; }

            # 删除容器（如果存在）
            if sudo docker ps -a --format '{{.Names}}' | grep -q '^minio$'; then
                sudo docker rm -f minio
                echo "✅ 容器已删除"
            else
                echo "ℹ️ 容器不存在"
            fi

            # 删除镜像（如果存在）
            if sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^$my_docker_img$"; then
                sudo docker rmi "$my_docker_img"
                echo "✅ 镜像已删除"
            else
                echo "ℹ️ 镜像不存在"
            fi

            echo "📦 本地数据目录已保留：$install_dir"
            read -n1 -r -p "回车继续..." key
            ;;

        0) echo "已退出"; break ;;
        *) echo "无效选择"; sleep 1 ;;
    esac
done

}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    case "${1:-}" in
        --task) [ "$#" -eq 2 ] && replication run "$2" ;;
        --list-safe) [ "$#" -eq 1 ] && replication list ;;
        "") main ;;
        *) echo "用法：$0 [--task 名称 | --list-safe]" >&2; exit 1 ;;
    esac
fi
