#!/usr/bin/env bash
IMAGE=cloudreve/cloudreve:4.19.1
CUSTOM_IMAGE=zaixiangjian/cloudreve:latest
APP=/home/docker/wangpan
COMPOSE=$APP/docker-compose.yml

require_docker() {
    command -v python3 >/dev/null && command -v curl >/dev/null &&
        docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || {
        echo "需要 Python3、curl 及已启动的 Docker Compose。"; return 1;
    }
}
show_ports() {
    echo "实际端口映射："
    docker port cloudreve 2>/dev/null
}
# 旧独立下载器只作过渡清理：精确名称、镜像及根目录挂载归属，按 ID 删除。
owned_aria2() {
    python3 - "$APP" <<'PYOWN'
import json,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
p=subprocess.run(['docker','inspect','aria2'],capture_output=True,text=True)
if p.returncode: sys.exit(0)
c=json.loads(p.stdout)[0]
allowed={'/config':root/'aria2/config','/data':root/'temp_data','/downloads':root/'aria2/downloads'}
mounts=c.get('Mounts',[])
if c.get('Name')!='/aria2' or c['Config']['Image'].split(':')[0]!='p3terx/aria2-pro' or c['HostConfig'].get('Privileged') or not mounts:
    sys.exit('拒绝操作：aria2 容器无法确认属于旧部署。')
if not {'/config','/data'}.issubset({m['Destination'] for m in mounts}) or len({m['Destination'] for m in mounts})!=len(mounts) or not all(m.get('Type')=='bind' and m['Destination'] in allowed and Path(m['Source']).resolve()==allowed[m['Destination']] and not any(p.is_symlink() for p in (Path(m['Source']),*Path(m['Source']).parents)) for m in mounts):
    sys.exit('拒绝操作：aria2 挂载不属于旧部署；未删除任何容器或文件。')
print(c['Id'])
PYOWN
}
remove_owned_aria2() {
    local expected=$1 current
    [ -n "$expected" ] || return 0
    current=$(owned_aria2) || return 1
    [ -n "$current" ] || return 0
    [ "$current" = "$expected" ] || { echo "aria2 容器已变化，拒绝删除。"; return 1; }
    docker rm -f "$expected" || return 1
    if docker inspect "$expected" >/dev/null 2>&1; then echo "旧 aria2 移除验证失败。"; return 1; fi
}
wait_cloudreve() {
    python3 - <<'PYREADY'
import json,subprocess,time,urllib.request
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for _ in range(60):
    try:
        c=json.loads(subprocess.check_output(['docker','inspect','cloudreve']))[0]
        assert c['State']['Running'] and not c['State'].get('Restarting')
        assert c['State'].get('Health',{}).get('Status','healthy')=='healthy'
        bindings=c['NetworkSettings']['Ports']['5212/tcp']
        b=bindings[0]; host=b['HostIp']
        if host in ('','0.0.0.0','::'): host='127.0.0.1'
        if ':' in host: host='['+host+']'
        with opener.open('http://'+host+':'+b['HostPort']+'/',timeout=2) as r:
            if r.status==200: break
    except Exception: pass
    time.sleep(1)
else: raise SystemExit('Cloudreve 未通过运行状态/HTTP 200 启动检查')
PYREADY
}
# 只管理可确认的 v4 持久化布局；旧 v3 和匿名数据卷必须先人工迁移。
check_layout() {
    [ -f "$COMPOSE" ] && [ ! -L "$APP" ] && [ ! -L "$COMPOSE" ] || {
        echo "未找到安全的现有 Compose 配置。"; return 1;
    }
    owned_aria2 >/dev/null || return 1
    python3 - "$COMPOSE" "$APP" <<'PY'
import configparser, json, re, subprocess, sys
from pathlib import Path
def accepted_image(ref):
    # 只允许两个明确来源；镜像 ID 必须仍带有可信来源标签/摘要。
    named=r'(?:cloudreve/cloudreve|zaixiangjian/cloudreve)(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[0-9a-f]{64})'
    if re.fullmatch(named, ref): return True
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', ref): return False
    p=subprocess.run(['docker','image','inspect',ref],capture_output=True,text=True)
    if p.returncode: return False
    i=json.loads(p.stdout)[0]
    return i.get('Id')==ref and any(re.fullmatch(named,x) for x in (i.get('RepoTags') or [])+(i.get('RepoDigests') or []))
try:
    cfg=json.loads(subprocess.check_output(['docker','compose','-f',sys.argv[1],'config','--format','json']))
    # 更新只重建本应用；卸载整套前另行拒绝无关服务。
    assert 'cloudreve' in cfg['services']
    s=cfg['services']['cloudreve']
    if 'aria2' in cfg['services']:
        ar=cfg['services']['aria2']
        assert ar.get('container_name')=='aria2' and not ar.get('privileged')
        root=Path(sys.argv[2]).resolve()
        legacy={'/config':root/'aria2/config','/data':root/'temp_data','/downloads':root/'aria2/downloads'}
        assert ar.get('image','').split(':')[0]=='p3terx/aria2-pro'
        assert ar.get('volumes') and all(v.get('type')=='bind' and v['target'] in legacy and Path(v['source']).resolve()==legacy[v['target']] and not any(p.is_symlink() for p in (Path(v['source']),*Path(v['source']).parents)) for v in ar['volumes'])
        targets={v['target']:v for v in ar.get('volumes',[])}
        assert {'/config','/data'}.issubset(targets) and len(targets)==len(ar.get('volumes',[]))
        if '/data' in targets: assert Path(targets['/data']['source']).resolve()==Path(sys.argv[2]).resolve()/'temp_data'
        if '/config' in targets: assert Path(targets['/config']['source']).resolve()==Path(sys.argv[2]).resolve()/'aria2/config'
        ap=subprocess.run(['docker','inspect','aria2'],capture_output=True,text=True)
        if ap.returncode==0:
            ac=json.loads(ap.stdout)[0]
            actual={v['Destination']:(v['Type'],v['Source'],v['RW']) for v in ac['Mounts']}
            expected={v['target']:(v['type'],v['source'],not v.get('read_only',False)) for v in ar.get('volumes',[])}
            assert actual==expected, 'aria2 实际挂载与 Compose 不一致'
    probe=subprocess.run(['docker','inspect','cloudreve'],capture_output=True,text=True)
    c=json.loads(probe.stdout)[0] if probe.returncode==0 else None
    root=Path(sys.argv[2]).resolve()
    assert s.get('container_name') == 'cloudreve'
    assert accepted_image(s['image']), 'Compose 镜像不属于允许的来源'
    assert not any(s.get(k) for k in ('privileged','volumes_from')), '不安全的运行选项'
    # 自定义命令/工作目录可能显式读旧 conf/db；不猜测它的 SQLite 位置。
    assert s.get('working_dir','/cloudreve')=='/cloudreve'
    assert s.get('entrypoint') in (None,['sh','./entrypoint.sh'])
    assert s.get('command') in (None,[]), '自定义启动命令需人工确认 v4 数据路径'
    allowed={'/cloudreve/data':'data','/cloudreve/uploads':'uploads','/cloudreve/avatar':'avatar','/data':'temp_data','/cloudreve/conf.ini':'cloudreve/conf.ini','/cloudreve/cloudreve.db':'cloudreve/cloudreve.db'}
    def source_ok(target,source):
        p=Path(source)
        assert not p.is_symlink() and p.resolve().is_relative_to(root)
        expected=[root/allowed[target]]
        if target in ('/cloudreve/uploads','/cloudreve/avatar'): expected.append(root/'cloudreve'/allowed[target])
        assert p.resolve() in expected
        assert all(not x.is_symlink() for x in (p,*p.parents) if x.is_relative_to(root))
        if target in ('/cloudreve/conf.ini','/cloudreve/cloudreve.db'):
            assert p.is_file()
            assert not any(x.exists() and p.samefile(x) for x in (root/'data/conf.ini',root/'data/cloudreve.db'))
        else: assert p.is_dir()
    assert (root/'data'/'conf.ini').is_file() and (root/'data'/'cloudreve.db').is_file(), '缺少 v4 配置或数据库'
    assert not (root/'data/conf.ini').is_symlink() and not (root/'data/cloudreve.db').is_symlink(), 'v4 配置/SQLite 不允许外部链接'
    # 明确拒绝把实际数据库重定向到兼容单文件或外部位置。
    import configparser
    ini=configparser.ConfigParser(interpolation=None,strict=False); ini.read(root/'data/conf.ini')
    for section in ini.sections():
        if section.lower()=='database':
            for key,value in ini[section].items():
                if key.lower() in ('dbfile','path'):
                    resolved=Path(value) if value.startswith('/') else Path('/cloudreve')/value
                    assert resolved.parent==Path('/cloudreve/data'), 'SQLite 必须与 WAL 共存于 data'
    assert not any(k in s.get('environment',{}) for k in ('CR_CONF','CR_CONFIG','CR_DATABASE_DBFILE')), '自定义配置路径需人工审核'
    volumes=s.get('volumes',[])
    assert len({v['target'] for v in volumes})==len(volumes)
    assert any(v.get('target')=='/cloudreve/data' for v in volumes)
    for v in volumes:
        assert v.get('type')=='bind' and v.get('target') in allowed and not v.get('read_only',False)
        source_ok(v['target'],v['source'])
    assert not s.get('privileged')
    if c is None: sys.exit(0)
    assert accepted_image(c['Config']['Image']), '容器镜像不属于允许的来源'
    mounts={m['Destination']:(m['Type'],m['Source'],m['RW']) for m in c['Mounts']}
    assert mounts.get('/cloudreve/data') == ('bind',str(root/'data'),True)
    # 旧 conf/db 是兼容挂载，真实配置/SQLite/WAL 必须完整保存在 data。
    assert set(mounts).issubset(allowed), '不支持的持久化挂载'
    for target,(typ,src,rw) in mounts.items():
        assert typ=='bind' and rw
        source_ok(target,src)
    assert (root/'data'/'conf.ini').is_file() and (root/'data'/'cloudreve.db').is_file(), '缺少 v4 配置或数据库'
    expected={v['target']:(v['type'],v.get('source'),not v.get('read_only',False)) for v in s.get('volumes',[])}
    assert mounts==expected, '运行容器挂载与 Compose 不一致'
    assert all(v[0]=='bind' and Path(v[1]).resolve().is_relative_to(root) for v in mounts.values())
    env=dict(x.split('=',1) for x in c['Config']['Env'] if '=' in x)
    assert all(env.get(k)==str(v) for k,v in s.get('environment',{}).items()), '环境变量不一致'
    ports=c['HostConfig']['PortBindings'] or {}
    expected_ports={}
    for p in s.get('ports',[]):
        expected_ports.setdefault(str(p['target'])+'/'+p.get('protocol','tcp'),[]).append({'HostIp':p.get('host_ip',''),'HostPort':str(p['published'])})
    assert ports==expected_ports, '运行端口与 Compose 不一致'
except (AssertionError,KeyError,ValueError,OSError,configparser.Error,subprocess.CalledProcessError) as e:
    print('拒绝操作：旧版/匿名卷布局或实际配置不匹配，需要先人工迁移并备份。',str(e),file=sys.stderr)
    sys.exit(1)
PY
}
# v4 真正配置/SQLite/WAL 整目录挂载，uploads/avatar/conf/db 保留兼容。
# 4.19.1 入口无条件启动内置 aria2；独立 aria2 不自动关联网盘。
full_compose() {
    python3 - "$@" <<'PYFULL'
import copy,json,os,subprocess,sys
from pathlib import Path
mode,original,output,root,image,host,port=sys.argv[1:]
root=Path(root).resolve()
def config(p):
    return json.loads(subprocess.check_output(['docker','compose','--project-directory',str(root),'-f',p,'config','--format','json']))
base=config(original) if mode=='update' else {'name':root.name,'services':{}}
wanted=copy.deepcopy(base); services=wanted['services']
if mode!='update':
    services['cloudreve']={'image':image,'container_name':'cloudreve','restart':'unless-stopped','command':None,'entrypoint':None,'networks':{'default':None},'ports':[{'target':5212,'published':port,'host_ip':host,'protocol':'tcp','mode':'ingress'}],'volumes':[]}
    wanted['name']=root.name.lower().replace('.','').replace(' ','')
    wanted['networks']={'default':{'name':wanted['name']+'_default','ipam':{}}}
s=services['cloudreve']; s['image']=image
web=[p for p in s.get('ports',[]) if int(p['target'])==5212 and p.get('protocol','tcp')=='tcp']
if len(web)!=1: raise SystemExit('网页端口映射不唯一，拒绝修改')
web[0]['host_ip']=host; web[0]['published']=port
plans=[]
def mounts(service,mapping):
    vv=service.setdefault('volumes',[]); existing={v['target']:v for v in vv}
    if len(existing)!=len(vv): raise SystemExit('重复挂载目标')
    for target,source in mapping.items():
        if target in existing: continue
        src=root/source
        plans.append((src,'file' if target in ('/cloudreve/conf.ini','/cloudreve/cloudreve.db') else 'dir'))
        vv.append({'type':'bind','source':str(src),'target':target,'bind':{}})
# 仅移除明确属于旧部署的外置下载器及 temp_data 挂载。
if 'aria2' in services:
    ar=services['aria2']
    legacy={'/config':root/'aria2/config','/data':root/'temp_data','/downloads':root/'aria2/downloads'}
    if ar.get('container_name')!='aria2' or ar.get('image','').split(':')[0]!='p3terx/aria2-pro' or ar.get('privileged') or not ar.get('volumes'):
        raise SystemExit('无法确认旧 aria2 服务归属')
    if not {'/config','/data'}.issubset({v['target'] for v in ar['volumes']}) or len({v['target'] for v in ar['volumes']})!=len(ar['volumes']) or not all(v.get('type')=='bind' and v['target'] in legacy and Path(v['source']).resolve()==legacy[v['target']] and not any(p.is_symlink() for p in (Path(v['source']),*Path(v['source']).parents)) for v in ar['volumes']):
        raise SystemExit('旧 aria2 挂载不属于本部署')
    del services['aria2']
for v in s.get('volumes',[]):
    if v['target']=='/data' and (v.get('type')!='bind' or Path(v['source']).resolve()!=root/'temp_data' or Path(v['source']).is_symlink()):
        raise SystemExit('无法确认 /data 临时挂载归属')
s['volumes']=[v for v in s.get('volumes',[]) if v['target']!='/data']
deps=s.get('depends_on')
if isinstance(deps,dict): deps.pop('aria2',None)
elif isinstance(deps,list): s['depends_on']=[d for d in deps if d!='aria2']
if not s.get('depends_on'): s.pop('depends_on',None)
# 不允许其他服务通过依赖/共享网络命名空间引用将被移除的服务。
for name,svc in services.items():
    if 'aria2' in svc.get('depends_on',{}) or any(svc.get(k)=='service:aria2' for k in ('network_mode','ipc','pid')) or any(x.split(':')[0]=='aria2' for x in svc.get('links',[])) or any(x.split(':')[0]=='aria2' for x in svc.get('volumes_from',[])):
        raise SystemExit('其他配置仍引用 aria2，需人工迁移')
mounts(s,{'/cloudreve/data':'data','/cloudreve/uploads':'uploads','/cloudreve/avatar':'avatar','/cloudreve/conf.ini':'cloudreve/conf.ini','/cloudreve/cloudreve.db':'cloudreve/cloudreve.db'})
# 先检查所有新路径，不覆盖任何已有文件，不拆出 v4 活跃 SQLite。
for src,kind in plans:
    for ancestor in (src,*src.parents):
        if ancestor==root.parent: break
        if ancestor.is_symlink(): raise SystemExit('拒绝链接路径：'+str(ancestor))
    if src.exists() and not (src.is_file() if kind=='file' else src.is_dir()): raise SystemExit('路径类型不匹配：'+str(src))
    if kind=='file' and src.exists():
        for live in (root/'data/conf.ini',root/'data/cloudreve.db'):
            if live.exists() and os.path.samefile(src,live): raise SystemExit('兼容文件不得引用真实 v4 配置/数据库')
Path(output).write_text(json.dumps(wanted,ensure_ascii=False,indent=2)+'\n'); os.chmod(output,0o600)
# 同一项目目录，整个 JSON 必须等于精确的预期变更，保留其他服务/凭据/端口。
if config(output)!=wanted: raise SystemExit('配置规范化产生非预期变化，拒绝更新')
for src,kind in plans:
    src.parent.mkdir(parents=True,exist_ok=True)
    if kind=='dir': src.mkdir(exist_ok=True)
    elif not src.exists():
        with src.open('xb'): pass
print('仅 Cloudreve v4 内置 aria2；5 个持久化/兼容挂载，旧文件不覆盖。')
PYFULL
}
install_app() {
    local image=${1:-$IMAGE}
    require_docker || return 1
    if docker inspect cloudreve >/dev/null 2>&1; then
        echo "cloudreve 容器已存在，请使用 2/12 号更新或先核实容器归属。"; return 1
    fi
    if [ -e "$APP" ] || [ -L "$APP" ]; then
        echo "本地目录或数据已存在，请使用 2/12 号按所选镜像更新/恢复启动。"; return 1
    fi
    local bind port
    IFS= read -r -p "绑定地址（回车 127.0.0.1；可选 0.0.0.0）：" bind || return 1
    bind=${bind:-127.0.0.1}
    [[ "$bind" = 127.0.0.1 || "$bind" = 0.0.0.0 ]] || { echo "地址无效"; return 1; }
    IFS= read -r -p "网页端口（回车 5212）：" port || return 1
    port=${port:-5212}
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$port<=65535)) || { echo "端口无效"; return 1; }
    docker pull "$image" || return 1
    mkdir -p /home/docker && mkdir -m 700 "$APP" || return 1
    full_compose fresh - "$COMPOSE" "$APP" "$image" "$bind" "$port" || return 1
    docker compose -f "$COMPOSE" config --quiet && docker compose -f "$COMPOSE" up -d || {
        echo "启动失败，保留目录供排查；不要覆盖已有数据。"; return 1;
    }
    echo "已启动 $image；首次注册账号将成为管理员。"
    show_ports
    echo "仅使用镜像内置 aria2；不创建独立下载器或 temp_data 挂载。"
}
update_app() {
    local image=${1:-$IMAGE}
    require_docker && check_layout || return 1
    local candidate backup bind port aria_id
    aria_id=$(owned_aria2) || return 1
    IFS= read -r -p "绑定地址（回车 127.0.0.1；可选 0.0.0.0）：" bind || return 1
    bind=${bind:-127.0.0.1}
    [[ "$bind" = 127.0.0.1 || "$bind" = 0.0.0.0 ]] || { echo "地址无效"; return 1; }
    IFS= read -r -p "网页端口（回车 5212）：" port || return 1
    port=${port:-5212}
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$port<=65535)) || { echo "端口无效"; return 1; }
    candidate=$(mktemp "$APP/.compose-update.XXXXXX") || return 1
    if ! full_compose update "$COMPOSE" "$candidate" "$APP" "$image" "$bind" "$port"
    then rm -f -- "$candidate"; return 1; fi
    docker pull "$image" || { rm -f -- "$candidate"; return 1; }
    backup=$(mktemp "$APP/docker-compose.yml.before-update.XXXXXX") || { rm -f -- "$candidate"; return 1; }
    cp -p -- "$COMPOSE" "$backup" && chmod 600 "$backup" && cat "$candidate" > "$COMPOSE" && chmod 600 "$COMPOSE" || { rm -f -- "$candidate"; return 1; }
    rm -f -- "$candidate"
    docker compose --project-directory "$APP" -f "$COMPOSE" up -d --no-deps cloudreve || {
        echo "启动失败；原配置：$backup。数据未删除；数据库升级后不可盲目降级。"; return 1;
    }
    wait_cloudreve || { echo "启动验证失败；未移除旧 aria2。原配置：$backup"; return 1; }
    remove_owned_aria2 "$aria_id" || return 1
    echo "已更新到 $image；网页绑定 $bind:$port，仅使用内置 aria2。其余环境、端口、网络和兼容挂载保留。原配置：$backup"
    echo "旧下载器容器仅在归属和新服务启动验证通过后移除；全部下载文件保留。"
    show_ports
}
login_dockerhub() {
    command -v docker >/dev/null || { echo "需要 Docker。"; return 1; }
    # 仅用户主动选择时交互登录，不在脚本中保存账号密码。
    docker login docker.io
}
push_custom_image() {
    require_docker && check_layout || return 1
    local source_id
    # 容器的 .Image 是实际不可变镜像 ID，不使用可能已变化的来源标签。
    source_id=$(docker inspect cloudreve --format '{{.Image}}') || {
        echo "未找到 cloudreve 容器；请先安装或恢复启动。"; return 1;
    }
    [[ "$source_id" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "镜像 ID 无效"; return 1; }
    [ "$(docker image inspect "$source_id" --format '{{.Id}}')" = "$source_id" ] || return 1
    echo "仅推送 cloudreve 镜像 $source_id 到 $CUSTOM_IMAGE；不包含挂载数据，不合并或推送 aria2。"
    docker tag "$source_id" "$CUSTOM_IMAGE" && docker push "$CUSTOM_IMAGE" || return 1
    if ! python3 - "$CUSTOM_IMAGE" "$source_id" <<'PYPUSH'
import json, re, subprocess, sys
try:
    def manifest(ref):
        return json.loads(subprocess.check_output(['docker','manifest','inspect',ref]))
    m=manifest(sys.argv[1])
    # 单平台镜像通常是直接 manifest；兼容包含多个平台的索引。
    if 'manifests' in m:
        digests=[]
        for entry in m['manifests']:
            digest=entry['digest']
            if not re.fullmatch(r'sha256:[0-9a-f]{64}',digest): raise ValueError('摘要无效')
            child=manifest(sys.argv[1].split('@')[0]+'@'+digest)
            digests.append(child.get('config',{}).get('digest'))
    else:
        digests=[m.get('config',{}).get('digest')]
    if sys.argv[2] not in digests: raise ValueError('远端 config digest 与实际镜像 ID 不一致')
except (ValueError,KeyError,subprocess.CalledProcessError) as e:
    sys.exit('推送后的远端验证失败：'+str(e))
PYPUSH
    then return 1; fi
    echo "推送完成，已验证远端 config digest：$source_id"
}
uninstall_app() {
    require_docker && check_layout || return 1
    python3 - "$COMPOSE" <<'PYSCOPE'
import json,subprocess,sys
cfg=json.loads(subprocess.check_output(['docker','compose','-f',sys.argv[1],'config','--format','json']))
if not set(cfg['services']).issubset({'cloudreve','aria2'}): sys.exit('存在其他服务，拒绝整套卸载；没有移除任何容器。')
PYSCOPE
    [ "$?" = 0 ] || return 1
    echo "仅移除经验证的 cloudreve 容器；保留 $APP 全部数据、配置、镜像及 /home 备份。"
    local answer aria_id cloud_id
    aria_id=$(owned_aria2) || return 1
    [ -z "$aria_id" ] || echo "检测到已验证归属的旧独立 aria2，将一并移除其容器；下载文件保留。"
    IFS= read -r -p "确认请输入精确小写 yes：" answer || { echo "已取消"; return; }
    [ "$answer" = yes ] || { echo "已取消"; return; }
    # 再次检查，避免确认期间容器/挂载变化；不执行整项目 down 或 remove-orphans。
    check_layout || return 1
    cloud_id=$(docker inspect cloudreve --format '{{.Id}}') || cloud_id=
    if [ -n "$cloud_id" ]; then
        docker rm -f "$cloud_id" || return 1
        if docker inspect "$cloud_id" >/dev/null 2>&1; then echo "卸载验证失败。"; return 1; fi
    fi
    remove_owned_aria2 "$aria_id" || return 1
    echo "Cloudreve 容器已卸载；如有已验证的旧独立 aria2 也已移除。全部数据保留。"
}
main() {
    local choice
    while true; do
        [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
        echo "=================================="
        echo "        cloudreve 网盘服务"
        echo "支持多种云存储的网盘，提供文件管理、分享和在线预览"
        echo "开源地址："
        echo "https://github.com/cloudreve/Cloudreve"
        echo -e "官方镜像：$IMAGE \033[33m（手动指定）\033[0m"
        echo "=================================="
        if docker inspect cloudreve >/dev/null 2>&1; then
            echo -e "安装状态：\033[32m已安装\033[0m"
            show_ports
        else
            echo "安装状态：未安装"
        fi
        echo "------------------------"
        echo "1. 自己安装 $CUSTOM_IMAGE"
        echo "2. 从zaixiangjian更新"
        echo "3. 登录DockerHub"
        echo "4. 打上标签推送到$CUSTOM_IMAGE"
        echo "------------------------"
        echo "9. 卸载（需 yes 确认，保留数据）"
        echo "------------------------"
        echo "11. 官方安装"
        echo "12. 官方更新"
        echo "------------------------"
        echo "0. 退出"
        echo "------------------------"
        IFS= read -r -p "输入你的选择: " choice || break
        case "$choice" in
            1) install_app "$CUSTOM_IMAGE" ;;
            2) update_app "$CUSTOM_IMAGE" ;;
            3) login_dockerhub ;;
            4) push_custom_image ;;
            11) install_app "$IMAGE" ;;
            12) update_app "$IMAGE" ;;
            9) uninstall_app ;;
            0) echo "已退出"; break ;;
            *) echo "选项无效" ;;
        esac
        IFS= read -r -p "按回车继续..." _ || break
    done
}
[[ "${BASH_SOURCE[0]}" != "$0" ]] || main
