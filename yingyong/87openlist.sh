#!/usr/bin/env bash
# OpenList 管理脚本；官方镜像固定版本，自定义镜像使用 zaixiangjian/openlist。
# OpenList 官方及自定义镜像管理。
set -o pipefail
APP_DIR=/home/docker/openlist
NAME=openlist
IMAGE=openlistteam/openlist:v4.2.6
API_IMAGE=openlistteam/openlist_api_server:latest
API_NAME=openlist-api-server
API_APP_DIR=/home/docker/openlist-api-server
pause() { IFS= read -r -p "按回车继续..." _; }
confirm() {
    local answer
    IFS= read -r -p "确认请输入小写 yes：" answer || return 1
    [ "$answer" = yes ]
}
require_docker() {
    command -v docker >/dev/null && docker info >/dev/null 2>&1 || {
        echo "请先安装并启动 Docker。"; return 1;
    }
}
engine() {
    LC_ALL=C.UTF-8 PYTHONUTF8=1 python3 - "$1" "$NAME" "$APP_DIR" "$IMAGE" <<'PYENGINE'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

mode, name, root, image = sys.argv[1:]
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
    if len(mounts) != 1 or mounts[0].get('Type') != 'bind' or mounts[0].get('Source') != str(root / 'data') or mounts[0].get('Destination') != '/opt/openlist/data' or not mounts[0].get('RW') or mounts[0].get('Propagation', 'rprivate') != 'rprivate':
        raise RuntimeError('挂载与本管理器不符，拒绝自动重建')
    if not (cfg['Image'].startswith(('openlistteam/openlist:', 'zaixiangjian/openlist:', 'zaixiangjian/openliat:')) or cfg['Image'] == image_id) or cfg.get('User') != '1000:1000':
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
    if hc.get('NetworkMode') != 'bridge' or hc.get('Binds') not in ([str(root / 'data') + ':/opt/openlist/data'], [str(root / 'data') + ':/opt/openlist/data:rw']):
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

def update():
    safe_paths()
    x = inspect(name)
    validate(x)
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
main() {
    [ "$(id -u)" -eq 0 ] || { echo "请使用 root 运行。"; return 1; }
    command -v python3 >/dev/null || { echo "缺少 python3。"; return 1; }
    local choice
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
