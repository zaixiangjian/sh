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
    python3 - "$COMPOSE" "$APP" "${1:-update}" <<'PY'
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
    def normalize_ports(value):
        out=[]
        for key,bindings in value.items():
            for binding in bindings or []:
                ip=binding.get('HostIp','')
                ip='0.0.0.0' if ip=='' else ip
                out.append((key,ip,str(binding['HostPort'])))
        return set(out)
    if sys.argv[3]!='uninstall':
        assert normalize_ports(ports)==normalize_ports(expected_ports), '运行端口与 Compose 不一致（请核对实际绑定与配置）'
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
    require_docker && check_layout uninstall || return 1
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
    # 再次检查，避免确认期间容器/挂载变化；卸载不要求端口与 Compose 一致。
    check_layout uninstall || return 1
    cloud_id=$(docker inspect cloudreve --format '{{.Id}}') || cloud_id=
    if [ -n "$cloud_id" ]; then
        docker rm -f "$cloud_id" || return 1
        if docker inspect "$cloud_id" >/dev/null 2>&1; then echo "卸载验证失败。"; return 1; fi
    fi
    remove_owned_aria2 "$aria_id" || return 1
    echo "Cloudreve 容器已卸载；如有已验证的旧独立 aria2 也已移除。全部数据保留。"
}
# 每个任务独立 watcher/transfer 锁；配置位于应用目录外，不随网盘复制。
TRANSFER_ROOT=/home/docker/wangpan-transfer
TRANSFER_UNITS=/etc/systemd/system
transfer_engine() {
    python3 /dev/fd/3 "$APP" "$TRANSFER_ROOT" "$TRANSFER_UNITS" "$(readlink -f "${BASH_SOURCE[0]}")" "$@" 3<<'PYTRANSFER'
import contextlib,fcntl,getpass,hashlib,json,os,re,shlex,shutil,signal,stat,subprocess,sys,tempfile,time
from pathlib import Path
APP,ROOT,UNITS,SCRIPT=map(Path,sys.argv[1:5]); args=sys.argv[5:]
HEADER='# wangpan 传送任务'; END='# /wangpan 传送任务'
NAME=re.compile(r'[a-z][a-z0-9_-]{0,31}')
os.umask(0o077)
def interrupted(signum,frame):
    # systemd stop / SIGTERM 必须解开临时目录上下文，删除 /run 密码副本。
    raise KeyboardInterrupt
signal.signal(signal.SIGTERM,interrupted)
def call(cmd,**kw):
    return subprocess.run(cmd,stdin=kw.pop('stdin',subprocess.DEVNULL),stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw)
def safe(p):
    p=Path(p)
    if not p.is_absolute() or any(x.is_symlink() for x in (p,*p.parents)): raise ValueError('拒绝符号链接或非绝对路径')
    return p
def private(p,directory=False):
    safe(p); s=p.stat()
    if s.st_uid!=os.geteuid() or stat.S_IMODE(s.st_mode)!=(0o700 if directory else 0o600): raise ValueError('任务文件权限/所有者不安全')
    if not (stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)): raise ValueError('任务文件类型不安全')
def prepare():
    safe(ROOT); safe(APP)
    if ROOT==APP or ROOT.is_relative_to(APP): raise ValueError('任务目录不得位于网盘内')
    if ROOT.exists(): private(ROOT,True)
    else: ROOT.mkdir(mode=0o700,parents=True)
def taskpath(name):
    if not NAME.fullmatch(name): raise ValueError('任务名仅限小写字母开头及字母数字 _ -，最多32字符')
    return safe(ROOT/name)
def destination(value):
    value=value.rstrip('/')
    if not re.fullmatch(r'/(?:home|srv|mnt|opt|data|backup)/(?:[A-Za-z0-9_.-]+/){1,}[A-Za-z0-9_.-]+',value): raise ValueError('目标需为专用绝对目录，至少三级，无空格')
    if any(x in ('.','..') for x in value.split('/')): raise ValueError('拒绝危险目标路径')
    return value
def validate(c,name):
    if c.get('name')!=name or c.get('source')!=str(APP) or c.get('version')!=1: raise ValueError('任务配置不匹配')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:-]{0,252}',c['host']): raise ValueError('SSH 主机无效')
    if not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]{0,31}',c['user']): raise ValueError('SSH 用户无效')
    if type(c['port'])!=int or not 1<=c['port']<=65535: raise ValueError('SSH 端口无效')
    destination(c['dest'])
    if c['auth'] not in ('key','password') or type(c['delete'])!=bool: raise ValueError('任务配置无效')
    if c.get('debounce')!=10 or c.get('poll')!=2: raise ValueError('任务时序无效')
    return c
def load(name):
    prepare(); p=taskpath(name); private(p,True); private(p/'config.json')
    c=validate(json.loads((p/'config.json').read_text()),name)
    for f in ('known_hosts','identity' if c['auth']=='key' else 'password'): private(p/f)
    return c
@contextlib.contextmanager
def lock(p,blocking=False):
    safe(p)
    fd=os.open(p,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    try:
        if os.fstat(fd).st_uid!=os.geteuid() or not stat.S_ISREG(os.fstat(fd).st_mode): raise ValueError('锁文件不安全')
        try: fcntl.flock(fd,fcntl.LOCK_EX|(0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError: yield False
        else: yield True
    finally: os.close(fd)
def atomic(p,obj):
    safe(p)
    fd,tmp=tempfile.mkstemp(prefix='.state-',dir=p.parent)
    try:
        with os.fdopen(fd,'w') as f: json.dump(obj,f,ensure_ascii=True); f.write('\n')
        os.replace(tmp,p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
def fingerprint():
    safe(APP)
    if not APP.is_dir(): raise ValueError('网盘目录不存在；不传送空目录')
    h=hashlib.sha256()
    def scan(p):
        s=p.lstat(); h.update(os.fsencode(str(p.relative_to(APP))))
        h.update(repr((s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns,s.st_ino)).encode())
        if stat.S_ISDIR(s.st_mode):
            with os.scandir(p) as it: entries=sorted(it,key=lambda x:os.fsencode(x.name))
            for e in entries: scan(Path(e.path))
    scan(APP); return h.hexdigest()
# 每次传送仅检查目标绝对路径、目录类型及符号链接，不创建远端标记文件。
REMOTE='''import sys
from pathlib import Path
p=Path(sys.argv[1]); create=sys.argv[2]=='create'
if any(x.is_symlink() for x in (p,*p.parents)): sys.exit('unsafe destination symlink')
if p.exists() and not p.is_dir(): sys.exit('destination is not a directory')
if create: p.mkdir(parents=True,exist_ok=True,mode=0o700)
if not p.is_dir(): sys.exit('destination directory missing')
'''
def remote(c,create=False):
    return 'python3 -c '+shlex.quote(REMOTE)+' '+shlex.quote(c['dest'])+' '+('create' if create else 'check')
@contextlib.contextmanager
def transport(c):
    p=taskpath(c['name'])
    # 密码只通过 sshpass -f 读取，短期副本位于 /run，退出时清理。
    with tempfile.TemporaryDirectory(prefix='wangpan-ssh-',dir='/run') as d:
        opts=['ssh','-F','/dev/null','-p',str(c['port']),'-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(p/'known_hosts'),'-o','GlobalKnownHostsFile=/dev/null','-o','ConnectTimeout=10','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-o','LogLevel=ERROR']
        if c['auth']=='password':
            f=Path(d)/'password'; shutil.copyfile(p/'password',f); f.chmod(0o600)
            opts=['sshpass','-f',str(f)]+opts+['-o','PubkeyAuthentication=no','-o','PreferredAuthentications=password','-o','NumberOfPasswordPrompts=1']
        else: opts+=['-i',str(p/'identity'),'-o','IdentitiesOnly=yes','-o','BatchMode=yes']
        yield opts

def run_task(name):
    c=load(name); p=taskpath(name)
    with lock(p/'transfer.lock') as owned:
        if not owned: return 75
        c=load(name)  # 删除任务与等待锁之间可能已撤销配置，必须重新确认。
        try:
            before=fingerprint()
            with transport(c) as ssh:
                probe=call(ssh+[c['user']+'@'+c['host'],remote(c)+' && command -v rsync >/dev/null'],timeout=40)
                if probe.returncode:
                    raise ValueError('远端预检失败（代码 '+str(probe.returncode)+'）：检查SSH、rsync、目录权限或符号链接')
                host='['+c['host']+']' if ':' in c['host'] else c['host']
                cmd=['rsync','-a','--checksum','--protect-args','--timeout=90','-e',shlex.join(ssh),'--rsync-path='+remote(c)+' && exec rsync']
                if c['delete']: cmd.append('--delete-delay')
                result=call(cmd+['--',str(APP)+'/',c['user']+'@'+host+':'+c['dest']+'/'],timeout=3600)
                if result.returncode: raise ValueError('rsync 失败，代码 '+str(result.returncode))
            after=fingerprint()
            atomic(p/'state.json',{'time':int(time.time()),'ok':True,'result':'已传送（热镜像，非一致性备份）','fingerprint':before,'dirty':before!=after})
            return 0
        except (ValueError,OSError,subprocess.TimeoutExpired) as e:
            atomic(p/'state.json',{'time':int(time.time()),'ok':False,'dirty':True,'result':str(e)})
            print(str(e),file=sys.stderr); return 1
class Debounce:
    def __init__(self): self.last=None; self.changed=None
    def observe(self,value,now):
        if value!=self.last: self.last=value; self.changed=now
        return self.changed is not None and now-self.changed>=10
    def completed(self,ok):
        if ok: self.changed=None

def watch_task(name):
    load(name); p=taskpath(name)
    with lock(p/'watcher.lock') as owned:
        if not owned: return 75
        debounce=Debounce()
        while True:
            load(name)
            try:
                value=fingerprint(); now=time.monotonic()
                if debounce.observe(value,now):
                    try: state=json.loads((p/'state.json').read_text())
                    except (OSError,ValueError): state={}
                    if state.get('ok') and not state.get('dirty') and state.get('fingerprint')==value: debounce.completed(True)
                    else: debounce.completed(run_task(name)==0)
            except (OSError,ValueError): pass
            time.sleep(2)

def names():
    if not ROOT.exists(): return []
    prepare(); out=[]
    for p in sorted(ROOT.iterdir()):
        if NAME.fullmatch(p.name) and p.is_dir():
            try: load(p.name); out.append(p.name)
            except (ValueError,OSError,KeyError): print('忽略不安全/无效任务：'+p.name,file=sys.stderr)
    return out

def cron_rewrite(text,tasks):
    # 精确识别本脚本 CLI 的行。已有其他 cron 标题及其内容绝不消费。
    pattern=re.compile(r'^\*/2 \* \* \* \* '+re.escape(shlex.quote(str(SCRIPT)))+r' --run-task [a-z][a-z0-9_-]{0,31} >/dev/null 2>&1$')
    kept=[]
    for line in text.splitlines():
        if line.strip() in (HEADER,END) or pattern.fullmatch(line): continue
        kept.append(line)
    block=[HEADER]+['*/2 * * * * '+shlex.quote(str(SCRIPT))+' --run-task '+n+' >/dev/null 2>&1' for n in tasks]+[END]
    if tasks:
        if kept and kept[-1]!='': kept.append('')
        kept+=block
    return '\n'.join(kept)+ ('\n' if kept else '')
def repair_cron():
    prepare()
    with lock(ROOT/'.cron.lock',True):
        old=call(['crontab','-l'],text=True)
        if old.returncode and 'no crontab' not in old.stderr.lower(): raise ValueError('无法读取 crontab，未覆盖')
        text=old.stdout if old.returncode==0 else ''; new=cron_rewrite(text,names())
        if new!=text:
            written=call(['crontab','-'],input=new,text=True,stdin=None)
            if written.returncode: raise ValueError('crontab 写入失败')
            verify=call(['crontab','-l'],text=True)
            if verify.returncode or verify.stdout!=new: raise ValueError('crontab 回读不匹配')
def unitname(name):
    taskpath(name); return 'wangpan-transfer-'+name+'.service'
def unittext(name):
    # 固定命令、严格任务名，不从配置拼接 shell 命令；路径含空格也正确转义。
    escaped=str(SCRIPT).replace('\\','\\\\').replace('"','\\"').replace('%','%%')
    return '[Unit]\nDescription=Wangpan transfer watcher '+name+'\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=simple\nUMask=0077\nExecStart=/bin/bash "'+escaped+'" --watch-task '+name+'\nRestart=always\nRestartSec=5\nStandardOutput=null\nStandardError=null\n\n[Install]\nWantedBy=multi-user.target\n'
def systemctl(*a):
    r=call(['systemctl',*a])
    if r.returncode: raise ValueError('systemd 操作失败：'+' '.join(a))
def install_unit(name):
    safe(UNITS); p=safe(UNITS/unitname(name)); body=unittext(name)
    if p.exists() and p.read_text()!=body: raise ValueError('已有同名非本脚本服务，未覆盖')
    if not p.exists():
        with p.open('x') as f: f.write(body)
        p.chmod(0o600)
    if p.read_text()!=body: raise ValueError('服务文件回读失败')
    systemctl('daemon-reload'); systemctl('enable','--now',p.name)
    systemctl('is-enabled',p.name); systemctl('is-active',p.name)
def remove_task(name):
    load(name); p=taskpath(name); unit=safe(UNITS/unitname(name))
    if unit.exists():
        if unit.read_text()!=unittext(name): raise ValueError('拒绝删除非本脚本服务')
        systemctl('disable','--now',unit.name)
        r=call(['systemctl','is-active',unit.name])
        if r.returncode==0: raise ValueError('watcher 未停止，不删除配置')
        unit.unlink(); systemctl('daemon-reload')
    with lock(p/'transfer.lock') as owned:
        if not owned: raise ValueError('任务仍在传送，稍后重试；未删除配置')
        # 先移除配置，使新进程无法启动，然后仅删除已验证任务目录。
        (p/'config.json').unlink(); repair_cron(); shutil.rmtree(p)
    if p.exists(): raise ValueError('删除验证失败')
def ask(prompt): return input(prompt)
def yes(prompt): return ask(prompt)=='yes'
def dependencies():
    for tool in ('ssh','ssh-keyscan','ssh-keygen','systemctl','crontab'):
        if not shutil.which(tool): raise ValueError('缺少依赖 '+tool+'；请先自行安装，不自动安装')
    if not Path('/run/systemd/system').is_dir(): raise ValueError('需要运行中的 systemd 来保证连续监测')
INSTALL_RSYNC = """set -eu
if command -v rsync >/dev/null 2>&1; then exit 0; fi
if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        exec sudo -n sh -c 'SCRIPT_BODY'
    fi
    echo '需要 root 或无密码 sudo 安装 rsync' >&2; exit 77
fi
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y --no-install-recommends rsync
elif command -v dnf >/dev/null 2>&1; then dnf install -y rsync
elif command -v yum >/dev/null 2>&1; then yum install -y rsync
elif command -v apk >/dev/null 2>&1; then apk add rsync
else echo '不支持的包管理器，请手动安装 rsync' >&2; exit 78
fi
command -v rsync >/dev/null
"""
# sudo 子命令只包含固定安装逻辑，避免递归提权。
INSTALL_RSYNC=INSTALL_RSYNC.replace("exec sudo -n sh -c 'SCRIPT_BODY'", "exec sudo -n sh -c "+shlex.quote('if command -v apt-get'+INSTALL_RSYNC.split('if command -v apt-get',1)[1]))
def ensure_local_rsync():
    if shutil.which('rsync'): return
    print('本机缺少 rsync，正在使用系统包管理器安装。')
    r=call(['sh','-c',INSTALL_RSYNC],timeout=900)
    if r.returncode or not shutil.which('rsync'): raise ValueError('本机 rsync 自动安装失败，请检查包管理器/权限/网络')
    print('本机 rsync 已安装并验证。')

def add_task():
    dependencies(); ensure_local_rsync(); prepare()
    print('不停服复制整个 wangpan：SQLite/DB/WAL/SHM 可能不一致，不是可靠备份。变化静默10秒传送，持续变化由每2分钟兜底。')
    if not yes('接受热镜像风险请输入精确 yes：'): return
    name=ask('任务名（小写字母开头）：'); p=taskpath(name)
    if p.exists(): raise ValueError('任务已存在')
    c={'version':1,'name':name,'source':str(APP),'host':ask('SSH 主机/IP：'),'port':int(ask('SSH 端口（22）：') or '22'),'user':ask('SSH 用户（root）：') or 'root','dest':destination(ask('远端目录（回车默认 /home/docker/wangpan/）：') or '/home/docker/wangpan/'),'debounce':10,'poll':2,'delete':False}
    auth=ask('认证 1.密钥 2.密码（1）：') or '1'
    if auth not in ('1','2'): raise ValueError('认证选项无效')
    c['auth']='key' if auth=='1' else 'password'; validate(c,name)
    if c['auth']=='password' and not shutil.which('sshpass'): raise ValueError('密码认证需要 sshpass，请自行安装')
    print('允许目标已有部署或文件，会覆盖同路径文件；请先停止远端 Cloudreve，运行中接收数据库会损坏数据。')
    if not yes('确认目标目录及覆盖范围，远端服务已停止；请输入精确 yes：'): return
    mode=ask('删除远端多余文件？1.不删除（默认） 2.镜像删除：') or '1'
    if mode not in ('1','2'): raise ValueError('删除选项无效')
    if mode=='2':
        print('仅对专用目标 '+c['dest']+' 使用 --delete，删除无法恢复。')
        if not yes('明确同意删除请输入精确 yes：'): return
        c['delete']=True
    # 在认证前展示未信任主机的全部 SHA256 指纹，独立确认。禁止 accept-new/自动 yes。
    scan=call(['ssh-keyscan','-T','10','-p',str(c['port']),c['host']],timeout=35)
    if scan.returncode or not scan.stdout.strip(): raise ValueError('目标离线或无法获取主机密钥；未添加')
    with tempfile.TemporaryDirectory(prefix='wangpan-ssh-',dir='/run') as d:
        kh=Path(d)/'known_hosts'; kh.write_bytes(scan.stdout); kh.chmod(0o600)
        fp=call(['ssh-keygen','-lf',str(kh),'-E','sha256'],text=True)
        if fp.returncode: raise ValueError('主机密钥格式错误')
        print('请通过独立可信渠道核对主机指纹，扫描本身不证明身份：\n'+fp.stdout)
        if not yes('已独立核对上述指纹，信任此主机请输入精确 yes：'): return
        p.mkdir(mode=0o700)
        try:
            shutil.copyfile(kh,p/'known_hosts'); (p/'known_hosts').chmod(0o600)
            if c['auth']=='key':
                key=safe(Path(ask('SSH 私钥绝对路径（需无口令专用密钥）：')))
                if key.is_relative_to(APP) or not key.is_file(): raise ValueError('私钥不得来自网盘目录')
                shutil.copyfile(key,p/'identity'); (p/'identity').chmod(0o600)
            else:
                # getpass 无控制终端时会退回可能回显的 stdin；拒绝该降级。
                tty_fd=os.open('/dev/tty',os.O_RDWR|os.O_NOCTTY)
                try:
                    if not os.isatty(tty_fd): raise ValueError('密码认证需要交互终端')
                    # 不以 r+ 包装终端：Python 会要求流可 seek，TTY 不支持。
                    with os.fdopen(os.dup(tty_fd),'w',encoding='utf-8') as tty_out:
                        password=getpass.getpass('SSH 密码（不回显）：',stream=tty_out)
                finally:
                    os.close(tty_fd)
                if not password or '\n' in password or '\x00' in password: raise ValueError('密码无效')
                (p/'password').write_text(password+'\n'); (p/'password').chmod(0o600); del password
            atomic(p/'config.json',c)
            with transport(c) as ssh:
                target=c['user']+'@'+c['host']
                r=call(ssh+[target,'true'],timeout=40)
                if r.returncode: raise ValueError('SSH 登录失败：请检查密码、SSH端口及认证权限（退出码 '+str(r.returncode)+'）')
                r=call(ssh+[target,'command -v python3 >/dev/null'],timeout=40)
                if r.returncode: raise ValueError('远端缺少 python3，需先安装以校验目录归属')
                r=call(ssh+[target,'command -v rsync >/dev/null'],timeout=40)
                if r.returncode:
                    print('远端缺少 rsync，正在通过 SSH 自动安装（需要 root 或无密码 sudo）。')
                    r=call(ssh+[target,'sh -c '+shlex.quote(INSTALL_RSYNC)],timeout=900)
                    if r.returncode: raise ValueError('远端 rsync 安装失败，请检查 root/sudo、包管理器和网络（退出码 '+str(r.returncode)+'）')
                    print('远端 rsync 安装完成。')
                r=call(ssh+[target,'command -v rsync >/dev/null && '+remote(c,True)],timeout=40)
                if r.returncode:
                    detail=(r.stderr or b'').decode('utf-8',errors='replace').strip()
                    allowed=('destination already owned by another task','destination ownership mismatch','unsafe destination symlink','destination is not a directory','unsafe owner marker')
                    reason=next((x for x in allowed if x in detail),'远端目录权限不足或归属校验未通过')
                    raise ValueError('SSH 登录成功，但目标目录检查失败：'+reason)
        except Exception:
            shutil.rmtree(p); raise
    # 不自动传送；只在用户添加成功后启用 watcher。失败时保留任务方便重试/删除。
    repair_cron(); install_unit(name)
    print('已启用 '+name+'：2秒轮询、静默10秒传送、每2分钟兜底；凭据仅位于 '+str(p))
def list_tasks():
    tasks=names()
    for i,n in enumerate(tasks,1):
        try: state=json.loads((taskpath(n)/'state.json').read_text())
        except (OSError,ValueError): state={}
        active=call(['systemctl','is-active',unitname(n)],text=True).stdout.strip()=='active'
        bad=not active or state.get('ok') is False
        print('\033[32m'+str(i)+'. '+n+'\033[0m'+(' \033[33m异常\033[0m' if bad else ''))
    if not tasks: print('\033[31m暂无\033[0m')
    return tasks
def menu():
    dependencies()
    if ROOT.exists(): repair_cron()
    while True:
        if sys.stdout.isatty() and os.environ.get('TERM','dumb')!='dumb':
            subprocess.run(['clear'],check=False)
        print('==================================')
        print('        定时传送任务')
        print('检测变化静默10秒传送，每2分钟保底；非一致性备份')
        print('------------------------')
        list_tasks()
        print('------------------------')
        print('1. 添加任务\n2. 删除任务\n3. 查看任务\n4. 手动传送\n5. 重试启用 watcher\n0. 返回')
        choice=ask('选择：')
        if choice=='0': return 0
        try:
            if choice=='1': add_task()
            elif choice=='3': list_tasks()
            elif choice in ('2','4','5'):
                tasks=list_tasks()
                if not tasks: continue
                selected=ask('任务编号'+('（回车全部）' if choice=='4' else '')+'：')
                if selected=='' and choice=='4': selected_tasks=tasks
                elif selected.isdecimal() and 1<=int(selected)<=len(tasks): selected_tasks=[tasks[int(selected)-1]]
                else: raise ValueError('编号无效')
                if choice=='2':
                    if yes('只删除任务配置、cron、所属 watcher，不删除远端/网盘数据；确认精确 yes：'): remove_task(selected_tasks[0]); print('已删除任务')
                elif choice=='5': install_unit(selected_tasks[0]); repair_cron(); print('watcher 已启用并验证')
                else:
                    for n in selected_tasks:
                        code=run_task(n); print(n+('：已传送' if code==0 else '：已有传送正在进行' if code==75 else '：失败，参见任务状态'))
            else: print('选项无效')
        except (ValueError,OSError,KeyError,subprocess.TimeoutExpired) as e: print('操作失败：'+str(e))
        ask('按回车继续...')
try:
    action=args[0] if args else 'menu'
    if action=='run': sys.exit(run_task(args[1]))
    elif action=='watch': sys.exit(watch_task(args[1]))
    elif action=='repair': repair_cron()
    elif action=='summary':
        print('定时传送任务')
        list_tasks()
    elif action=='menu': sys.exit(menu())
    else: raise ValueError('未知任务操作')
except (EOFError,KeyboardInterrupt): sys.exit(1)
except (ValueError,OSError,KeyError,IndexError,subprocess.TimeoutExpired) as e:
    print('传送任务失败：'+str(e),file=sys.stderr); sys.exit(1)
PYTRANSFER
}
transfer_menu() { transfer_engine menu; }
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
        transfer_engine summary
        echo "------------------------"
        echo "1. 自己安装 $CUSTOM_IMAGE"
        echo "2. 从zaixiangjian更新"
        echo "3. 登录DockerHub"
        echo "4. 打上标签推送到$CUSTOM_IMAGE"
        echo "5. 自动传送任务"
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
            5) transfer_menu ;;
            11) install_app "$IMAGE" ;;
            12) update_app "$IMAGE" ;;
            9) uninstall_app ;;
            0) echo "已退出"; break ;;
            *) echo "选项无效" ;;
        esac
        IFS= read -r -p "按回车继续..." _ || break
    done
}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    case "${1:-}" in
        --run-task|--watch-task)
            [ "$#" = 2 ] || exit 2
            if [ "$1" = --run-task ]; then transfer_engine run "$2"; else transfer_engine watch "$2"; fi ;;
        --repair-transfer-cron) transfer_engine repair ;;
        "") main ;;
        *) echo "参数无效" >&2; exit 2 ;;
    esac
fi
