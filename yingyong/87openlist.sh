#!/usr/bin/env bash
# OpenList 管理脚本；官方镜像固定版本，自定义镜像使用 zaixiangjian/openlist。
# OpenList 官方及自定义镜像管理。
set -o pipefail
APP_DIR=/home/docker/openlist
NAME=openlist
IMAGE=openlistteam/openlist:v4.2.7
API_IMAGE=openlistteam/openlist_api_server:latest
API_NAME=openlist-api-server
API_APP_DIR=/home/docker/openlist-api-server
pause() { IFS= read -r -p "按回车继续..." _; }
confirm() {
    local answer
    IFS= read -r -p "确认请输入小写 yes：" answer || return 1
    [ "$answer" = yes ]
}
install_packages() {
    if command -v apt-get >/dev/null; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    else
        echo "当前自动安装仅支持 Debian/Ubuntu（apt-get），未修改系统。请先安装所需依赖：$*"
        return 1
    fi
}
prepare_base() {
    [[ $EUID -eq 0 ]] || { echo '请使用 root 运行。';return 1; }
    local -a packages=()
    command -v python3 >/dev/null || packages+=(python3)
    command -v clear >/dev/null || packages+=(ncurses-bin)
    command -v mountpoint >/dev/null && command -v findmnt >/dev/null && command -v flock >/dev/null || packages+=(util-linux)
    command -v ls >/dev/null && command -v mkdir >/dev/null && command -v chmod >/dev/null && command -v chown >/dev/null || packages+=(coreutils)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    if ((${#packages[@]}));then
        echo "正在准备基础环境：${packages[*]}"
        install_packages "${packages[@]}" || { echo '基础依赖安装失败，停止运行。';return 1; }
    fi
    python3 -c 'import sys,ssl,sqlite3,fcntl,termios; assert sys.version_info >= (3,9)' || { echo '需要完整 Python 3.9+（包含ssl、sqlite3等标准库）。';return 1; }
    mkdir -p /run/lock || return 1
}
require_docker() {
    if ! command -v docker >/dev/null;then
        echo '缺少 Docker，正在安装 docker.io。'
        install_packages docker.io || return 1
    fi
    if ! docker info >/dev/null 2>&1;then
        if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]];then
            systemctl enable --now docker || { echo 'Docker启动失败，停止操作。';return 1; }
        else
            echo 'Docker不可用且没有运行中的systemd；请先启动Docker，本次操作已停止。';return 1
        fi
    fi
    docker info >/dev/null 2>&1 || { echo 'Docker仍不可用，停止操作。';return 1; }
}
engine() {
    LC_ALL=C.UTF-8 PYTHONUTF8=1 python3 - "$1" "$NAME" "$APP_DIR" "$IMAGE" "${2:-}" "${3:-}" <<'PYENGINE'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

mode, name, root, image = sys.argv[1:5]
s3_bind, s3_host_port = sys.argv[5:7]
root = Path(root)
manager = root / '.openlist-manager'

def docker(*args):
    p = subprocess.run(['docker', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       encoding='utf-8', errors='replace')
    if p.returncode:
        # Docker diagnostics may include environment values. Do not echo them.
        raise RuntimeError('Docker 操作失败：' + args[0])
    return p.stdout.strip()

def inspect(ref):
    return json.loads(docker('inspect', ref))[0]

def safe_paths():
    for p in (root, root / 'data', manager):
        if any(q.is_symlink() for q in [p, *p.parents]):
            raise RuntimeError('拒绝符号链接应用/数据/管理目录')
    if not root.is_dir() or not (root / 'data').is_dir():
        raise RuntimeError('应用数据目录不存在')
    if manager.exists() and (manager.stat().st_uid != 0 or manager.stat().st_mode & 0o077):
        raise RuntimeError('管理备份目录必须由 root 所有且权限为 0700')

def endpoints(x):
    out = []
    for b in (x['NetworkSettings'].get('Ports', {}).get('5244/tcp') or []):
        ip, port = b['HostIp'], b['HostPort']
        if ip in ('', '0.0.0.0'):
            ip = '127.0.0.1'
        elif ip == '::':
            ip = '::1'
        if ':' in ip:
            ip = '[' + ip + ']'
        out.append('http://' + ip + ':' + port + '/')
    return out

def ready(ref):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(30):
        x = inspect(ref)
        if not x['State']['Running']:
            raise RuntimeError('容器未运行，无法验证 HTTP 服务')
        for url in endpoints(x):
            try:
                with opener.open(url, timeout=2) as r:
                    if r.status == 200 and r.read(1):
                        return
            except (OSError, ValueError):
                pass
        time.sleep(1)
    raise RuntimeError('HTTP 启动验证超时；请在本机检查容器日志，不代表密码错误')

def addresses():
    x = inspect(name)
    bindings = x['NetworkSettings'].get('Ports', {}).get('5244/tcp') or []
    if not bindings:
        print('未检测到 5244/tcp 映射；无法给出网页访问地址。')
    for b in bindings:
        ip, port = b['HostIp'], b['HostPort']
        if ip in ('127.0.0.1', '::1'):
            host = '[' + ip + ']' if ':' in ip else ip
            print('仅本机访问：http://' + host + ':' + port)
            print('远程访问需 SSH 隧道或反向代理。')
        elif ip in ('', '0.0.0.0', '::'):
            print('本机验证地址：http://' + ('[::1]' if ip == '::' else '127.0.0.1') + ':' + port)
            print('监听所有接口；远程使用 http://服务器公网IP:' + port + '（IPv6 地址加方括号），并确认防火墙。')
        else:
            host = '[' + ip + ']' if ':' in ip else ip
            print('绑定地址：http://' + host + ':' + port + '（是否可公网访问取决于路由和防火墙）')

def validate(x, image_id=None):
    hc, cfg, mounts = x['HostConfig'], x['Config'], x['Mounts']
    data=[m for m in mounts if m.get('Destination')=='/opt/openlist/data']
    extra=[m for m in mounts if m.get('Destination')!='/opt/openlist/data']
    if len(data)!=1 or data[0].get('Source')!=str(root/'data') or data[0].get('Type')!='bind' or not data[0].get('RW') or data[0].get('Propagation','rprivate')!='rprivate':
        raise RuntimeError('挂载与本管理器不符，拒绝自动重建')
    if len(extra)>1 or any(m.get('Type')!='bind' or m.get('Source')!='/home/docker/挂载目录' or m.get('Destination')!='/mnt/ftps' or m.get('Propagation')!='rslave' or not m.get('RW') for m in extra):raise RuntimeError('不支持额外挂载')
    if not (cfg['Image'].startswith(('openlistteam/openlist:', 'zaixiangjian/openlist:', 'zaixiangjian/openliat:')) or cfg['Image'] in (image_id, x['Image'])) or cfg.get('User') != '1000:1000':
        raise RuntimeError('非受支持的镜像/用户，拒绝自动重建')
    # Fail closed: every nonempty HostConfig field must be represented or an explicit Docker default.
    preserved = {'Binds', 'PortBindings', 'RestartPolicy', 'NetworkMode', 'LogConfig'}
    defaults = {'ContainerIDFile': '', 'AutoRemove': False, 'VolumeDriver': '', 'VolumesFrom': None,
                'CgroupnsMode': 'private', 'IpcMode': 'private',
                'ShmSize': 67108864, 'Runtime': 'runc', 'Isolation': '',
                'MaskedPaths': ['/proc/asound', '/proc/acpi', '/proc/interrupts', '/proc/kcore',
                                '/proc/keys', '/proc/latency_stats', '/proc/timer_list', '/proc/timer_stats',
                                '/proc/sched_debug', '/proc/scsi', '/sys/firmware', '/sys/devices/virtual/powercap'],
                'ReadonlyPaths': ['/proc/bus', '/proc/fs', '/proc/irq', '/proc/sys', '/proc/sysrq-trigger']}
    for k, v in hc.items():
        if k == 'ConsoleSize':
            # Docker 记录创建终端的行列数；非 TTY 服务不受其影响，不是自定义运行限制。
            if not isinstance(v, list) or len(v) != 2 or any(type(n) is not int or n < 0 for n in v):
                raise RuntimeError('无效 ConsoleSize')
            continue
        if k in preserved:
            continue
        if k in defaults:
            same = set(v) == set(defaults[k]) if k in ('MaskedPaths', 'ReadonlyPaths') and isinstance(v, list) else v == defaults[k]
            if not same:
                raise RuntimeError('不支持自定义 HostConfig：' + k)
        elif v not in (None, False, 0, '', [], {}):
            raise RuntimeError('不支持额外 HostConfig：' + k)
    allowed_binds={str(root/'data')+':/opt/openlist/data',str(root/'data')+':/opt/openlist/data:rw','/home/docker/挂载目录:/mnt/ftps:rw,rslave','/home/docker/挂载目录:/mnt/ftps:rslave'}
    if hc.get('NetworkMode') != 'bridge' or len(hc.get('Binds') or [])!=len(mounts) or any(b not in allowed_binds for b in hc.get('Binds') or []):
        raise RuntimeError('不支持自定义网络/挂载选项')
    if hc.get('LogConfig', {}).get('Type') not in ('json-file', 'local'):
        raise RuntimeError('不支持此日志驱动')
    for k in ('Tty', 'OpenStdin', 'StdinOnce', 'Healthcheck', 'Shell', 'OnBuild', 'NetworkDisabled', 'MacAddress'):
        if cfg.get(k):
            raise RuntimeError('不支持额外 Config：' + k)
    if len(cfg.get('Entrypoint') or []) > 1:
        raise RuntimeError('不支持多参数 entrypoint')
    for e in cfg.get('Env') or []:
        if '\n' in e or '\r' in e or '=' not in e:
            raise RuntimeError('不支持多行/无等号环境变量')
    networks = x['NetworkSettings'].get('Networks', {})
    if set(networks) != {'bridge'}:
        raise RuntimeError('不支持额外网络')
    n = networks['bridge']
    for k in ('Aliases', 'Links', 'IPAMConfig', 'DriverOpts'):
        if n.get(k):
            raise RuntimeError('不支持自定义网络：' + k)
    if not hc.get('PortBindings', {}).get('5244/tcp'):
        raise RuntimeError('缺少 5244/tcp 映射，无法进行 HTTP 启动验证')
    if x['State'].get('Paused') or x['State'].get('Restarting'):
        raise RuntimeError('暂停/重启中的实例不能更新')

def secure_json(p, obj):
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False)

def managed_backups():
    # Legacy records grant ownership by exact container ID, never by a name glob alone.
    paths = list(root.glob('openlist.before-update.*/container.json'))
    if manager.exists():
        paths += list(manager.glob('update.*/container.json'))
    found = []
    for p in paths:
        if p.is_symlink() or p.parent.is_symlink() or p.parent.stat().st_uid != 0 or p.parent.stat().st_mode & 0o077 or p.stat().st_uid != 0 or p.stat().st_mode & 0o077:
            raise RuntimeError('存在不安全的旧配置备份，需人工处理')
        rec = json.loads(p.read_text(encoding='utf-8'))
        ident = rec.get('Id', '')
        if not ident or not all(c in '0123456789abcdef' for c in ident) or len(ident) != 64:
            raise RuntimeError('旧配置备份的容器 ID 无效')
        found.append((p.parent, ident))
    return found

def owned_old(x, ident):
    return (x['Id'] == ident and x.get('Name', '').startswith('/' + name + '-before-update-')
            and not x['State']['Running'] and len(x['Mounts']) == 1
            and x['Mounts'][0].get('Source') == str(root / 'data')
            and x['Mounts'][0].get('Destination') == '/opt/openlist/data')

def existing_containers():
    ids = docker('ps', '-aq').split()
    return [inspect(i) for i in ids]

def ftps_anchor_ready():
    anchor=Path('/home/docker/挂载目录')
    if any(p.is_symlink() for p in (anchor,*anchor.parents)):return False
    try:
        p=subprocess.run(['mountpoint','-q',str(anchor)],capture_output=True,timeout=3)
        if p.returncode:return False
        p=subprocess.run(['findmnt','-n','-o','PROPAGATION','--mountpoint',str(anchor)],capture_output=True,text=True,timeout=3)
        return p.returncode==0 and 'shared' in p.stdout.strip().split(',')
    except (OSError,subprocess.TimeoutExpired):return False

def update():
    safe_paths()
    x = inspect(name)
    validate(x)
    if any(m.get('Destination')=='/mnt/ftps' for m in x['Mounts']):
        if not ftps_anchor_ready():raise RuntimeError('FTPS父挂载点未就绪或不是shared，拒绝更新')
    docker('pull', image)
    target = json.loads(docker('image', 'inspect', image))[0]['Id']
    if target == x['Image']:
        print('实际镜像已一致，无需重建。')
        return
    hc, cfg = x['HostConfig'], x['Config']
    # 环境只保存在临时内存文件系统中，结束即清理；不生成恢复材料。
    with tempfile.TemporaryDirectory(prefix='openlist-update-', dir='/run') as tmp:
        env = Path(tmp) / 'runtime.env'
        fd = os.open(env, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write('\n'.join(cfg.get('Env') or []) + '\n')
        rp = hc['RestartPolicy']
        restart = rp['Name'] or 'no'
        if restart == 'on-failure' and rp.get('MaximumRetryCount'):
            restart += ':' + str(rp['MaximumRetryCount'])
        candidate = name + '-update-' + Path(tmp).name.rsplit('-', 1)[-1]
        args = ['create', '--name', candidate, '--restart', restart, '--network', 'bridge',
                '--user', cfg['User'], '--env-file', str(env),
                '-v', str(root / 'data') + ':/opt/openlist/data']
        if any(m.get('Destination')=='/mnt/ftps' for m in x['Mounts']):args+=['-v','/home/docker/挂载目录:/mnt/ftps:rw,rslave']
        for port, binds in (hc.get('PortBindings') or {}).items():
            for bind in binds or []:
                ip = bind['HostIp']
                ip = '[' + ip + ']' if ':' in ip else ip
                args += ['-p', (ip + ':' if ip else '') + bind['HostPort'] + ':' + port]
        for k, v in (cfg.get('Labels') or {}).items():
            args += ['--label', k + '=' + v]
        lc = hc.get('LogConfig') or {}
        args += ['--log-driver', lc['Type']]
        for k, v in lc.get('Config', {}).items():
            args += ['--log-opt', k + '=' + v]
        # 允许新镜像更新 WorkingDir、Entrypoint、Cmd 等默认值。
        args += [target]
        new_id = docker(*args)
        removed = False
        try:
            y = inspect(new_id)
            if y['Image'] != target:
                raise RuntimeError('新容器镜像校验失败')
            docker('rm', '-f', x['Id'])
            removed = True
            docker('rename', new_id, name)
            if x['State']['Running']:
                docker('start', new_id)
                ready(new_id)
            print('直接更新完成，数据目录、端口与环境变量保留；未创建备份或恢复材料。')
            if not x['State']['Running']:
                print('原实例已停止，新实例保持停止。')
        except BaseException:
            if not removed:
                docker('rm', '-f', new_id)
                print('替换前失败，原容器保持不变。')
            else:
                print('替换后启动未验证通过；数据未删除，请检查新容器：' + new_id)
                print('此流程不备份、不自动回滚。')
            raise

def s3_switch():
    import fcntl, socket, uuid
    with open('/run/lock/openlist-manager.lock','a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('另一项 OpenList 操作正在进行')
        safe_paths()
        x=inspect(name); validate(x)
        if not x['State']['Running']: raise RuntimeError('请先启动 OpenList')
        path=root/'data'/'config.json'
        if path.is_symlink() or not path.is_file(): raise RuntimeError('config.json 不安全或不存在')
        original=path.read_bytes(); cfg=json.loads(original); section=cfg.get('s3',{})
        if type(section.get('enable')) is not bool: raise RuntimeError('s3.enable 配置无效')
        mounting=mode in ('mount-rebuild','mount-detach')
        detaching=mode=='mount-detach'
        if detaching and not any(m.get('Destination')=='/mnt/ftps' for m in x['Mounts']):
            print('容器未映射FTPS目录，无需卸载。');return
        enabled=section['enable'] if mounting else mode=='s3-enable'
        if section['enable']==enabled and not mounting: print('S3 已是所选状态'); return
        port=section.get('port',5246)
        if type(port) is not int or not 1<=port<=65535 or port==5244: raise RuntimeError('需要独立有效 S3 端口')
        hc,runtime=x['HostConfig'],x['Config']
        if any(e.split('=',1)[0].upper().endswith(('S3_ENABLE','S3_PORT')) for e in runtime.get('Env',[])): raise RuntimeError('存在S3环境变量覆盖，拒绝修改')
        if enabled and not mounting and (s3_bind not in ('127.0.0.1','0.0.0.0') or not s3_host_port.isdigit() or not 1<=int(s3_host_port)<=65535): raise RuntimeError('绑定地址/端口无效')
        ports=dict(hc.get('PortBindings') or {})
        if not mounting:
            ports.pop(str(port)+'/tcp',None)
            if enabled: ports[str(port)+'/tcp']=[{'HostIp':s3_bind,'HostPort':s3_host_port}]
        section['enable']=enabled; cfg['s3']=section; info=path.stat()
        def write(content):
            fd,tmp=tempfile.mkstemp(prefix='.s3-config.',dir=path.parent)
            try:
                with os.fdopen(fd,'wb') as f:
                    os.fchown(f.fileno(),info.st_uid,info.st_gid);os.fchmod(f.fileno(),info.st_mode&0o777)
                    f.write(content);f.flush();os.fsync(f.fileno())
                os.replace(tmp,path)
            finally:
                if os.path.exists(tmp):os.unlink(tmp)
        old=name+'-s3-before-'+uuid.uuid4().hex[:12]
        candidate=name+'-s3-new-'+uuid.uuid4().hex[:12]
        rp=hc.get('RestartPolicy') or {}; policy=rp.get('Name') or 'no'
        if policy=='on-failure' and rp.get('MaximumRetryCount'):policy+=':'+str(rp['MaximumRetryCount'])
        args=['create','--name',candidate,'--network','bridge','--restart',policy,'--user',runtime['User'],'-v',str(root/'data')+':/opt/openlist/data']
        if not detaching and (mounting or any(m.get('Destination')=='/mnt/ftps' for m in x['Mounts'])):
            anchor=Path('/home/docker/挂载目录')
            if not ftps_anchor_ready():raise RuntimeError('FTPS父挂载点未就绪或不是shared')
            args+=['-v',str(anchor)+':/mnt/ftps:rw,rslave']
        for e in runtime.get('Env') or []:args+=['-e',e]
        for k,v in (runtime.get('Labels') or {}).items():args+=['--label',k+'='+v]
        for k,flag in [('Hostname','--hostname'),('WorkingDir','--workdir')]:
            if runtime.get(k):args+=[flag,runtime[k]]
        log=hc['LogConfig'];args+=['--log-driver',log['Type']]
        for k,v in (log.get('Config') or {}).items():args+=['--log-opt',k+'='+v]
        for dest,bindings in ports.items():
            for b in bindings or []:
                ip=b.get('HostIp','');ip='['+ip+']' if ':' in ip else ip
                args+=['-p',(ip+':' if ip else '')+b['HostPort']+':'+dest]
        ep=runtime.get('Entrypoint') or []
        if ep:args+=['--entrypoint',ep[0]]
        args+=[x['Image']]+(runtime.get('Cmd') or [])
        ident=docker(*args);stopped=renamed=False
        try:
            docker('stop',name);stopped=True
            if path.read_bytes()!=original:raise RuntimeError('配置已变化，未覆盖')
            docker('rename',name,old);renamed=True
            write((json.dumps(cfg,ensure_ascii=False,indent=2)+'\n').encode())
            docker('rename',ident,name);docker('start',name);ready(name)
            if json.loads(path.read_text()).get('s3',{}).get('enable') is not enabled:raise RuntimeError('开关读回校验失败')
            if mounting:
                present=any(m.get('Destination')=='/mnt/ftps' and m.get('Propagation')=='rslave' for m in inspect(name)['Mounts'])
                if present==detaching:raise RuntimeError('FTPS映射读回失败')
            if enabled and not mounting:
                if not inspect(name)['HostConfig'].get('PortBindings',{}).get(str(port)+'/tcp'):raise RuntimeError('端口映射校验失败')
                for attempt in range(20):
                    try:
                        with socket.create_connection(('127.0.0.1' if s3_bind=='0.0.0.0' else s3_bind,int(s3_host_port)),timeout=1):break
                    except OSError:
                        if attempt==19:raise RuntimeError('S3端口验证超时')
                        time.sleep(1)
        except BaseException:
            docker('rm','-f',ident)
            if renamed:write(original);docker('rename',old,name)
            if stopped:docker('start',name);ready(name)
            raise
        docker('rm',old)
        if detaching:print('容器FTPS映射已移除并验证，旧容器已清理；宿主机挂载、配置、缓存及远程文件保留。')
        elif mounting:print('FTPS映射已验证；本机存储根目录请填写 /mnt/ftps/唯一名称。旧容器已清理。')
        else:
            print('S3 已'+('启用' if enabled else '关闭')+'；旧容器已清理，未复制数据。')
            if enabled:print('S3端口：'+s3_bind+':'+s3_host_port+'；未验证账号认证及网盘读写。')

def uninstall():
    safe_paths()
    records = dict((ident, p) for p, ident in managed_backups())
    containers = existing_containers()
    remove = []
    for x in containers:
        uses = any(m.get('Source') and (m['Source'] == str(root) or m['Source'].startswith(str(root) + '/')) for m in x.get('Mounts', []))
        is_current = x.get('Name') == '/' + name
        owned = x['Id'] in records and owned_old(x, x['Id'])
        # 兼容最早版本留下但配置记录已不存在的停止更新容器；不匹配任意容器。
        legacy_name = x.get('Name', '')
        if (legacy_name.startswith('/' + name + '-before-update-')
                and not x['State']['Running'] and len(x.get('Mounts', [])) == 1
                and x['Mounts'][0].get('Type') == 'bind'
                and x['Mounts'][0].get('Source') == str(root / 'data')
                and x['Mounts'][0].get('Destination') == '/opt/openlist/data'
                and x.get('Config', {}).get('Image', '').startswith(('openlistteam/openlist:', 'zaixiangjian/openlist:', 'zaixiangjian/openliat:'))):
            owned = True
        if is_current:
            # 卸载仅核实应用挂载归属，不套用用于重建的镜像标签/用户/运行参数限制。
            if not any(m.get('Type') == 'bind' and m.get('Source') == str(root / 'data')
                       and m.get('Destination') == '/opt/openlist/data' for m in x.get('Mounts', [])):
                raise RuntimeError('同名容器没有本应用的数据挂载，拒绝误删')
        if uses and not (is_current or owned):
            raise RuntimeError('其他容器使用应用目录，拒绝卸载；请先人工处理（未删除任何容器/数据）')
        if is_current or owned:
            remove.append(x['Id'])
    for ident in remove:
        docker('rm', '-f', ident)
    # Read back before deleting mounted data, including races/newly created containers.
    for x in existing_containers():
        if any(m.get('Source') and (m['Source'] == str(root) or m['Source'].startswith(str(root) + '/')) for m in x.get('Mounts', [])):
            raise RuntimeError('仍有容器引用应用目录，保留数据')
    shutil.rmtree(root)
    print('已卸载当前实例及配置备份验证归属的停止回滚容器；已删除应用目录。')

try:
    if mode == 'ready':
        ready(name)
    elif mode == 'addresses':
        addresses()
    elif mode == 'update':
        update()
    elif mode in ('s3-enable','s3-disable','mount-rebuild','mount-detach'):
        s3_switch()
    elif mode == 'uninstall':
        uninstall()
    else:
        raise RuntimeError('未知操作')
except Exception as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PYENGINE
}
ready() { engine ready; }
addresses() { engine addresses; }
show_initial_password() {
    # 仅读取初始化日志；不重置、不猜测密码，不输出整份日志。
    python3 - "$NAME" <<'PYPASSWORD'
import subprocess,re,sys,time
for _ in range(10):
    p=subprocess.run(['docker','logs','--tail','200',sys.argv[1]],capture_output=True,encoding="utf-8",errors="replace")
    text=re.sub(r'\x1b\[[0-9;]*m','',p.stdout+p.stderr)
    m=re.search(r'initial password is:\s*([^\s]+)',text,re.IGNORECASE)
    if m:
        print('账号')
        print('admin')
        print('密码')
        print(m.group(1))
        print('请妥善保存并在登录后修改；这里显示的是初始密码，不代表修改后的密码。')
        break
    if p.returncode:
        print("读取初始化日志失败；未重置密码。")
        break
    time.sleep(1)
else:
    print('未读取到初始密码。可在服务器运行：docker logs openlist')
PYPASSWORD
}
install_official() {
    require_docker || return 1
    if [ -e "$APP_DIR" ] || [ -L "$APP_DIR" ] || docker container inspect "$NAME" >/dev/null 2>&1; then
        echo "目录或同名容器已存在，不覆盖。已有安装按来源选择 2 或 12 号更新。"; return 1
    fi
    local host_port bind
    local -a ftps_binds=()
    if [[ -f /etc/systemd/system/openlist-ftps-anchor.service ]];then
        ftps_engine verify-all || return 1
        ftps_binds=(-v '/home/docker/挂载目录:/mnt/ftps:rw,rslave')
    fi
    IFS= read -r -p "请输入地址（回车默认 127.0.0.1；可选 127.0.0.1 或 0.0.0.0）：" bind || return 1
    bind=${bind:-127.0.0.1}
    [[ "$bind" = 127.0.0.1 || "$bind" = 0.0.0.0 ]] || { echo "绑定地址无效。"; return 1; }
    IFS= read -r -p "网页端口（回车默认 5244）：" host_port || return 1
    host_port=${host_port:-5244}
    [[ "$host_port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$host_port <= 65535)) || { echo "端口无效。"; return 1; }
    LC_ALL=C.UTF-8 PYTHONUTF8=1 python3 - "$APP_DIR" <<'PYPATH'
from pathlib import Path
import sys
p = Path(sys.argv[1])
if any(q.is_symlink() for q in (p, *p.parents)):
    sys.exit('拒绝通过符号链接安装，未修改目录。')
PYPATH
    [ "$?" -eq 0 ] || return 1
    docker pull "$IMAGE" || return 1
    mkdir -m 755 -p "$APP_DIR/data" || return 1
    chown 1000:1000 "$APP_DIR/data" || return 1
    chmod 755 "$APP_DIR/data" || return 1
    docker run -d \
        --name "$NAME" \
        --restart always \
        -p "$bind:$host_port:5244" \
        -v "$APP_DIR/data:/opt/openlist/data" \
        "${ftps_binds[@]}" \
        --user 1000:1000 \
        "$IMAGE" || return 1
    ready || return 1
    echo "安装完成（容器运行与 HTTP 页面验证通过；未验证网页登录）。"
    addresses || return 1
    show_initial_password
}
install_custom() {
    local IMAGE=zaixiangjian/openlist:latest
    install_official
}
update_custom() {
    local IMAGE=zaixiangjian/openlist:latest
    update_official
}
login_docker() {
    require_docker || return 1
    docker login
}
push_custom() {
    require_docker || return 1
    local source target=zaixiangjian/openlist:latest local_id
    source=$(docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null) || { echo "没有当前实例，拒绝猜测推送源镜像。"; return 1; }
    [ -n "$source" ] || return 1
    local_id=$(docker image inspect "$source" -f '{{.Id}}' 2>/dev/null) || { echo "没有可用源镜像，请先安装。"; return 1; }
    echo "将推送本地镜像 $local_id 到 $target，不修改容器。"
    docker tag "$source" "$target" && docker push "$target" || return 1
    docker manifest inspect --verbose "$target" | python3 -c '
import json,sys
x=json.load(sys.stdin)
if not isinstance(x,list): x=[x]
d=[i.get("SchemaV2Manifest",i.get("OCIManifest",{})).get("config",{}).get("digest") for i in x]
if sys.argv[1] not in d:sys.exit("远端摘要不匹配，无法确认推送结果。")
print("远端摘要与本地一致，推送验证通过。")
' "$local_id"
}
update_official() {
    require_docker || return 1
    echo "将更新当前实例，镜像来源：$IMAGE"
    echo "按所选镜像来源直接更新，保留端口、环境变量与数据，采用新镜像默认启动配置。"
    echo "不创建配置备份、数据快照或回滚容器；更新失败需手动处理。请勿并发更新/卸载。"
    confirm || { echo "已取消"; return 0; }
    engine update
}
uninstall_app() {
    require_docker || return 1
    echo "支持 1 号自定义安装及 11 号官方安装；其他容器若引用此目录则拒绝删除。"
    echo "将删除 openlist 及由私有配置备份中的完整 ID 验证归属的停止回滚容器，以及 $APP_DIR 全部数据。"
    echo "保留 Docker、镜像和 /home 下独立备份。"
    confirm || { echo "已取消"; return 0; }
    engine uninstall
}
api_engine() {
    LC_ALL=C.UTF-8 PYTHONUTF8=1 python3 - "$1" "$API_NAME" "$API_APP_DIR" "$API_IMAGE" "${2:-}" "${3:-}" "${4:-}" "${5:-}" <<'PYAPI'
import json, os, re, shutil, socket, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path
mode, name, directory, image, bind, port, domain, env_source = sys.argv[1:]
root = Path(directory)
label = 'org.openlist.api-manager.directory'

def docker(*args):
    p = subprocess.run(['docker', *args], capture_output=True, encoding='utf-8', errors='replace')
    if p.returncode:
        raise RuntimeError('API Docker 操作失败：' + args[0] + '（诊断可能含密钥，不自动显示）')
    return p.stdout.strip()

def inspect(ref):
    return json.loads(docker('inspect', ref))[0]

def exists():
    return subprocess.run(['docker', 'container', 'inspect', name], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0

def paths(required=True):
    if any(p.is_symlink() for p in (root, *root.parents)):
        raise RuntimeError('拒绝符号链接 API 应用目录')
    if root.exists():
        if not root.is_dir() or root.stat().st_uid != 0 or (root.stat().st_mode & 0o777) != 0o700:
            raise RuntimeError('API 配置目录必须由 root 所有且权限 0700')
        for p in (root / '.env', root / 'deploy.json'):
            if p.is_symlink() or (p.exists() and (not p.is_file() or p.stat().st_uid != 0 or (p.stat().st_mode & 0o777) != 0o600)):
                raise RuntimeError('API 配置文件必须是 root 所有的 0600 普通文件')
    elif required:
        raise RuntimeError('API 配置目录不存在')

def owned(x):
    if (x.get('Config', {}).get('Labels') or {}).get(label) != str(root):
        raise RuntimeError('API 同名容器不属于本管理器，拒绝操作')

def save(filename, content):
    fd, tmp = tempfile.mkstemp(prefix='.config-', dir=root)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
        os.replace(tmp, root / filename)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def endpoints(x):
    for b in x['NetworkSettings'].get('Ports', {}).get('3000/tcp') or []:
        ip = b['HostIp'] or '127.0.0.1'
        if ip == '0.0.0.0': ip = '127.0.0.1'
        if ip == '::': ip = '::1'
        if ':' in ip: ip = '[' + ip + ']'
        yield 'http://' + ip + ':' + b['HostPort'] + '/'

def ready(ref):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(60):
        x = inspect(ref)
        if not x['State']['Running']:
            raise RuntimeError('API 容器未运行；请在本机检查日志（可能含密钥）')
        for url in endpoints(x):
            try:
                with opener.open(url, timeout=2) as r:
                    body = r.read(65536)
                    if r.status == 200 and b'<html' in body.lower(): return
            except (OSError, ValueError): pass
        time.sleep(1)
    raise RuntimeError('API HTTP 页面启动验证超时；未验证 OAuth/令牌功能')

def addresses():
    x = inspect(name)
    print('API 容器状态：' + x['State']['Status'])
    for url in endpoints(x): print('API 本机验证地址：' + url)
    for b in x['NetworkSettings'].get('Ports', {}).get('3000/tcp') or []:
        if b['HostIp'] in ('0.0.0.0', '', '::'):
            print('API 监听所有接口；公网访问需反向代理 HTTPS 与防火墙控制。')
        else: print('API 默认仅本机访问；远程需 SSH 隧道或反向代理。')

def record(x):
    env = x['Config'].get('Env') or []
    if any('\n' in e or '\r' in e or '=' not in e for e in env):
        raise RuntimeError('不支持多行环境变量')
    save('.env', '\n'.join(env) + '\n')
    # 私有配置不输出环境变量或整个 inspect（可能含 OAuth 密钥）。
    save('deploy.json', json.dumps({'container': name, 'image_id': x['Image'],
         'image': image, 'ports': x['HostConfig'].get('PortBindings'),
         'mounts': x.get('Mounts', [])}, ensure_ascii=False))

def validate(x):
    owned(x)
    hc, cfg = x['HostConfig'], x['Config']
    if x['State'].get('Paused') or x['State'].get('Restarting'):
        raise RuntimeError('API 暂停/重启中，拒绝更新')
    if hc.get('NetworkMode') != 'bridge' or set(x['NetworkSettings'].get('Networks', {})) != {'bridge'}:
        raise RuntimeError('不支持自定义 API 网络，拒绝丢失配置')
    if not hc.get('PortBindings', {}).get('3000/tcp'):
        raise RuntimeError('API 缺少 3000/tcp 映射')
    if any('\n' in e or '\r' in e or '=' not in e for e in cfg.get('Env') or []):
        raise RuntimeError('不支持多行环境变量')
    # 用原镜像的实际默认配置核实启动项，避免悄悄丢失手工覆盖。
    original = json.loads(docker('image', 'inspect', x['Image']))[0]['Config']
    for k in ('Entrypoint', 'Cmd', 'WorkingDir', 'Healthcheck', 'Shell'):
        if cfg.get(k) != original.get(k):
            raise RuntimeError('不支持手工覆盖 API 启动配置：' + k)
    for k in ('Tty', 'OpenStdin', 'StdinOnce', 'NetworkDisabled', 'MacAddress'):
        if cfg.get(k): raise RuntimeError('不支持自定义 API Config：' + k)
    # HostConfig 采用已有主程序的 fail-closed 白名单；仅复制明确支持的选项。
    preserved = {'Binds', 'PortBindings', 'RestartPolicy', 'NetworkMode', 'LogConfig'}
    defaults = {'ContainerIDFile': '', 'AutoRemove': False, 'VolumeDriver': '', 'VolumesFrom': None,
                'CgroupnsMode': 'private', 'IpcMode': 'private', 'ShmSize': 67108864,
                'Runtime': 'runc', 'Isolation': '',
                'MaskedPaths': ['/proc/asound', '/proc/acpi', '/proc/interrupts', '/proc/kcore',
                                '/proc/keys', '/proc/latency_stats', '/proc/timer_list', '/proc/timer_stats',
                                '/proc/sched_debug', '/proc/scsi', '/sys/firmware', '/sys/devices/virtual/powercap'],
                'ReadonlyPaths': ['/proc/bus', '/proc/fs', '/proc/irq', '/proc/sys', '/proc/sysrq-trigger']}
    for k, v in hc.items():
        if k in preserved: continue
        if k == 'ConsoleSize' and isinstance(v, list) and len(v) == 2 and all(type(n) is int and n >= 0 for n in v): continue
        if k in defaults:
            same = set(v) == set(defaults[k]) if k in ('MaskedPaths', 'ReadonlyPaths') and isinstance(v, list) else v == defaults[k]
            if not same: raise RuntimeError('不支持自定义 API HostConfig：' + k)
        elif v not in (None, False, 0, '', [], {}):
            raise RuntimeError('不支持额外 API HostConfig：' + k)
    for n in x['NetworkSettings']['Networks'].values():
        if any(n.get(k) for k in ('Aliases', 'Links', 'IPAMConfig', 'DriverOpts')):
            raise RuntimeError('不支持自定义 API 网络参数')
    if hc.get('LogConfig', {}).get('Type') not in ('none', 'json-file', 'local'):
        raise RuntimeError('不支持此 API 日志驱动')
    # Mounts 字段中的高级挂载自动拒绝；标准 -v bind/volume 原样保留（含 ro）。
    if len(x.get('Mounts', [])) != len(hc.get('Binds') or []):
        raise RuntimeError('不支持 API 高级或镜像匿名挂载，拒绝丢失配置')

def install():
    paths(False)
    if root.exists() or exists(): raise RuntimeError('API 目录或容器已存在，不覆盖；选择 22/32 更新')
    if bind not in ('127.0.0.1', '0.0.0.0') or not port.isdigit() or not 1 <= int(port) <= 65535 or int(port) == 5244:
        raise RuntimeError('API 地址/端口无效，不能使用主程序默认端口 5244')
    with socket.socket() as s:
        s.bind((bind, int(port)))
    for ident in docker('ps', '-aq').split():
        x = inspect(ident)
        if any(b.get('HostPort') == port for binds in (x['HostConfig'].get('PortBindings') or {}).values() for b in binds or []):
            raise RuntimeError('API 端口已有 Docker 配置占用')
    if not re.fullmatch(r'[A-Za-z0-9.-]+(?::[0-9]{1,5})?', domain):
        raise RuntimeError('OPLIST_MAIN_URLS 应为域名（不含协议/路径）')
    env = ['OPLIST_MAIN_URLS=' + domain]
    if env_source:
        p = Path(env_source)
        if any(q.is_symlink() for q in (p, *p.parents)) or not p.is_file() or p.stat().st_uid != 0 or (p.stat().st_mode & 0o777) != 0o600:
            raise RuntimeError('环境文件必须为 root 所有、0600 的非符号链接普通文件')
        for line in p.read_text(encoding='utf-8').splitlines():
            if not line or line.startswith('#'): continue
            k, sep, v = line.partition('=')
            if not sep or not re.fullmatch(r'OPLIST_[A-Z0-9_]+', k) or any(c in v for c in '\r\n"\\&|'):
                raise RuntimeError('环境文件格式无效或含上游 sed/JSON 不安全字符；值不加引号')
            if k != 'OPLIST_MAIN_URLS': env.append(line)
    docker('pull', image)
    target = json.loads(docker('image', 'inspect', image))[0]['Id']
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    save('.env', '\n'.join(env) + '\n')
    cid = docker('run', '-d', '--name', name, '--restart', 'unless-stopped', '--network', 'bridge',
                 '--log-driver', 'none', '--label', label + '=' + str(root),
                 '--env-file', str(root / '.env'), '-p', bind + ':' + port + ':3000', target)
    record(inspect(cid))
    ready(cid)
    print('API HTTP 页面验证通过；未验证 OAuth/令牌功能。')
    addresses()

def update():
    paths()
    x = inspect(name)
    validate(x)
    docker('pull', image)
    target = json.loads(docker('image', 'inspect', image))[0]['Id']
    if target == x['Image']:
        record(x)
        print('API 实际镜像已一致，无需重建。'); return
    cfg, hc = x['Config'], x['HostConfig']
    with tempfile.TemporaryDirectory(prefix='openlist-api-update-', dir='/run') as tmp:
        env = Path(tmp) / 'runtime.env'
        fd = os.open(env, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f: f.write('\n'.join(cfg.get('Env') or []) + '\n')
        rp = hc['RestartPolicy']; restart = rp['Name'] or 'no'
        if restart == 'on-failure' and rp.get('MaximumRetryCount'): restart += ':' + str(rp['MaximumRetryCount'])
        candidate = name + '-update-' + Path(tmp).name.rsplit('-', 1)[-1]
        args = ['create', '--name', candidate, '--restart', restart, '--network', 'bridge', '--env-file', str(env)]
        if cfg.get('User'): args += ['--user', cfg['User']]
        for mount in hc.get('Binds') or []: args += ['-v', mount]
        for p, bindings in (hc.get('PortBindings') or {}).items():
            for b in bindings or []:
                ip = b['HostIp']; ip = '[' + ip + ']' if ':' in ip else ip
                args += ['-p', (ip + ':' if ip else '') + b['HostPort'] + ':' + p]
        for k, v in (cfg.get('Labels') or {}).items(): args += ['--label', k + '=' + v]
        lc = hc['LogConfig']; args += ['--log-driver', lc['Type']]
        for k, v in lc.get('Config', {}).items(): args += ['--log-opt', k + '=' + v]
        new = docker(*args, target)
        removed = False
        try:
            if inspect(new)['Image'] != target: raise RuntimeError('API 新镜像校验失败')
            docker('rm', '-f', x['Id']); removed = True
            docker('rename', new, name)
            record(inspect(new))
            if x['State']['Running']:
                docker('start', new); ready(new)
            print('API 直接更新完成；环境、端口、挂载保留，未创建备份/回滚容器。')
            addresses()
        except BaseException:
            if not removed: docker('rm', '-f', new)
            else: print('API 替换后未验证通过；配置未删除，请人工检查 API 容器；无自动回滚。')
            raise

def uninstall():
    paths(False)
    if exists(): owned(inspect(name))
    for ident in docker('ps', '-aq').split():
        x = inspect(ident)
        if x.get('Name') == '/' + name: continue
        if any(m.get('Source') == str(root) or m.get('Source', '').startswith(str(root) + '/') for m in x.get('Mounts', [])):
            raise RuntimeError('其他容器使用 API 目录，拒绝删除')
    if exists(): docker('rm', '-f', name)
    if exists(): raise RuntimeError('API 容器仍存在，保留配置')
    for ident in docker('ps', '-aq').split():
        if any(m.get('Source') == str(root) or m.get('Source', '').startswith(str(root) + '/') for m in inspect(ident).get('Mounts', [])):
            raise RuntimeError('容器仍引用 API 目录，保留配置')
    if root.exists(): shutil.rmtree(root)
    print('已删除独立 API 容器及 API 配置目录；OpenList 主程序与外部挂载不变。')

try:
    if mode == 'install': install()
    elif mode == 'update': update()
    elif mode == 'uninstall': uninstall()
    elif mode == 'addresses': addresses()
    elif mode == 'owned':
        paths(); owned(inspect(name))
    else: raise RuntimeError('未知 API 操作')
except Exception as exc:
    # 不输出 subprocess 命令、环境值、配置内容或上游启动日志。
    print(str(exc) if isinstance(exc, RuntimeError) else 'API 操作失败（检查权限、端口及私有配置；未输出敏感内容）', file=sys.stderr)
    sys.exit(1)
PYAPI
}
install_api_official() {
    require_docker || return 1
    if [ -e "$API_APP_DIR" ] || [ -L "$API_APP_DIR" ] || docker container inspect "$API_NAME" >/dev/null 2>&1; then
        echo "API 目录或容器已存在，不覆盖；请先选择 22 官方更新或 32 自定义更新。"
        return 1
    fi
    local bind port domain env_file
    echo "独立 OAuth/token 获取工具，不是 OpenList 内置 API；不会修改主程序接口。"
    echo "将新建 $API_NAME 和 $API_APP_DIR；请勿并发安装/更新/卸载。"
    echo "上游 entrypoint 会输出含密钥的配置，本管理器新安装禁用 Docker 日志。"
    confirm || { echo "已取消"; return 0; }
    IFS= read -r -p "API 监听地址（默认 127.0.0.1；可选 0.0.0.0）：" bind || return 1
    IFS= read -r -p "API 主机端口（默认 3000，不可使用 5244）：" port || return 1
    IFS= read -r -p "OAuth 回调域名例如 api.oplist.org（必填，不含协议/路径）：" domain || return 1
    IFS= read -r -p "可选 OAuth 环境文件路径（root/0600；回车不导入）：" env_file || return 1
    api_engine install "${bind:-127.0.0.1}" "${port:-3000}" "$domain" "$env_file" || return 1
    echo "按需配置 HTTPS、各网盘应用密钥/回调域名，并手动设置相应 OpenList 驱动高级 API URL。"
    echo "容器内不能用 127.0.0.1 访问另一容器；请使用可达域名/网络地址。"
}
install_api_custom() {
    local API_IMAGE=zaixiangjian/openlist-api-server:latest
    install_api_official
}
update_api_official() {
    require_docker || return 1
    if [ ! -d "$API_APP_DIR" ] || ! docker container inspect "$API_NAME" >/dev/null 2>&1; then
        echo "API 服务尚未完整安装，请先选择 21 官方安装或 31 自定义安装，再使用 22/32 更新。"
        return 1
    fi
    echo "仅更新独立 API 服务，镜像来源：$API_IMAGE；保留环境、端口和挂载。"
    echo "采用新镜像默认启动配置，不备份/自动回滚；请勿并发操作。"
    confirm || { echo "已取消"; return 0; }
    api_engine update
}
update_api_custom() {
    local API_IMAGE=zaixiangjian/openlist-api-server:latest
    update_api_official
}
uninstall_api() {
    require_docker || return 1
    echo "仅删除 $API_NAME 容器和 $API_APP_DIR 全部配置（可能含 OAuth 密钥）。"
    echo "不删除 OpenList 主程序、外部挂载、Docker、镜像或 /home 独立备份。"
    confirm || { echo "已取消"; return 0; }
    api_engine uninstall
}
push_api_custom() {
    require_docker || return 1
    api_engine owned || return 1
    local source target=zaixiangjian/openlist-api-server:latest local_id
    source=$(docker inspect -f '{{.Image}}' "$API_NAME" 2>/dev/null) || { echo "没有当前 API 实例，拒绝猜测源镜像。"; return 1; }
    [[ "$source" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "API 源镜像 ID 无效。"; return 1; }
    local_id=$(docker image inspect "$source" -f '{{.Id}}' 2>/dev/null) || return 1
    [ "$local_id" = "$source" ] || return 1
    echo "推送当前 API 的不可变镜像 $local_id 到 $target；不拉取目标，不修改容器。"
    docker tag "$source" "$target" && docker push "$target" || return 1
    docker manifest inspect --verbose "$target" | python3 -c '
import json,sys
x=json.load(sys.stdin)
if not isinstance(x,list): x=[x]
d=[i.get("SchemaV2Manifest",i.get("OCIManifest",{})).get("config",{}).get("digest") for i in x]
if sys.argv[1] not in d:sys.exit("API 远端摘要不匹配，无法确认推送结果。")
print("API 远端摘要与本地一致，推送验证通过。")
' "$local_id"
}
ftps_engine() {
    python3 - "$1" 3<&0 <<'PYFTPS'
import os,sys,pathlib,json,re,subprocess,tempfile,shutil,termios,fcntl
BASE=pathlib.Path('/home/docker/openlist-ftps');MOUNT=pathlib.Path('/home/docker/挂载目录');CACHE=BASE;SYSTEM=pathlib.Path('/etc/systemd/system')
def run(args,**kw):
    p=subprocess.run(args,capture_output=True,timeout=kw.pop('timeout',90),**kw)
    if p.returncode:raise RuntimeError('操作失败：'+args[0]+' '+args[1]+'；请在本机查看服务日志，不要公开凭据')
    return p.stdout
def ask(prompt,secret=False):
    print(prompt,end='',flush=True);old=None
    try:
        if secret and os.isatty(3):
            old=termios.tcgetattr(3);new=old[:];new[3]&=~termios.ECHO;termios.tcsetattr(3,termios.TCSADRAIN,new)
        raw=bytearray()
        while True:
            b=os.read(3,1)
            if not b:raise EOFError
            if b==b'\n':break
            raw.extend(b)
    finally:
        if old is not None:termios.tcsetattr(3,termios.TCSADRAIN,old);print()
    v=raw.decode().removesuffix('\r')
    if v in (':quit',':cancel','退出配置向导'):raise EOFError
    if any(ord(c)<32 or ord(c)==127 for c in v):raise ValueError('输入含控制字符')
    return v
def safe(p):
    if any(q.is_symlink() for q in (p,*p.parents)):raise ValueError('拒绝符号链接路径')
def records():
    safe(BASE)
    if not BASE.exists():return []
    if BASE.stat().st_uid!=0 or BASE.stat().st_mode&0o077:raise ValueError('配置目录需root:0700')
    rs=[]
    for p in sorted(BASE.glob('*.json')):
        safe(p)
        if p.stat().st_uid!=0 or p.stat().st_mode&0o077:raise ValueError('记录权限不安全')
        r=json.loads(p.read_text());n=r.get('name','')
        if not re.fullmatch('[a-z][a-z0-9_-]{0,31}',n) or p.name!=n+'.json':raise ValueError('记录名称无效')
        rs.append(r)
    return rs
def unit(n):return 'openlist-ftps-'+n+'.service'
def write(p,text,mode=0o600):
    safe(p);fd,tmp=tempfile.mkstemp(prefix='.ftps-',dir=p.parent)
    try:
        with os.fdopen(fd,'w') as f:os.fchmod(f.fileno(),mode);f.write(text);f.flush();os.fsync(f.fileno())
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def select():
    rs=records()
    if not rs:raise ValueError('暂无挂载配置')
    for i,r in enumerate(rs,1):print(str(i)+'. '+r['name'])
    v=ask('选择编号（0取消）：')
    if v=='0':raise EOFError
    if not v.isascii() or not v.isdigit() or not 1<=int(v)<=len(rs):raise ValueError('编号无效')
    return rs[int(v)-1]['name']
def check(n):
    if subprocess.run(['mountpoint','-q',str(MOUNT/n)],capture_output=True,timeout=3).returncode:
        raise ValueError(n+'：本地目录未挂载，请先选择3启动挂载')
    remote=next(r['remote'] for r in records() if r['name']==n)
    args=['rclone','lsf','remote:'+remote,'--config',str(BASE/(n+'.conf')),'--max-depth','1','--contimeout','10s','--timeout','20s','--retries','1','--low-level-retries','1']
    reason='远程读取失败'
    for attempt in range(2):
        try:
            p=subprocess.run(args,capture_output=True,timeout=40)
            if p.returncode==0:break
            diagnostic=p.stderr.decode(errors='replace').lower()
            if '401' in diagnostic and any(k in diagnostic for k in ('refresh token','retrieve token')):reason='远端后端授权失效（401），不是本地登录失败';break
            if any(k in diagnostic for k in ('certificate','x509')):reason='TLS证书验证失败';break
            if any(k in diagnostic for k in ('530','authentication failed','login incorrect')):reason='账号认证失败';break
            if any(k in diagnostic for k in ('timeout','timed out')):reason='远程连接或读取超时'
            elif any(k in diagnostic for k in ('421','too many')):reason='远程服务繁忙或连接数受限'
        except subprocess.TimeoutExpired:reason='远程读取超过40秒'
        if attempt==0:print(n+'：远程读取暂未通过，重试一次……')
    else:raise ValueError(n+'：'+reason+'；未重建容器，配置和缓存保留')
    if reason in ('TLS证书验证失败','账号认证失败','远端后端授权失效（401），不是本地登录失败'):raise ValueError(n+'：'+reason+'；未重建容器')
    try:
        p=subprocess.run(['ls','-A',str(MOUNT/n)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
    except subprocess.TimeoutExpired:raise ValueError(n+'：本地FUSE挂载读取超时，远程检查已通过；未重建容器，请检查挂载服务')
    if p.returncode:raise ValueError(n+'：本地FUSE挂载读取失败；未重建容器，请检查挂载服务')
def preflight():
    if not pathlib.Path('/run/systemd/system').is_dir():raise ValueError('需要正在运行的systemd')
    if any(not shutil.which(x) for x in ('rclone','fusermount3','mountpoint','mount','ls','findmnt')):
        print('需安装rclone/fuse3/util-linux/coreutils')
        if ask('输入yes安装依赖（其他取消）：')!='yes':raise EOFError
        if not shutil.which('apt-get'):raise ValueError('请先安装依赖，此系统不支持自动安装')
        run(['apt-get','update'],timeout=180);run(['apt-get','install','-y','rclone','fuse3','util-linux','coreutils','ca-certificates'],timeout=300)
    missing=[x for x in ('rclone','fusermount3','mountpoint','mount','ls','findmnt') if not shutil.which(x)]
    if missing:raise ValueError('依赖安装后仍缺少：'+', '.join(missing))
    if not pathlib.Path('/dev/fuse').exists() and shutil.which('modprobe'):
        subprocess.run(['modprobe','fuse'],capture_output=True,timeout=10)
    if not pathlib.Path('/dev/fuse').exists():raise ValueError('未找到/dev/fuse；需要宿主机启用FUSE，受限容器/VPS无法通过安装软件解决')
    helptext=run(['rclone','mount','--help']).decode()
    required=('--vfs-cache-mode','--vfs-cache-max-size','--allow-other','--default-permissions')
    if any(flag not in helptext for flag in required):raise ValueError('rclone缺少所需挂载能力，请升级后重试')
    for p in (BASE,MOUNT,SYSTEM):safe(p)
    BASE.mkdir(mode=0o700,parents=True,exist_ok=True);records()
    MOUNT.mkdir(mode=0o755,parents=True,exist_ok=True)
    p=SYSTEM/'openlist-ftps-anchor.service'
    text='[Unit]\nDescription=OpenList FTPS shared anchor\nAfter=local-fs.target\nBefore=docker.service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/mount --bind /home/docker/挂载目录 /home/docker/挂载目录\nExecStart=/bin/mount --make-rshared /home/docker/挂载目录\n[Install]\nWantedBy=multi-user.target\n'
    safe(p)
    if p.exists() and p.read_text()!=text:raise ValueError('同名anchor服务不属于本管理器')
    if not p.exists():
        if subprocess.run(['mountpoint','-q',str(MOUNT)]).returncode==0 or any(MOUNT.iterdir()):raise ValueError('挂载根目录已被使用，拒绝接管')
        write(p,text,0o644)
    run(['systemctl','daemon-reload']);run(['systemctl','enable','--now',p.name])
    if 'shared' not in run(['findmnt','-n','-o','PROPAGATION','--target',str(MOUNT)]).decode():raise ValueError('父挂载点传播未生效')
def add():
    preflight();n=ask('唯一名称（小写字母开头，最多32位，例如namecrane）：')
    if not re.fullmatch('[a-z][a-z0-9_-]{0,31}',n):raise ValueError('名称无效')
    for p in (BASE/(n+'.json'),BASE/(n+'.conf'),SYSTEM/unit(n),MOUNT/n,CACHE/n):
        safe(p)
        if p.exists():raise ValueError('同名配置或目录已存在，不覆盖')
    host=ask('FTPS主机（例如eu1.workspace.org）：')
    if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9.:-]*',host):raise ValueError('主机无效')
    port=ask('端口（回车21；该服务填8221）：') or '21'
    if not port.isascii() or not port.isdigit() or not 1<=int(port)<=65535:raise ValueError('端口无效')
    user=ask('账号：');password=ask('密码（隐藏输入）：',True)
    if not user or not password:raise ValueError('账号密码不能为空')
    remote=ask('远程目录（回车/）：') or '/'
    if not remote.startswith('/') or any(x in ('.','..') for x in remote.split('/')):raise ValueError('远程目录必须为绝对路径且不能穿越')
    print('是否忽略远程文件修改时间')
    print('不支持 SetModTime 的服务选 yes 支持的服务输入 no')
    while True:
        no_modtime=ask('请输入你的选择（不知道怎么选直接回车默认 yes ）：') or 'yes'
        if no_modtime in ('yes','no'):break
        print('请输入小写 yes 或 no，回车默认 yes。')
    colored=sys.stdout.isatty() and os.environ.get('TERM','dumb')!='dumb'
    def hint(text,color):
        print('\033['+color+'m'+text+'\033[0m' if colored else text)
    hint('VFS 缓存软上限（非硬性限制，实际占用可能超过设定值）','32')
    hint('推荐设置：10GB 磁盘 → 1G，100GB 磁盘 → 10G，以此类推','32')
    hint('上传 5GB、10GB 大文件，占用超过VFS缓存软上限','33')
    hint('频繁读写或处理大文件建议 5G 以上，并确保磁盘有足够剩余空间','33')
    size=ask('VFS缓存软上限（如10G，回车默认1G）：') or '1G'
    if not re.fullmatch('[1-9][0-9]{0,4}[MG]',size):raise ValueError('缓存格式无效')
    print('启用STARTTLS及证书验证；缓存是软上限，待上传/打开文件可超限。不会创建远程目录。')
    if ask('输入小写yes添加：')!='yes':raise EOFError
    secret=run(['rclone','obscure','-'],input=(password+'\n').encode()).decode().strip();password=None
    conf=BASE/(n+'.conf');service=SYSTEM/unit(n)
    try:
        write(conf,'[remote]\ntype = ftp\nhost = '+host+'\nport = '+str(int(port))+'\nuser = '+user+'\npass = '+secret+'\nexplicit_tls = true\ntls = false\nno_check_certificate = false\n')
        run(['rclone','lsf','remote:'+remote,'--config',str(conf),'--max-depth','1','--contimeout','10s','--timeout','20s','--retries','1'],timeout=40)
        (MOUNT/n).mkdir(mode=0);(CACHE/n).mkdir(mode=0o700)
        def quote(v):return '"'+str(v).replace('\\','\\\\').replace('"','\\"').replace('%','%%')+'"'
        args=[shutil.which('rclone'),'mount','remote:'+remote,str(MOUNT/n),'--config',str(conf),'--allow-other','--default-permissions','--uid','1000','--gid','1000','--umask','007','--dir-perms','0770','--file-perms','0660','--vfs-cache-mode','writes','--cache-dir',str(CACHE/n),'--vfs-cache-max-size',size,'--vfs-cache-max-age','24h','--contimeout','10s','--timeout','1m','--log-level','ERROR']
        if no_modtime=='yes':args+=['--no-modtime']
        helptext=run([args[0],'mount','--help']).decode()
        if '--vfs-cache-min-free-space' in helptext:args+=['--vfs-cache-min-free-space','1G']
        # 实际解析全部参数后再安装服务，防止旧版本收到未知flag后反复重启。
        run(args+['--help'])
        text='[Unit]\nDescription=OpenList FTPS '+n+'\nRequires=openlist-ftps-anchor.service\nAfter=network-online.target openlist-ftps-anchor.service\nWants=network-online.target\n[Service]\nType=notify\nUMask=0077\nExecStart='+' '.join(map(quote,args))+'\nExecStop='+shutil.which('fusermount3')+' -u '+quote(MOUNT/n)+'\nRestart=on-failure\nRestartSec=10\nTimeoutStartSec=infinity\nTimeoutStopSec=180\n[Install]\nWantedBy=multi-user.target\n'
        write(service,text,0o644)
        write(BASE/(n+'.json'),json.dumps({'name':n,'remote':remote,'cache_size':size,'no_modtime':no_modtime=='yes'},ensure_ascii=False))
        run(['systemctl','daemon-reload'])
        if not start_mount(n,enable=True):raise SystemExit(2)
        print('挂载及只读验证成功；容器本机存储根目录：/mnt/ftps/'+n+'；尚未验证上传。')
    except BaseException:
        print('添加未完成，本次配置/缓存保留供检查，不代表挂载成功；不删除可能的待上传数据。');raise
def start_mount(n,enable=False):
    import time
    if enable:run(['systemctl','enable',unit(n)])
    run(['systemctl','start','--no-block',unit(n)])
    for attempt in range(10):
        p=subprocess.run(['systemctl','show',unit(n),'-p','ActiveState','--value'],capture_output=True,text=True,timeout=3)
        state=p.stdout.strip()
        if state=='active':
            check(n);print('挂载已启动，实际挂载及只读检查通过；未验证上传。');return True
        if state in ('failed','inactive'):raise ValueError('挂载启动失败，配置和缓存保留；请选择2查看诊断')
        time.sleep(1)
    print('启动请求已提交，服务尚未就绪，可能正在恢复缓存；不会因菜单等待结束而终止服务。请稍后选择2检查，不要重复重启。')
    return False

def error_kind(text):
    text=text.lower()
    if '401' in text and any(k in text for k in ('refresh token','retrieve token')):return '远端后端授权失效（401），不是本地登录失败'
    if any(k in text for k in ('x509','certificate')):return 'TLS证书验证失败'
    if 'setmodtime is not supported' in text:return '远端不支持设置修改时间'
    if any(k in text for k in ('530','login incorrect','authentication failed')):return 'FTPS账号认证失败'
    if any(k in text for k in ('timeout','timed out')):return '连接或读取超时'
    if any(k in text for k in ('failed to upload','failed to copy','object not found')):return '上传或远端文件操作失败'
    return '其他服务错误（原始日志请在本机查看，勿公开凭据）'
def telemetry(n,detail=False):
    p=subprocess.run(['systemctl','show',unit(n),'-p','StatusText','--value'],capture_output=True,text=True,timeout=3)
    status=p.stdout.strip() if p.returncode==0 else ''
    match=re.search(r'to upload\s+(\d+),\s*uploading\s+(\d+)',status)
    result={'pending':int(match[1]) if match else None,'uploading':int(match[2]) if match else None}
    if detail:
        print(n+'：待上传 '+str(result['pending'] if match else '未知')+'，正在上传 '+str(result['uploading'] if match else '未知')+'（服务最近一次上报，不是实时完成保证）')
        try:
            p=subprocess.run(['du','-sh','--',str(CACHE/n)],capture_output=True,text=True,timeout=5)
            print('缓存磁盘占用：'+(p.stdout.split()[0] if p.returncode==0 and p.stdout.split() else '无法读取'))
        except subprocess.TimeoutExpired:print('缓存占用统计超时')
        p=subprocess.run(['journalctl','-u',unit(n),'--since','15 minutes ago','-n','100','--no-pager','-o','cat'],capture_output=True,text=True,timeout=5)
        if p.returncode:print('近期错误日志读取失败，不能据此判断上传正常')
        else:
            errors=[line for line in p.stdout.splitlines() if any(k in line.lower() for k in ('error','fatal','failed'))]
            kinds=list(dict.fromkeys(error_kind(line) for line in errors))
            print('近15分钟日志：'+('；'.join(kinds) if kinds else '未发现错误记录（不代表全部上传完成）'))
    return result

def edit():
    import shlex
    n=select();meta=BASE/(n+'.json');service=SYSTEM/unit(n)
    safe(meta);safe(service)
    cfg=json.loads(meta.read_text());original=service.read_text()
    line=next((l for l in original.splitlines() if l.startswith('ExecStart=')),None)
    if not line:raise ValueError('未找到服务启动参数')
    args=shlex.split(line.split('=',1)[1])
    if args[:2]!=[shutil.which('rclone'),'mount'] or args.count('--vfs-cache-max-size')!=1:raise ValueError('非预期服务参数，拒绝修改')
    current=args[args.index('--vfs-cache-max-size')+1]
    size=ask('缓存软上限（回车保留'+current+'）：') or current
    if not re.fullmatch('[1-9][0-9]{0,4}[MG]',size):raise ValueError('缓存格式无效')
    print('是否忽略远程文件修改时间')
    print('不支持 SetModTime 的服务选 yes 支持的服务输入 no')
    choice=ask('请输入你的选择（不知道怎么选直接回车默认 yes ）：') or 'yes'
    if choice not in ('yes','no'):raise ValueError('请输入yes或no')
    timeout_value=args[args.index('--timeout')+1] if '--timeout' in args else '1m'
    timeout_value=ask('I/O无活动超时（如5m，回车保留'+timeout_value+'）：') or timeout_value
    if not re.fullmatch('[1-9][0-9]{0,3}[smh]',timeout_value):raise ValueError('超时格式无效')
    transfers=args[args.index('--transfers')+1] if '--transfers' in args else '4'
    transfers=ask('上传并发（1–16，回车保留'+transfers+'）：') or transfers
    if not transfers.isascii() or not transfers.isdigit() or not 1<=int(transfers)<=16:raise ValueError('并发无效')
    for flag,value in (('--timeout',timeout_value),('--transfers',transfers)):
        if args.count(flag)>1:raise ValueError('服务参数重复，拒绝修改')
        if flag in args:args[args.index(flag)+1]=value
        else:args.extend([flag,value])
    args[args.index('--vfs-cache-max-size')+1]=size
    args=[a for a in args if a!='--no-modtime']
    if choice=='yes':args.append('--no-modtime')
    run(args+['--help'])
    if ask('输入yes保存（不重启，不删除缓存；下次启动生效）：')!='yes':raise EOFError
    def quote(v):return '"'+v.replace('\\','\\\\').replace('"','\\"').replace('%','%%')+'"'
    updated=original.replace(line,'ExecStart='+' '.join(quote(a) for a in args),1)
    updated=re.sub(r'^TimeoutStartSec=.*$','TimeoutStartSec=infinity',updated,flags=re.M)
    if not re.search(r'^TimeoutStartSec=',updated,re.M):updated=updated.replace('[Service]','[Service]\nTimeoutStartSec=infinity',1)
    cfg.update(cache_size=size,no_modtime=choice=='yes',io_timeout=timeout_value,transfers=int(transfers))
    if service.read_text()!=original:raise ValueError('配置期间服务文件已变化，未覆盖')
    before=meta.read_text()
    try:
        write(service,updated,0o644);write(meta,json.dumps(cfg,ensure_ascii=False));run(['systemctl','daemon-reload'])
    except BaseException:
        write(service,original,0o644);write(meta,before);run(['systemctl','daemon-reload']);raise
    print('已保存，仅下次启动生效，当前运行参数未改变。')
    if ask('现在应用需停止OpenList且缓存无待上传数据；输入yes尝试应用，回车不重启：')!='yes':return
    info=telemetry(n)
    if info['pending'] is None or info['pending'] or info['uploading']:raise ValueError('上传队列未知或非空，拒绝重启；设置已保存')
    cache=CACHE/n
    if any(p.is_file() and p.stat().st_size for p in cache.rglob('*')):raise ValueError('缓存非空，保守拒绝自动重启；设置已保存')
    stop(n);start_mount(n)

def stop(n,delete=False):
    p=subprocess.run(['docker','inspect','-f','{{.State.Running}}','openlist'],capture_output=True,text=True)
    if p.returncode or p.stdout.strip()!='false':raise ValueError('请先停止OpenList容器；无法确认停止时拒绝操作')
    print('请确认无其他程序使用且缓存已上传；不会删除远程文件。')
    if ask('输入小写yes确认：')!='yes':raise EOFError
    run(['systemctl','stop',unit(n)],timeout=200)
    if subprocess.run(['mountpoint','-q',str(MOUNT/n)]).returncode==0:raise ValueError('仍然挂载，未清理')
    if delete:
        cache=CACHE/n;safe(cache)
        if cache.exists() and any(p.is_file() and p.stat().st_size for p in cache.rglob('*')):raise ValueError('缓存非空，可能有待上传数据，已停止但拒绝删除；请先启动并确认上传完成')
        run(['systemctl','disable',unit(n)])
        for p in (SYSTEM/unit(n),BASE/(n+'.conf'),BASE/(n+'.json')):safe(p);p.unlink()
        if cache.exists():shutil.rmtree(cache)
        (MOUNT/n).rmdir();run(['systemctl','daemon-reload']);print('配置已删除；远程文件未删除。')
    else:print('挂载已停止，开机自启保留；底层目录禁止容器写入。')
try:
    if os.geteuid()!=0:raise ValueError('请使用root')
    lock=open('/run/lock/openlist-manager.lock','a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    action=sys.argv[1]
    if action in ('list','status'):
        rs=records()
        import unicodedata
        def width(value):return sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in value)
        rows=[]
        def health(r):
            n=r['name']
            try:
                def probe(args,seconds):
                    return subprocess.run(args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=seconds).returncode==0
                mounted=probe(['mountpoint','-q',str(MOUNT/n)],2)
                service_state=subprocess.run(['systemctl','show',unit(n),'-p','ActiveState','--value'],capture_output=True,text=True,timeout=3).stdout.strip()
                if service_state=='activating':return '启动中（缓存恢复/等待就绪）'
                active=service_state=='active'
                if not mounted:return '异常（服务运行但未挂载）' if active else '未挂载'
                if not active:return '错误（挂载服务未运行）'
                info=telemetry(n)
                if action=='status':
                    try:check(n)
                    except ValueError as e:return '错误（'+str(e)+'）'
                if info['pending'] or info['uploading']:return '传送中（最近上报：'+str(info['pending'])+'待传/'+str(info['uploading'])+'上传中）'
                if info['pending'] is None:return '已挂载（队列未知）'
                return '已挂载（本地正常）'
            except subprocess.TimeoutExpired:return '异常（检测超时）'
            except Exception:return '错误（检测失败）'
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            states=list(pool.map(health,rs))
        for r,state in zip(rs,states):
            n=r['name']
            rows.append((n,state,str(MOUNT/n),'/mnt/ftps/'+n))
        headers=('名称','状态','本地目录','容器目录')
        widths=[max([width(headers[i])]+[width(row[i]) for row in rows])+3 for i in range(3)]
        if action=='list':
            print('菜单仅检测本地服务/挂载及最近上报队列；远程、缓存占用和错误诊断请选择 2')
            print('----------------------------------')
        colored=sys.stdout.isatty() and os.environ.get('TERM','dumb')!='dumb'
        for index,row in enumerate([headers]+rows):
            label='\033[32m'+row[0]+'\033[0m' if colored and index>0 else row[0]
            state=row[1]
            if colored and index>0:
                if state=='已挂载（本地正常）':
                    state='已挂载\033[32m（本地正常）\033[0m'
                elif state.startswith('错误（'):
                    state='\033[31m'+state+'\033[0m'
                else:
                    state='\033[33m'+state+'\033[0m'
            print(label+' '*(widths[0]-width(row[0]))+state+' '*(widths[1]-width(row[1]))+row[2]+' '*(widths[2]-width(row[2]))+row[3])
        if not rs:print('暂无FTPS挂载')
        if action=='status':
            for r in rs:telemetry(r['name'],True)

    elif action=='add':add()
    elif action=='edit':edit()
    elif action=='verify-all':
        rs=records()
        if not rs:raise ValueError('请先添加挂载')
        for r in rs:check(r['name'])
    elif action=='start':
        n=select();start_mount(n)
    elif action in ('stop','delete'):stop(select(),action=='delete')
    else:raise ValueError('未知操作')
except (EOFError,KeyboardInterrupt):print('\n已取消');sys.exit(1)
except BlockingIOError:print('另一项OpenList操作正在进行');sys.exit(1)
except Exception as e:print(str(e) if isinstance(e,(ValueError,RuntimeError)) else 'FTPS操作失败；请在本机检查服务日志，勿公开凭据');sys.exit(1)
PYFTPS
}
ftps_attach() {
    require_docker || return 1
    ftps_engine verify-all || return 1
    echo '将重建OpenList，增加 /home/docker/挂载目录 → /mnt/ftps（rslave）映射，短暂中断服务。'
    confirm || return 1
    engine mount-rebuild
}
ftps_detach() {
    require_docker || return 1
    echo '将重建OpenList并移除全部 /mnt/ftps 容器映射，相关本机存储会不可用。'
    echo '请先暂停相关上传下载；宿主机挂载、配置、缓存和远程文件均保留。'
    confirm || return 1
    engine mount-detach
}
ftps_summary() {
    local view=${1:-main}
    python3 - "$view" <<'PYFTPS_SUMMARY'
import json,pathlib,subprocess,sys,os
count=0
try:
    base=pathlib.Path('/home/docker/openlist-ftps')
    for p in base.glob('*.json'):
        if p.is_symlink():continue
        r=json.loads(p.read_text())
        if r.get('name')==p.stem:count+=1
    total='有 '+str(count)+' 个挂载'
except Exception:total='挂载数量检测失败'
try:
    p=subprocess.run(['docker','inspect','openlist'],capture_output=True,text=True,timeout=3)
    if p.returncode:raise ValueError()
    x=json.loads(p.stdout)[0]
    mapped=any(m.get('Type')=='bind' and m.get('Source')=='/home/docker/挂载目录' and m.get('Destination')=='/mnt/ftps' and m.get('Propagation')=='rslave' for m in x.get('Mounts',[]))
    state='已挂载到容器' if mapped else '未挂载到容器'
    color='32' if mapped else '33'
except Exception:state='容器映射检测失败';color='33'
colored=sys.stdout.isatty() and os.environ.get('TERM','dumb')!='dumb'
if colored:state='\033['+color+'m'+state+'\033[0m'
if sys.argv[1]=='main':
    title='7. FTPS 本地挂载管理'
    if colored:title='\033[32m'+title+'\033[0m'
    print(title+'（'+total+'，'+state+'）')
else:print('6. 将挂载目录映射到OpenList（重建容器）（'+state+'）')
PYFTPS_SUMMARY
}
ftps_menu() {
    local choice
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]];then clear;fi
        echo '=================================='
        echo '       FTPS 本地挂载管理'
        echo '=================================='
        ftps_engine list
        echo '=================================='
        echo '1. 添加 FTPS 挂载'
        echo '2. 查看挂载状态'
        echo '3. 启动挂载'
        echo '4. 停止挂载（先停止OpenList）'
        echo '5. 删除挂载配置（不删除远程文件）'
        ftps_summary submenu
        echo '7. 卸载挂载（重建容器）'
        echo '8. 修改已有挂载设置（缓存/修改时间/超时/并发）'
        echo '----------------------------------'
        echo '0. 返回上一级'
        echo '----------------------------------'
        IFS= read -r -p '请输入选项：' choice || return 0
        case "$choice" in
            1) ftps_engine add && ftps_attach ;;
            2) ftps_engine status ;;
            3) ftps_engine start ;;
            4) ftps_engine stop ;;
            5) ftps_engine delete ;;
            6) ftps_attach ;;
            7) ftps_detach ;;
            8) ftps_engine edit ;;
            0) return 0 ;;
            *) echo '无效选项' ;;
        esac
        pause || return 0
    done
}
openlist_s3_state() {
    python3 - "$APP_DIR/data/config.json" <<'PY_STATE'
import json,sys,pathlib
try:
    p=pathlib.Path(sys.argv[1])
    if p.is_symlink():raise ValueError()
    value=json.loads(p.read_text())['s3']['enable']
    if type(value) is not bool:raise ValueError()
    print('enabled' if value else 'disabled')
except Exception:print('unknown')
PY_STATE
}
openlist_s3_menu() {
    local state choice bind port green='' yellow='' reset=''
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then green=$'\033[32m';yellow=$'\033[33m';reset=$'\033[0m';fi
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear;fi
        state=$(openlist_s3_state)
        echo "=================================="
        echo "      OpenList 映射为 S3 协议"
        echo "=================================="
        case "$state" in
            disabled) echo "${green}1.开启 S3 协议${reset}" ;;
            enabled) echo "${yellow}2.关闭 S3 协议${reset}" ;;
            *) echo "无法读取 S3 状态，请先安装并检查 config.json。" ;;
        esac
        echo "0. 返回上一级"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice:$state" in
            0:*) return 0 ;;
            1:disabled)
                require_docker || { pause;continue; }
                IFS= read -r -p "S3绑定地址（回车127.0.0.1，可选0.0.0.0）：" bind || return 0
                bind=${bind:-127.0.0.1}
                IFS= read -r -p "S3宿主机端口（回车5246）：" port || return 0
                port=${port:-5246}
                [[ $bind == 127.0.0.1 || $bind == 0.0.0.0 ]] && [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$port<=65535)) || { echo "地址或端口无效";pause;continue; }
                [[ $bind != 0.0.0.0 ]] || echo "注意：S3将监听外网，请配置认证、防火墙及HTTPS反向代理。"
                echo "将重建当前容器并启用 S3，不复制数据，短暂中断服务。"
                confirm && engine s3-enable "$bind" "$port"
                ;;
            2:enabled)
                require_docker || { pause;continue; }
                echo "将关闭S3并移除对应端口映射，短暂中断服务。"
                confirm && engine s3-disable
                ;;
            *) echo "无效选项" ;;
        esac
        pause || return 0
    done
}
main() {
    prepare_base || return 1
    local choice s3_state s3_label
    while true; do
        [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
        echo "=================================="
        echo "        OpenList 管理脚本"
        echo "开源网盘聚合程序，支持多种存储"
        echo "开源地址："
        echo "https://github.com/OpenListTeam/OpenList"
        echo -e "官方镜像：$IMAGE \033[33m（手动指定）\033[0m"
        echo "=================================="
        echo "1. 自己安装zaixiangjian/openlist:latest"
        echo "2. 从zaixiangjian更新"
        echo "3. 登录 Docker Hub"
        echo "4. 打上标签推送到zaixiangjian/openlist:latest"
        echo "-----------------------------------"
        ftps_summary main
        s3_state=$(openlist_s3_state)
        case "$s3_state" in enabled) s3_label='开启';;disabled) s3_label='关闭';;*) s3_label='检测失败';;esac
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
            if [[ $s3_state == enabled ]];then s3_label=$'\033[32m'"$s3_label"$'\033[0m';else s3_label=$'\033[33m'"$s3_label"$'\033[0m';fi
        fi
        echo "8. OpenList 映射为 S3 协议（ S3 状态：$s3_label）"
        echo "9. 卸载（需 yes 确认）"
        echo "-----------------------------------"
        echo "11. 官方安装（默认端口 5244）"
        echo "12. 官方更新"
        echo "-----------------------------------"
        echo "=================================="
        echo "        OpenList网盘授权"
        echo "独立网盘 OAuth 授权及令牌获取工具，非 OpenList 内置 API"
        echo "开源地址："
        echo "https://github.com/OpenListTeam/OpenList-APIPages"
        echo "官方镜像：$API_IMAGE"
        echo "=================================="
        echo "21. 自己安装zaixiangjian/openlist-api-server:latest"
        echo "22. 从zaixiangjian更新 API"
        echo "23. 登录 Docker Hub"
        echo "24. 打上标签推送到zaixiangjian/openlist-api-server:latest"
        echo "-----------------------------------"
        echo "29. 卸载 API（支持21/31；需精确 yes）"
        echo "-----------------------------------"
        echo "31. 官方安装 API（默认端口 3000）"
        echo "32. 官方更新 API"
        echo "-----------------------------------"
        echo "0. 退出"
        echo "-----------------------------------"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) install_custom ;;
            2) update_custom ;;
            3) login_docker ;;
            4) push_custom ;;
            7) ftps_menu; continue ;;
            8) openlist_s3_menu; continue ;;
            9) uninstall_app ;;
            11) install_official ;;
            12) update_official ;;
            21) install_api_custom ;;
            22) update_api_custom ;;
            23) login_docker ;;
            24) push_api_custom ;;
            29) uninstall_api ;;
            31) install_api_official ;;
            32) update_api_official ;;
            0) echo "已退出"; return 0 ;;
            *) echo "无效选项" ;;
        esac
        pause || return 0
    done
}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
