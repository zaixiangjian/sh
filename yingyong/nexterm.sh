#!/usr/bin/env bash
# Nexterm 单文件独立管理器；所有函数和Python逻辑内嵌，无外部脚本依赖。
# 新环境需Linux/Bash、root、可用软件源和镜像仓库；不修改kejilion.sh。
set -uo pipefail
NAME="nexterm"
DATA_DIR="/home/docker/nexterm"
KEY_FILE="/home/docker/.nexterm-encryption-key"
BACKUP_DIR="/home/备份/nexterm"
SEARCH_DIRS=("/home/备份/nexterm" "/home/备份" "/home")
OFFICIAL_IMAGE="nexterm/aio:latest"
CUSTOM_IMAGE="zaixiangjian/aio:latest"
BIND_IP="127.0.0.1"
PORT="6989"
LOCK_FILE="/home/docker/.nexterm.lock"
RETENTION_FILE="/home/备份/nexterm/config/local-retention.json"
error() { echo "错误：$*" >&2; }
exists() { docker container inspect "$NAME" >/dev/null 2>&1; }
running() { [[ $(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null) == true ]]; }
locked() (
    local cmd
    for cmd in docker python3 tar flock openssl; do command -v "$cmd" >/dev/null || { error "请先安装 $cmd"; exit 1; }; done
    docker info >/dev/null 2>&1 || { error "Docker 不可用。"; exit 1; }
    umask 077
    mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || { error "其他 Nexterm 操作正在执行。"; exit 1; }
    "$@"
)
select_port() {
    local address port
    while true; do
        IFS= read -r -p "绑定地址（127.0.0.1 或 0.0.0.0，回车默认127.0.0.1）：" address || return 1
        address=${address:-127.0.0.1}
        case "$address" in 127.0.0.1|0.0.0.0) break ;; *) error "地址无效。" ;; esac
    done
    while true; do
        IFS= read -r -p "本地端口（回车默认6989）：" port || return 1
        port=${port:-6989}
        if [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )); then PORT=$((10#$port)); break; fi
        error "端口必须为1–65535。"
    done
    BIND_IP=$address
    echo "端口映射：$BIND_IP:$PORT -> 容器6989"
    if [[ $BIND_IP == 0.0.0.0 ]]; then echo "提示：监听所有IPv4网卡，请配置防火墙和访问控制。"; fi
    return 0
}
verify_container() {
    local i
    for i in 1 2 3; do running || return 1; sleep 1; done
    [[ $(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$NAME") != unhealthy ]]
}
run_container() {
    docker run -d --name "$NAME" --env-file "$1" --restart always -p "$BIND_IP:$PORT:6989" -v "$DATA_DIR:/app/data" "$2" || return 1
    verify_container
}
# 归档、密钥和容器配置只在私有文件中处理，不打印环境凭据。
helper() {
    python3 - "$@" <<'PY'
import sys,os,json,pathlib,tarfile,time,shutil
mode=sys.argv[1]
if mode=='env':
    key=pathlib.Path(sys.argv[2]).read_text().strip()
    if not key or '\n' in key or '\r' in key: raise ValueError('密钥无效')
    pathlib.Path(sys.argv[3]).write_text('ENCRYPTION_KEY='+key+'\n'); os.chmod(sys.argv[3],0o600)
elif mode=='config':
    c=json.load(open(sys.argv[2]))[0]; out=sys.argv[3]; data=sys.argv[4]
    mounts=c.get('Mounts',[])
    if len(mounts)!=1 or mounts[0].get('Type')!='bind' or mounts[0].get('Source')!=data or mounts[0].get('Destination')!='/app/data' or not mounts[0].get('RW'):
        raise ValueError('不支持现有挂载，拒绝重建')
    h=c['HostConfig']
    ports=h.get('PortBindings') or {}
    if set(ports)!={'6989/tcp'} or len(ports['6989/tcp'])!=1: raise ValueError('不支持现有端口映射')
    if h.get('NetworkMode') not in ('default','bridge') or h.get('Privileged') or h.get('CapAdd') or h.get('Devices'):
        raise ValueError('不支持现有网络或额外权限配置')
    nets=c.get('NetworkSettings',{}).get('Networks',{})
    if set(nets)-{'bridge'}: raise ValueError('不支持额外Docker网络')
    env=c['Config'].get('Env') or []
    if not any(x.startswith('ENCRYPTION_KEY=') for x in env) or any('\n' in x or '\r' in x for x in env): raise ValueError('不支持现有密钥或环境变量')
    if any(x.startswith('SERVER_PORT=') and x!='SERVER_PORT=6989' for x in env): raise ValueError('不支持修改过的内部SERVER_PORT')
    pathlib.Path(out).write_text('\n'.join(env)+'\n'); os.chmod(out,0o600)
    p=ports['6989/tcp'][0]; restart=h['RestartPolicy']['Name']
    if restart=='on-failure' and h['RestartPolicy'].get('MaximumRetryCount'): restart+=':'+str(h['RestartPolicy']['MaximumRetryCount'])
    print(p.get('HostIp') or '0.0.0.0'); print(p['HostPort']); print(restart)
elif mode=='list':
    found=[]
    for root in sys.argv[2:]:
        if not os.path.isdir(root): continue
        found.extend(p for p in pathlib.Path(root).glob('nexterm-*.tar.gz') if p.is_file() and not p.is_symlink())
    for p in sorted(set(found),key=lambda p:(p.stat().st_mtime_ns,p.name),reverse=True): sys.stdout.buffer.write(os.fsencode(p)+b'\0')
elif mode=='reserve':
    while True:
        p=os.path.join(sys.argv[2],'nexterm-'+time.strftime('%Y%m%d%H%M%S')+'.tar.gz')
        try:
            fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600); os.close(fd); print(p); break
        except FileExistsError: time.sleep(1)
elif mode=='extract':
    with tarfile.open(sys.argv[2],'r:gz') as t:
        seen=set(); members=t.getmembers()
        for m in members:
            p=pathlib.PurePosixPath(m.name)
            if p.is_absolute() or '..' in p.parts or '\\' in m.name or not(m.isdir() or m.isfile()) or m.mode & 0o7000: raise ValueError('归档含危险路径、链接、特殊文件或特殊权限')
            if str(p) in seen: raise ValueError('重复路径')
            seen.add(str(p))
        # 全部成员已在上方校验；兼容发行版自带的Python3，不依赖filter新接口。
        t.extractall(sys.argv[3],members=members)
    root=pathlib.Path(sys.argv[3])
    if (root/'data').is_dir() and (root/'encryption-key').is_file():
        if set(p.name for p in root.iterdir())!={'data','encryption-key'}: raise ValueError('备份结构无效')
        print('new')
    else: print('legacy')
elif mode=='copy':
    shutil.copytree(sys.argv[2],sys.argv[3],dirs_exist_ok=True,symlinks=False)
else: raise ValueError('未知操作')
PY
}
install_app() (
    local image=$1 work
    exists && { error "容器已存在，请使用更新选项。"; exit 1; }
    [[ ! -d $DATA_DIR || -z $(python3 -c 'import os,sys; print("yes" if os.listdir(sys.argv[1]) else "")' "$DATA_DIR") ]] || { error "已有数据，禁止生成新密钥覆盖；请使用恢复。"; exit 1; }
    select_port || exit 0
    docker pull "$image" || exit 1
    work=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-install.XXXXXX") || exit 1
    trap 'rm -rf -- "$work"' EXIT
    openssl rand -hex 32 > "$work/key" || exit 1
    helper env "$work/key" "$work/env" || exit 1
    mkdir -p "$DATA_DIR" || exit 1
    run_container "$work/env" "$image" || { error "启动失败，请查看 docker logs $NAME；原密钥可从容器环境配置找回。"; exit 1; }
    echo "安装完成，映射：$BIND_IP:$PORT -> 6989"
    echo "加密密钥不保存只显示一次（请妥善保管）"
    # 不另存持久密钥文件；Docker 仍会保存运行所需的环境变量。
    local displayed_key
    IFS= read -r displayed_key < "$work/key" || { error "读取密钥失败。"; exit 1; }
    printf '%s\n' "$displayed_key"
)
manual_backup() {
    configure_local_retention && backup_app
}
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
files=sorted((p for p in root.iterdir() if re.fullmatch(r'nexterm-\d{14}\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name,reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
backup_app() (
    local work archive complete=0 restart=0
    exists && [[ -d $DATA_DIR ]] || { error "容器或数据目录不存在。"; exit 1; }
    work=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-backup.XXXXXX") || exit 1
    trap 'rm -rf -- "$work"' EXIT
    docker inspect "$NAME" > "$work/inspect.json" || exit 1
    helper config "$work/inspect.json" "$work/env" "$DATA_DIR" >/dev/null || exit 1
    mkdir -p "$BACKUP_DIR" || exit 1
    archive=$(helper reserve "$BACKUP_DIR") || exit 1
    running && restart=1
    cleanup() {
        local rc=$?
        trap - EXIT INT TERM HUP
        rm -rf -- "$work"
        (( complete )) || rm -f -- "$archive"
        if (( restart )); then docker start "$NAME" >/dev/null && verify_container || { error "备份后重启失败。"; rc=1; }; fi
        exit "$rc"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    (( ! restart )) || docker stop -t 30 "$NAME" >/dev/null || exit 1
    helper copy "$DATA_DIR" "$work/data" || exit 1
    tar -czf "$archive" -C "$work/data" . || exit 1
    complete=1
    prune_local_backups || { error "备份成功，但本地保留清理失败。"; exit 1; }
    echo "备份完成：$archive（仅应用数据，不含加密密钥，权限0600）"
    echo "恢复必须输入原ENCRYPTION_KEY，请与备份分开妥善保管；未加密字段仍可读取。"
)
update_app() (
    local image=$1 work old rollback failed restart=0
    local -a config=()
    exists || { error "尚未安装。"; exit 1; }
    work=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-update.XXXXXX") || exit 1
    trap 'rm -rf -- "$work"' EXIT
    docker inspect "$NAME" > "$work/inspect.json" || exit 1
    helper config "$work/inspect.json" "$work/env" "$DATA_DIR" > "$work/config" || exit 1
    mapfile -t config < "$work/config"
    BIND_IP=${config[0]}; PORT=${config[1]}
    docker pull "$image" || exit 1
    old="$NAME-before-update-$(date +%Y%m%d%H%M%S)-$$"
    rollback=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-before-update.XXXXXX") || exit 1
    running && restart=1
    docker stop -t 30 "$NAME" >/dev/null || exit 1
    if ! helper copy "$DATA_DIR" "$rollback"; then (( ! restart )) || docker start "$NAME" >/dev/null; exit 1; fi
    if ! docker rename "$NAME" "$old"; then (( ! restart )) || docker start "$NAME" >/dev/null; exit 1; fi
    if docker run -d --name "$NAME" --env-file "$work/env" --restart "${config[2]}" -p "$BIND_IP:$PORT:6989" -v "$DATA_DIR:/app/data" "$image" && verify_container; then
        docker rm "$old" >/dev/null || { error "旧容器清理失败：$old"; exit 1; }
        echo "更新完成：$image；保留原端口、环境变量、密钥和重启策略。"
        echo "更新前数据保留：$rollback"
    else
        if exists; then docker rm -f "$NAME" >/dev/null || { error "失败容器无法移除，原数据：$rollback"; exit 1; }; fi
        failed=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-failed-update.XXXXXX") || exit 1
        mv -T "$DATA_DIR" "$failed" && mv -T "$rollback" "$DATA_DIR" || { error "回滚失败，请保留 $rollback 和 $failed"; exit 1; }
        docker rename "$old" "$NAME" || exit 1
        (( ! restart )) || docker start "$NAME" >/dev/null
        error "更新失败，已恢复原数据与容器；失败数据：$failed"; exit 1
    fi
)
restore_app() (
    local -a files=()
    local choice confirm file work format staged image old rollback failed key_source legacy_key had=0 restart=0
    mapfile -d '' -t files < <(helper list "${SEARCH_DIRS[@]}")
    (( ${#files[@]} )) || { echo "无可用备份。"; exit 0; }
    echo "可用备份（最新优先）："
    local i
    for i in "${!files[@]}"; do printf '%s. %s\n' "$((i+1))" "${files[$i]}"; done
    IFS= read -r -p "请选择备份编号（回车最新，0取消）：" choice || exit 0
    choice=${choice:-1}; [[ $choice != 0 ]] || exit 0
    [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#files[@]} )) || { error "编号无效。"; exit 1; }
    file=${files[$((choice-1))]}
    select_port || exit 0
    echo "恢复 $file 到 $DATA_DIR，替换现有数据并重建容器。"
    IFS= read -r -p "输入小写 yes 确认恢复：" confirm || exit 0
    [[ $confirm == yes ]] || { echo "已取消。"; exit 0; }
    work=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-restore.XXXXXX") || exit 1
    trap 'rm -rf -- "$work"' EXIT
    cp "$file" "$work/archive.tar.gz" || exit 1
    mkdir "$work/extracted" || exit 1
    format=$(helper extract "$work/archive.tar.gz" "$work/extracted") || { error "归档安全校验失败。"; exit 1; }
    if [[ $format == new ]]; then
        staged="$work/extracted/data"
        key_source="$work/extracted/encryption-key"
        helper env "$key_source" "$work/env" || exit 1
    else
        staged="$work/extracted"
        IFS= read -r -s -p "该备份不含密钥，请输入原始ENCRYPTION_KEY：" legacy_key || exit 0
        echo
        [[ -n $legacy_key ]] || { error "未输入原密钥。"; exit 1; }
        key_source="$work/legacy-key"
        printf '%s\n' "$legacy_key" > "$key_source"
        helper env "$key_source" "$work/env" || exit 1
    fi
    image=$OFFICIAL_IMAGE
    if exists; then
        had=1; running && restart=1
        docker inspect "$NAME" > "$work/inspect.json" || exit 1
        helper config "$work/inspect.json" "$work/old-env" "$DATA_DIR" >/dev/null || exit 1
        image=$(docker inspect -f '{{.Config.Image}}' "$NAME") || exit 1
        # 原版旧镜像恢复改用官方AIO；自用镜像保留对应来源。
        [[ $image != germannewsmaker/nexterm:* ]] || image=$OFFICIAL_IMAGE
    fi
    docker pull "$image" || exit 1
    rollback=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-before-restore.XXXXXX") || exit 1
    old="$NAME-before-restore-$(date +%Y%m%d%H%M%S)-$$"
    if (( had )); then
        docker stop -t 30 "$NAME" >/dev/null || exit 1
        docker rename "$NAME" "$old" || { (( ! restart )) || docker start "$NAME" >/dev/null; exit 1; }
    fi
    if [[ -d $DATA_DIR ]]; then
        mv -T "$DATA_DIR" "$rollback" || { (( ! had )) || docker rename "$old" "$NAME"; (( ! restart )) || docker start "$NAME" >/dev/null; exit 1; }
    fi
    if ! mv -T "$staged" "$DATA_DIR"; then
        mv -T "$rollback" "$DATA_DIR"
        (( ! had )) || docker rename "$old" "$NAME"
        (( ! restart )) || docker start "$NAME" >/dev/null
        exit 1
    fi
    if run_container "$work/env" "$image"; then
        (( ! had )) || docker rm "$old" >/dev/null || { error "恢复完成但旧容器清理失败：$old"; exit 1; }
        cp "$key_source" "$KEY_FILE" && chmod 600 "$KEY_FILE" || error "密钥文件保存失败，容器中的密钥仍在。"
        echo "恢复成功，映射：$BIND_IP:$PORT -> 6989；原数据：$rollback"
    else
        if exists; then docker rm -f "$NAME" >/dev/null || { error "失败容器无法移除，原数据：$rollback"; exit 1; }; fi
        failed=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-failed-restore.XXXXXX") || exit 1
        mv -T "$DATA_DIR" "$failed" && mv -T "$rollback" "$DATA_DIR" || { error "回滚失败，请保留 $rollback 和 $failed"; exit 1; }
        (( ! had )) || docker rename "$old" "$NAME"
        (( ! restart )) || docker start "$NAME" >/dev/null
        error "恢复失败，已尝试恢复原数据和原容器；失败数据：$failed"; exit 1
    fi
)
uninstall_app() {
    local confirm work
    echo "删除容器 $NAME、数据目录 $DATA_DIR 和密钥文件；保留备份、镜像、脚本及Docker。"
    IFS= read -r -p "输入小写 yes 确认卸载：" confirm || return 0
    [[ $confirm == yes ]] || { echo "已取消。"; return 0; }
    if exists; then
        work=$(mktemp -d "$(dirname "$DATA_DIR")/.nexterm-check.XXXXXX") || return 1
        docker inspect "$NAME" > "$work/inspect.json" && helper config "$work/inspect.json" "$work/env" "$DATA_DIR" >/dev/null || { rm -rf "$work"; return 1; }
        rm -rf "$work"
        docker rm -f "$NAME" || return 1
    fi
    rm -rf -- "$DATA_DIR" && rm -f -- "$KEY_FILE" || return 1
    echo "卸载完成，备份保留。"
}
login_hub() { docker login --username zaixiangjian; }
push_image() {
    local source confirm id remote
    echo "仅推送镜像，不包含数据或运行时密钥；目标：$CUSTOM_IMAGE"
    IFS= read -r -p "输入小写 yes 确认覆盖目标标签：" confirm || return 0
    [[ $confirm == yes ]] || { echo "已取消。"; return 0; }
    if exists; then source=$(docker inspect -f '{{.Image}}' "$NAME") || return 1
    else docker pull "$OFFICIAL_IMAGE" || return 1; source=$OFFICIAL_IMAGE; fi
    docker tag "$source" "$CUSTOM_IMAGE" && docker push "$CUSTOM_IMAGE" || return 1
    id=$(docker image inspect -f '{{.Id}}' "$CUSTOM_IMAGE") || return 1
    remote=$(docker manifest inspect "$CUSTOM_IMAGE") || { error "推送后远端验证失败。"; return 1; }
    printf '%s' "$remote" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("config",{}).get("digest")==sys.argv[1] else 1)' "$id" || { error "远端镜像摘要不匹配。"; return 1; }
    echo "单平台镜像已推送，远端摘要验证通过：$CUSTOM_IMAGE"
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
REMOTE_DIR="/home/备份/nexterm/config"
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
            dest=valid(ask('远端专用备份目录','/home/备份/nexterm'))
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
            prefix=valid(ask('桶内专用备份前缀','备份/nexterm')).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                keep=ask('S3远端备份保留数量','3')
                if keep.isdigit() and 1<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入1–100000的正整数。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份nexterm时间戳归档')
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
        d=load(); files=[x for x in backups.glob('nexterm-*.tar.gz') if x.is_file() and not x.is_symlink()]
        if not files: print('暂无归档，等待新备份。'); sys.exit(0)
        f=max(files,key=lambda x:x.stat().st_mtime_ns)
        if not re.fullmatch(r'nexterm-\d{14}\.tar\.gz',f.name): raise ValueError('归档名无效')
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
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(r'nexterm-\d{14}\.tar\.gz',x.get('Path',''))],reverse=True)
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
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != '# Nexterm managed remote backup' ]]; then error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" "${AIR_TASK_NAME:-}" <<'PY'
import sys,pathlib
unit,script,kind,calendar,task_name=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
remote_args=('--remote-task '+task_name+' '+kind) if task_name else ('--remote '+kind)
service_content=('# Nexterm managed remote backup\n[Unit]\nDescription=Nexterm remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' '+remote_args+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# Nexterm managed remote backup\n[Unit]\nDescription=Nexterm daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
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
    logger=logging.getLogger('nexterm'); logger.setLevel(logging.INFO); logger.addHandler(h)
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
        if ! locked backup_app; then backup_event_log "$kind" "本地备份失败"; return 1; fi
        backup_event_log "$kind" "本地备份完成（不含密钥）" || return 1
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
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { echo "该目标正在传送，本次跳过。"; exit 0; }
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


remote_summary() { named_summary "${1:-all}"; }

show_menu() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "=================================="
    echo "        Nexterm - 基于 Web 的终端访问工具"
    echo "功能介绍: 使用浏览器远程访问主机终端，支持加密会话与多用户协作"
    echo "开源地址："
    echo "https://github.com/gnmyt/Nexterm"
    echo "=================================="
    named_summary all
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份/home/备份/nexterm/"
    echo "4. 恢复"
    echo "5. SSH 远程备份配置"
    echo "6. S3 API 兼容备份配置"
    echo "9. 卸载"
    echo "21. 自己安装zaixiangjian/aio:latest"
    echo "22. 从zaixiangjian更新"
    echo "23. 登录 Docker Hub"
    echo "24. 打上标签推送到zaixiangjian/aio:latest"
    echo "0. 退出"
}
# 菜单入口仅补齐基础工具；Docker仅在1/21安装与4恢复入口准备。
ensure_environment() {
    local mode=${1:-base} manager cmd docker_missing=0
    local -a packages=()
    if command -v apt-get >/dev/null; then manager=apt
    elif command -v dnf >/dev/null; then manager=dnf
    elif command -v yum >/dev/null; then manager=yum
    elif command -v apk >/dev/null; then manager=apk
    elif command -v pacman >/dev/null; then manager=pacman
    elif command -v zypper >/dev/null; then manager=zypper
    else error "不支持的包管理器，请手动安装 Docker、Python3、tar、util-linux、openssl。"; return 1; fi
    for cmd in python3 tar flock openssl; do
        if ! command -v "$cmd" >/dev/null; then
            case "$cmd" in
                python3) if [[ $manager == pacman ]]; then packages+=(python); else packages+=(python3); fi ;;
                flock) packages+=(util-linux) ;;
                *) packages+=("$cmd") ;;
            esac
        fi
    done
    if [[ $mode == install ]] && ! command -v docker >/dev/null; then
        docker_missing=1
        case "$manager" in
            apt) packages+=(docker.io) ;;
            *) packages+=(docker) ;;
        esac
    fi
    if [[ $mode == remote ]]; then
        command -v rclone >/dev/null || packages+=(rclone)
        if ! command -v ssh-keyscan >/dev/null || ! command -v ssh-keygen >/dev/null; then
            case "$manager" in apt) packages+=(openssh-client) ;; apk) packages+=(openssh-client) ;; *) packages+=(openssh) ;; esac
        fi
    fi
    if (( ${#packages[@]} )); then
        echo "正在安装缺失环境：${packages[*]}"
        case "$manager" in
            apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || return 1 ;;
            dnf|yum) "$manager" install -y "${packages[@]}" || return 1 ;;
            apk) apk add --no-cache "${packages[@]}" || return 1 ;;
            pacman) pacman -Syu --needed --noconfirm "${packages[@]}" || return 1 ;;
            zypper) zypper --non-interactive install "${packages[@]}" || return 1 ;;
        esac
    fi
    for cmd in python3 tar flock openssl; do
        command -v "$cmd" >/dev/null || { error "$cmd 安装后仍不可用，请检查软件源。"; return 1; }
    done
    if [[ $mode == install ]] && ! command -v docker >/dev/null; then
        error "Docker安装后仍不可用，请检查软件源是否提供Docker软件包。"; return 1;
    fi
    if [[ $mode == install ]] && ! docker info >/dev/null 2>&1; then
        echo "正在启动 Docker 服务..."
        if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
            systemctl start docker || { error "Docker 启动失败。"; return 1; }
            if (( docker_missing )); then systemctl enable docker || return 1; fi
        elif command -v rc-service >/dev/null; then
            rc-service docker start || return 1
            if (( docker_missing )); then rc-update add docker default || return 1; fi
        elif command -v service >/dev/null; then
            service docker start || return 1
        else error "无法管理 Docker 服务，请手动启动 Docker。"; return 1; fi
        docker info >/dev/null 2>&1 || { error "Docker 服务启动后仍不可用。"; return 1; }
    fi
    if [[ $mode == remote ]]; then
        for cmd in rclone ssh-keyscan ssh-keygen; do command -v "$cmd" >/dev/null || { error "传送工具$cmd不可用"; return 1; }; done
    fi
    mkdir -p "$(dirname "$DATA_DIR")" || return 1
    return 0
}

AI_APP_ID='nexterm'
AI_APP_LABEL='Nexterm'
delete_remote_task() {
    local kind="$1"
    remote_schedule_unlocked "$kind" remove || return 1
    remote_engine delete "$kind"
}
single_configuration_locked() (
    local kind="$1"; shift
    umask 077
    mkdir -p "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || exit 1
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { error '该任务正在执行，未修改配置。'; exit 1; }
    "$@"
)
remote_schedule() { configuration_locked "$1" remote_schedule_unlocked "$@"; }
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
repremote_schedules() {
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
    ensure_environment || return 1
    repremote_schedules
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
                if ! named_task_available "$name"; then continue; fi
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
import os,sys,stat,fcntl
from pathlib import Path
p=Path(sys.argv[1]); held=[]
try:
    if p.is_symlink(): raise ValueError('配置目录是链接，拒绝使用')
    if not p.exists(): sys.exit(0)
    if not p.is_dir(): raise ValueError('配置路径不是目录')
    for f in p.iterdir():
        if f.name not in ('configuration.lock','ssh.lock','ssh-backup.lock','s3.lock'):
            raise ValueError('此应用已有同名配置或未完成配置文件，未覆盖；请在本应用菜单检查/删除任务')
        fd=os.open(f,os.O_RDWR|os.O_NOFOLLOW);held.append(fd)
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1: raise ValueError('锁文件不安全')
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: sys.exit('同名任务正在配置或执行，请稍后重试')
except (ValueError,OSError) as e: sys.exit(str(e))
finally:
    for fd in held: os.close(fd)
PY_AVAILABLE
}

named_configure() {
    local kind="$1"
    # Recheck while holding the task configuration/transfer locks; never overwrite another creator.
    if [[ -e "$REMOTE_DIR/ssh.json" || -e "$REMOTE_DIR/ssh.conf" || -e "$REMOTE_DIR/ssh-backup.json" || -e "$REMOTE_DIR/ssh-backup.conf" || -e "$REMOTE_DIR/s3.json" || -e "$REMOTE_DIR/s3.conf" ]]; then
        error '本应用同名任务配置已存在，未覆盖。'; return 1
    fi
    if [ "$kind" = ssh-backup ]; then configure_local_retention || return 1; fi
    remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    remote_schedule_unlocked "$kind" enable
}



main() {
    [[ $EUID == 0 ]] || { error "请使用root或sudo运行。"; return 1; }
    ensure_environment || { error "环境准备失败，未执行应用操作。"; return 1; }
    repair_remote_schedules
    local choice
    while true; do
        show_menu
        IFS= read -r -p "请输入选项：" choice || { echo "已退出"; return 0; }
        case "$choice" in
            1) ensure_environment install && locked install_app "$OFFICIAL_IMAGE" ;;
            2) locked update_app "$OFFICIAL_IMAGE" ;;
            3) locked manual_backup ;;
            4) ensure_environment install && locked restore_app ;;
            5) remote_menu ssh; continue ;;
            6) remote_menu s3; continue ;;
            9) locked uninstall_app ;;
            21) ensure_environment install && locked install_app "$CUSTOM_IMAGE" ;;
            22) locked update_app "$CUSTOM_IMAGE" ;;
            23) locked login_hub ;;
            24) locked push_image ;;
            0) echo "已退出"; return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." _ || { echo "已退出"; return 0; }
    done
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} == --remote-task ]]; then
        remote_locked_run "${3:-}@${2:-}" "${4:-}"
        exit $?
    fi
    if [[ ${1:-} == --remote ]]; then
        [[ ${2:-} == ssh-backup || ${2:-} == ssh || ${2:-} == s3 ]] || exit 1
        remote_locked_run "$2" "${3:-}"
    else main "$@"; fi
fi




