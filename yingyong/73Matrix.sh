#!/usr/bin/env bash
# Matrix 管理脚本：Synapse + PostgreSQL 16 + Element Web
# 数据目录 /home/docker/matrix；备份 /home/Matrix-时间.tar.gz
set -uo pipefail
umask 077
APP_DIR=/home/docker/matrix
BACKUP_DIR=/home
PROJECT=matrix
SYNAPSE_IMAGE=matrixdotorg/synapse:latest
ELEMENT_IMAGE=vectorim/element-web:latest
PG_IMAGE=postgres:16

info() { printf '\n%s\n' "$*"; }
fail() { printf '\n错误：%s\n' "$*" >&2; return 1; }
ask() { read -r -p "$1" "$2"; }
compose() { docker compose --project-name "$PROJECT" --project-directory "$APP_DIR" -f "$APP_DIR/compose.yaml" "$@"; }
installed() { [[ -f "$APP_DIR/compose.yaml" && -f "$APP_DIR/.matrix-managed" ]]; }
require_install() { installed || fail '尚未安装，或不是本脚本管理的目录。'; }
require_docker() {
    command -v docker >/dev/null || { fail '请先安装 Docker Engine 和 Docker Compose 插件，再运行此脚本。'; return 1; }
    docker info >/dev/null 2>&1 || { fail 'Docker 未运行或无法连接。'; return 1; }
    docker compose version >/dev/null 2>&1 || { fail '缺少 Docker Compose v2 插件。'; return 1; }
}
# 备份后只重启原先正在运行的容器，不启动原先停止的服务。
running_ids() { compose ps -q --status running; }
restart_ids() {
    local ids=$1
    [[ -z "$ids" ]] && return 0
    local -a list=(); mapfile -t list <<< "$ids"
    docker start "${list[@]}" >/dev/null
}
wait_ready() {
    local n
    for ((n=0;n<90;n++)); do
        if compose exec -T synapse python -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8008/_matrix/client/versions", timeout=3)' >/dev/null 2>&1; then
            if compose exec -T element wget -q -O /dev/null http://127.0.0.1:80/ >/dev/null 2>&1; then return 0; fi
        fi
        sleep 2
    done
    fail '服务未就绪，请检查：cd /home/docker/matrix && docker compose -p matrix logs --tail=80'
}
write_stack() {
    python3 - "$APP_DIR" "$SERVER_NAME" "$PUBLIC_URL" "$API_PORT" "$WEB_PORT" "$BIND_IP" "$SYNAPSE_IMAGE" "$ELEMENT_IMAGE" "$PG_IMAGE" <<'PY'
import json,secrets,sys,pathlib
root,server,url,api,web,bind,synapse,element,postgres=sys.argv[1:]
p=pathlib.Path(root); password=secrets.token_hex(32)
(p/'db-password').write_text(password+'\n')
(p/'element').mkdir(exist_ok=True)
(p/'element/config.json').write_text(json.dumps({'default_server_config':{'m.homeserver':{'base_url':url,'server_name':server}},'disable_custom_urls':True,'disable_guests':True,'brand':'Element','default_country_code':'CN'},indent=2)+'\n')
log={'driver':'json-file','options':{'max-size':'10m','max-file':'3'}}
services={
 'postgres':{'image':postgres,'restart':'unless-stopped','environment':{'POSTGRES_USER':'synapse','POSTGRES_DB':'synapse','POSTGRES_PASSWORD_FILE':'/run/secrets/db_password','POSTGRES_INITDB_ARGS':'--encoding=UTF8 --locale=C'},'secrets':['db_password'],'volumes':['./postgres:/var/lib/postgresql/data'],'healthcheck':{'test':['CMD-SHELL','pg_isready -U synapse -d synapse'],'interval':'10s','timeout':'5s','retries':12},'logging':log},
 'synapse':{'image':synapse,'restart':'unless-stopped','environment':{'UID':'991','GID':'991'},'depends_on':{'postgres':{'condition':'service_healthy'}},'ports':[f'{bind}:{api}:8008'],'volumes':['./synapse:/data'],'logging':log},
 'element':{'image':element,'restart':'unless-stopped','ports':[f'{bind}:{web}:80'],'volumes':['./element/config.json:/app/config.json:ro'],'logging':log}}
(p/'compose.yaml').write_text(json.dumps({'services':services,'secrets':{'db_password':{'file':'./db-password'}}},indent=2)+'\n')
(p/'.matrix-managed').write_text('matrix-manager-v1\n')
PY
}
patch_synapse() {
    docker run --rm -i --user 0 --entrypoint python \
        -v "$APP_DIR/synapse:/data" -v "$APP_DIR/db-password:/run/db-password:ro" \
        -e MATRIX_PUBLIC_URL="$PUBLIC_URL" "$SYNAPSE_IMAGE" - <<'PY'
import os,yaml,secrets
path='/data/homeserver.yaml'
with open(path) as f: config=yaml.safe_load(f)
config['database']={'name':'psycopg2','args':{'user':'synapse','password':open('/run/db-password').read().strip(),'database':'synapse','host':'postgres','port':5432,'cp_min':5,'cp_max':10}}
config['public_baseurl']=os.environ['MATRIX_PUBLIC_URL'].rstrip('/')+'/'
config['enable_registration']=False
config['registration_shared_secret']=secrets.token_hex(32)
config['listeners']=[{'port':8008,'tls':False,'type':'http','x_forwarded':True,'bind_addresses':['0.0.0.0'],'resources':[{'names':['client','federation'],'compress':False}]}]
with open(path,'w') as f: yaml.safe_dump(config,f,sort_keys=False)
os.chown(path,991,991)
os.chmod(path,0o600)
PY
}
install_app() {
    require_docker || return 1
    if [[ -e "$APP_DIR" ]]; then fail '安装目录已经存在，不覆盖。已有安装可选更新，失败安装请先检查数据。'; return 1; fi
    info '需要 Matrix 服务域名及可用的 HTTPS 反向代理。服务器名称安装后不能随意更改。'
    ask 'Matrix 服务器域名（如 matrix.example.com）: ' SERVER_NAME || return 1
    [[ "$SERVER_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ && "$SERVER_NAME" == *.* && "$SERVER_NAME" != *..* ]] || { fail '域名格式错误。'; return 1; }
    ask "Matrix 公网 HTTPS 地址 [https://$SERVER_NAME]: " PUBLIC_URL || return 1
    PUBLIC_URL=${PUBLIC_URL:-https://$SERVER_NAME}
    [[ "$PUBLIC_URL" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]] || { fail '请输入不带子路径的 HTTPS 地址。'; return 1; }
    ask 'Synapse 本机端口 [8008]: ' API_PORT || return 1; API_PORT=${API_PORT:-8008}
    ask 'Element 本机端口 [8088]: ' WEB_PORT || return 1; WEB_PORT=${WEB_PORT:-8088}
    local port
    for port in "$API_PORT" "$WEB_PORT"; do
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$port <= 65535)) || { fail '端口必须是 1–65535。'; return 1; }
    done
    [[ "$API_PORT" != "$WEB_PORT" ]] || { fail '两个端口不能相同。'; return 1; }
    ask '端口绑定地址 [127.0.0.1；容器反代可输入 0.0.0.0]: ' BIND_IP || return 1; BIND_IP=${BIND_IP:-127.0.0.1}
    [[ "$BIND_IP" == 127.0.0.1 || "$BIND_IP" == 0.0.0.0 ]] || { fail '只支持 127.0.0.1 或 0.0.0.0。'; return 1; }
    info '开始拉取镜像……'
    docker pull "$SYNAPSE_IMAGE" && docker pull "$ELEMENT_IMAGE" && docker pull "$PG_IMAGE" || return 1
    mkdir -p "$APP_DIR/synapse" || return 1
    write_stack || return 1
    chmod 755 "$APP_DIR/element" && chmod 644 "$APP_DIR/element/config.json" || return 1
    docker run --rm -e SYNAPSE_SERVER_NAME="$SERVER_NAME" -e SYNAPSE_REPORT_STATS=no -v "$APP_DIR/synapse:/data" "$SYNAPSE_IMAGE" generate || return 1
    patch_synapse || return 1
    compose config -q && compose up -d && wait_ready || return 1
    info "安装成功。Synapse：$BIND_IP:$API_PORT；Element：$BIND_IP:$WEB_PORT"
    info '创建首个管理员（密码交互输入，不写进命令行）：'
    compose exec synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008 -a || { fail '管理员创建未完成，可稍后手动执行下方命令。'; }
    info '后续创建用户：cd /home/docker/matrix && docker compose -p matrix exec synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008'
    info '默认关闭公开注册。请将 Matrix HTTPS 域名反代到 Synapse，将另一个 HTTPS 域名反代到 Element。'
    info '反代需传递 Host、X-Forwarded-For、X-Forwarded-Proto，且不要改写 /_matrix 路径。'
    info '本脚本不修改现有 nginx/Caddy/防火墙；跨服务器联邦还需配置 8448 或 /.well-known/matrix/server 委派。未配置 TURN/通话后端。'
}
backup_app() {
    require_install && require_docker || return 1
    mkdir -p "$BACKUP_DIR" || return 1
    local file ids rc=0
    file=$(python3 - "$BACKUP_DIR" <<'PY'
import datetime,os,pathlib,sys,time
for _ in range(100):
    stamp=datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    path=pathlib.Path(sys.argv[1])/f"Matrix-{stamp}.tar.gz"
    try:
        fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    except FileExistsError:
        time.sleep(0.1)
        continue
    os.close(fd)
    print(path)
    break
else:
    raise RuntimeError("无法创建唯一备份文件")
PY
    ) || return 1
    ids=$(running_ids) || { rm -f -- "$file"; return 1; }
    info '备份包含聊天记录、媒体、数据库及密钥，请妥善保管。正在停止服务保证一致性……'
    if ! compose stop -t 120; then
        restart_ids "$ids" || fail '原运行容器恢复失败。'
        rm -f -- "$file"; return 1
    fi
    tar --exclude='matrix/synapse/*.log*' -czf "$file" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" || rc=1
    if ((rc==0)); then chmod 600 "$file" && tar -tzf "$file" >/dev/null || rc=1; fi
    restart_ids "$ids" || { fail '备份后原运行容器未能重启，请检查。'; rc=1; }
    if ((rc!=0)); then info "备份操作失败；临时归档（可能不完整）：$file"; return 1; fi
    LAST_BACKUP=$file
    info "备份完成：$file"
}
update_app() {
    require_install && require_docker || return 1
    info '更新前自动备份；PostgreSQL 固定主版本 16，不自动跨主版本升级。'
    backup_app || return 1
    compose pull && compose up -d && wait_ready || { fail "更新失败；可从 $LAST_BACKUP 恢复。"; return 1; }
    info '更新完成，保留原有配置与数据。'
}
# 仅允许普通文件/目录，拒绝路径穿越、链接、设备和重复路径。
extract_archive() {
    python3 - "$1" "$2" <<'PY'
import pathlib,tarfile,sys
archive,dest=sys.argv[1:]
with tarfile.open(archive,'r:gz') as t:
    members=t.getmembers(); seen=set()
    if not members: raise ValueError('空备份')
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='matrix': raise ValueError('非法备份路径')
        if not (m.isfile() or m.isdir()) or str(p) in seen: raise ValueError('不允许链接、特殊文件或重复路径')
        seen.add(str(p))
    required={'matrix/compose.yaml','matrix/.matrix-managed','matrix/synapse/homeserver.yaml','matrix/db-password','matrix/element/config.json'}
    if not required <= seen: raise ValueError('不是完整的 Matrix 备份')
    t.extractall(dest,members=members,numeric_owner=True)
PY
}
restore_app() {
    require_docker || return 1
    local selected confirm stage old='' ids='' path n
    local -a files=()
    mapfile -d '' files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'Matrix-*.tar.gz' -print0 | sort -zr)
    ((${#files[@]})) || { fail '未发现 /home/Matrix-*.tar.gz 备份。'; return 1; }
    info '检测到以下备份文件：'
    for n in "${!files[@]}"; do printf '%s. %s\n' "$((n+1))" "${files[n]##*/}"; done
    printf '\n'
    ask '请选择要恢复的备份编号（回车恢复最新备份）: ' selected || { info '已取消恢复。'; return 0; }
    selected=${selected:-1}
    [[ "$selected" == 0 ]] && return 0
    [[ "$selected" =~ ^[1-9][0-9]{0,5}$ ]] && ((selected <= ${#files[@]})) || { fail '编号无效。'; return 1; }
    path=${files[selected-1]}
    info "将恢复：$path；当前数据将保存到 /home/docker/matrix.before_restore.*。只恢复自己生成的可信备份。"
    ask '输入 yes 确认恢复: ' confirm || { info '已取消恢复。'; return 0; }
    [[ "$confirm" == yes ]] || { info '已取消恢复。'; return 0; }
    mkdir -p /home/docker || return 1
    stage=$(mktemp -d /home/docker/.matrix-restore-XXXXXX) || return 1
    cp -- "$path" "$stage/archive.tar.gz" && extract_archive "$stage/archive.tar.gz" "$stage" || { rm -rf -- "$stage"; fail '备份校验或解压失败，原数据未改动。'; return 1; }
    docker compose -p "$PROJECT" --project-directory "$stage/matrix" -f "$stage/matrix/compose.yaml" config -q || { rm -rf -- "$stage"; return 1; }
    if [[ -e "$APP_DIR" ]]; then
        require_install || { rm -rf -- "$stage"; return 1; }
        ids=$(running_ids) || { rm -rf -- "$stage"; return 1; }
        compose stop -t 120 || { restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
        old=$(mktemp -d "${APP_DIR}.before_restore.$(date +%Y%m%d-%H%M%S).XXXXXX") || { restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
        if ! mv -T -- "$APP_DIR" "$old"; then restart_ids "$ids"; rm -rf -- "$stage"; return 1; fi
        chmod 700 "$old" || { mv -T -- "$old" "$APP_DIR"; restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
    fi
    if mv -T -- "$stage/matrix" "$APP_DIR"; then
        if compose up -d --force-recreate && wait_ready; then
            rm -rf -- "$stage"
            info '恢复完成。'; [[ -z "$old" ]] || info "原数据保留：$old"; return 0
        fi
        compose stop -t 120 || { fail "恢复启动失败且无法停止容器，请手动处理；旧数据：$old"; return 1; }
        mv -T -- "$APP_DIR" "$stage/failed-matrix" || { fail "无法移动失败数据；旧数据：$old"; return 1; }
    fi
    if [[ -n "$old" ]]; then
        if mv -T -- "$old" "$APP_DIR"; then
            compose up -d --force-recreate || fail '原数据已恢复，但容器未能重启。'
            [[ -n "$ids" ]] || compose stop -t 120
        else fail "回滚失败，旧数据仍在：$old"; fi
    fi
    fail "恢复失败，失败现场保留在：$stage"; return 1
}
uninstall_app() {
    local confirm
    info "卸载将删除本脚本的 Matrix 容器、网络，以及 $APP_DIR 中全部聊天记录、媒体、数据库和密钥。保留 /home 中备份及共享 Docker 镜像。"
    ask '输入 yes 确认卸载: ' confirm || { info '已取消卸载。'; return 0; }
    [[ "$confirm" == yes ]] || { info '已取消卸载。'; return 0; }
    require_install && require_docker || return 1
    compose down --remove-orphans || return 1
    rm -rf -- "$APP_DIR" || return 1
    info '卸载完成，备份已保留。'
}
edit_smtp() {
    require_install && require_docker || return 1
    local host port user password sender mode notifications payload
    info '配置 Synapse SMTP（用于邮箱验证、密码重置和邮件通知）。'
    ask 'SMTP服务器: ' host || return 0
    [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || { fail 'SMTP服务器地址无效。'; return 1; }
    ask 'SMTP端口 [587]: ' port || return 0; port=${port:-587}
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$port <= 65535)) || { fail '端口无效。'; return 1; }
    ask '加密方式：1.STARTTLS  2.SSL/TLS [587默认1，465默认2]: ' mode || return 0
    if [[ -z "$mode" ]]; then mode=1; [[ "$port" != 465 ]] || mode=2; fi
    [[ "$mode" == 1 || "$mode" == 2 ]] || { fail '请选择1或2。'; return 1; }
    ask 'SMTP用户名: ' user || return 0
    read -r -s -p 'SMTP密码/授权码（隐藏输入）: ' password || { echo; return 0; }; echo
    [[ -n "$password" ]] || { fail '密码不能为空。'; return 1; }
    ask '发件邮箱（须为服务商允许的地址）: ' sender || return 0
    [[ "$sender" =~ ^[^[:space:]\<\>]+@[^[:space:]\<\>]+\.[^[:space:]\<\>]+$ ]] || { fail '发件邮箱格式无效。'; return 1; }
    ask '开启邮件通知？[Y/n]: ' notifications || return 0
    case "$notifications" in ''|Y|y) notifications=true ;; N|n) notifications=false ;; *) fail '请输入Y或N。'; return 1 ;; esac
    # JSON通过标准输入传递，不把密码放在进程参数或日志中。
    payload=$(printf '%s\0' "$host" "$port" "$user" "$password" "$sender" "$mode" "$notifications" | python3 -c 'import sys,json; v=sys.stdin.buffer.read().decode().split("\0")[:-1]; print(json.dumps(v))') || return 1
    unset password
    apply_smtp "$payload"
}
apply_smtp() {
    local payload=$1 backup
    backup=$(printf '%s' "$payload" | compose exec -T synapse python -c '
import json,sys,os,tempfile,subprocess,shutil,yaml
values=json.load(sys.stdin)
path="/data/homeserver.yaml"
with open(path) as f: config=yaml.safe_load(f)
if values == ["registration", "off"]:
    config["enable_registration"]=False
elif values == ["registration", "email"]:
    if not (config.get("email") or {}).get("smtp_host"):
        raise RuntimeError("请先配置SMTP")
    config["enable_registration"]=True
    config["enable_registration_without_verification"]=False
    config["registrations_require_3pid"]=["email"]
    config["registration_requires_token"]=False
elif values == ["registration", "open"]:
    config["enable_registration"]=True
    config["enable_registration_without_verification"]=True
    config["registrations_require_3pid"]=[]
    config["registration_requires_token"]=False
    config["enable_registration_captcha"]=False
elif values == ["delete"]:
    config.pop("email",None)
else:
    host,port,user,password,sender,mode,notifications=values
    email=dict(config.get("email") or {})
    email.update(smtp_host=host,smtp_port=int(port),smtp_user=user,smtp_pass=password,notif_from="Matrix <"+sender+">",app_name="Matrix",enable_tls=True,require_transport_security=True,force_tls=mode=="2",enable_notifs=notifications=="true")
    config["email"]=email
fd,candidate=tempfile.mkstemp(prefix=".smtp-candidate-",suffix=".yaml",dir="/data")
try:
    with os.fdopen(fd,"w") as f: yaml.safe_dump(config,f,sort_keys=False)
    result=subprocess.run([sys.executable,"-m","synapse.config","-c",candidate],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if result.returncode: raise RuntimeError("SMTP配置校验失败，原配置未修改")
    fd,backup=tempfile.mkstemp(prefix="homeserver.before_smtp-",suffix=".yaml",dir="/data"); os.close(fd)
    shutil.copyfile(path,backup); os.chmod(backup,0o600)
    stat=os.stat(path); os.chown(candidate,stat.st_uid,stat.st_gid); os.chmod(candidate,0o600)
    os.replace(candidate,path)
    print(backup)
except Exception:
    print("SMTP配置写入或校验失败，未输出凭证，请检查原配置及权限。",file=sys.stderr); sys.exit(1)
finally:
    if os.path.exists(candidate): os.unlink(candidate)
') || { unset payload; return 1; }
    [[ "$backup" == /data/homeserver.before_smtp-*.yaml ]] || { fail '无法确认配置备份路径。'; return 1; }
    if compose restart synapse && wait_ready; then
        info "配置已保存并加载。原配置备份：$APP_DIR/synapse/${backup##*/}"
        if [[ "$payload" == *'"registration"'* ]]; then
            info '注册设置已更新，已有用户不受影响。'
            return 0
        fi
        if [[ "$payload" != '["delete"]' ]]; then
            info '尚未实际发送邮件；请在Element中绑定邮箱或测试密码重置验证投递。'
        fi
        info '公开注册设置保持不变。'
        return 0
    fi
    info '启动检查失败，尝试恢复原配置……'
    python3 - "$APP_DIR/synapse/${backup##*/}" "$APP_DIR/synapse/homeserver.yaml" <<'PY'
import os,sys,shutil,tempfile
source,target=sys.argv[1:]; stat=os.stat(target)
fd,path=tempfile.mkstemp(prefix='.smtp-rollback-',dir=os.path.dirname(target)); os.close(fd)
shutil.copyfile(source,path); os.chown(path,stat.st_uid,stat.st_gid); os.chmod(path,0o600); os.replace(path,target)
PY
    if [[ $? != 0 ]]; then fail "回滚失败，请从 ${backup##*/} 手动恢复。"; return 1; fi
    compose restart synapse && wait_ready || fail '原配置已恢复，但服务仍未就绪。'
    fail 'SMTP配置未通过启动检查，已恢复原配置。'
}

configure_smtp() {
    require_install && require_docker || return 1
    local option configured confirm
    while true; do
        configured=$(compose exec -T synapse python -c 'import yaml; c=yaml.safe_load(open("/data/homeserver.yaml")); print("yes" if (c.get("email") or {}).get("smtp_host") else "no")') || return 1
        echo
        echo "SMTP配置管理"
        if [[ "$configured" == yes ]]; then echo "当前状态：已配置"; else echo "当前状态：未配置"; fi
        echo "1. 添加SMTP配置"
        echo "2. 修改SMTP配置"
        echo "3. 删除SMTP配置"
        echo "0. 返回"
        ask '请输入选项: ' option || return 0
        case "$option" in
            1)
                if [[ "$configured" == yes ]]; then info '已有SMTP配置，请选择2修改。'; else edit_smtp; fi
                ;;
            2)
                if [[ "$configured" != yes ]]; then info '尚未配置SMTP，请选择1添加。'; else info '请重新填写SMTP信息，密码隐藏输入；其他email选项保留。'; edit_smtp; fi
                ;;
            3)
                if [[ "$configured" != yes ]]; then info '没有SMTP配置可删除。'; continue; fi
                info '删除整个email配置块，停用SMTP验证、密码重置邮件和通知。原配置将备份（包含凭证），不删除其他配置。'
                ask '输入 yes 确认删除SMTP配置: ' confirm || return 0
                if [[ "$confirm" == yes ]]; then apply_smtp '["delete"]'; else info '已取消删除。'; fi
                ;;
            0) return 0 ;;
            *) info '无效选项。' ;;
        esac
    done
}

registration_status() {
    if ! installed; then echo '未安装'; return 0; fi
    local status
    status=$(compose exec -T synapse python -c 'import yaml; c=yaml.safe_load(open("/data/homeserver.yaml")); print("允许注册" if c.get("enable_registration",False) else "不允许")' 2>/dev/null) || status='状态未知'
    echo "$status"
}
registration_menu_line() {
    local status
    status=$(registration_status)
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        case "$status" in
            允许注册) echo -e "6. 用户与注册管理（\033[31m允许注册\033[0m）" ;;
            不允许) echo -e "6. 用户与注册管理（\033[32m不允许\033[0m）" ;;
            *) echo "6. 用户与注册管理（$status）" ;;
        esac
    else echo "6. 用户与注册管理（$status）"; fi
}
manage_users() {
    require_install && require_docker || return 1
    local option mode confirm
    while true; do
        echo
        echo "用户与注册管理（$(registration_status)）"
        echo "1. 创建普通用户"
        echo "2. 创建管理员"
        echo "3. 允许注册"
        echo "4. 禁止注册"
        echo "0. 返回"
        ask '请输入选项: ' option || return 0
        case "$option" in
            1) compose exec synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008 --no-admin ;;
            2) compose exec synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008 --admin ;;
            3)
                echo "1. 邮箱验证注册（需先配置SMTP，推荐）"
                echo "2. 无验证公开注册（有机器人滥用风险）"
                echo "0. 返回"
                ask '请选择注册方式 [1]: ' mode || return 0
                mode=${mode:-1}
                case "$mode" in
                    1) mode=email ;;
                    2) mode=open; info '警告：将取消邮箱验证、注册令牌和验证码限制，任何人都可注册。' ;;
                    0) continue ;;
                    *) info '无效选项。'; continue ;;
                esac
                ask '输入 yes 确认允许注册: ' confirm || return 0
                if [[ "$confirm" == yes ]]; then apply_smtp "[\"registration\", \"$mode\"]"; else info '已取消。'; fi
                ;;
            4)
                ask '输入 yes 确认禁止公开注册（不影响已有账号）: ' confirm || return 0
                if [[ "$confirm" == yes ]]; then apply_smtp '["registration", "off"]'; else info '已取消。'; fi
                ;;
            0) return 0 ;;
            *) info '无效选项。' ;;
        esac
    done
}

show_menu() {
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then
        clear
    fi

    echo "=================================="
    echo "        Matrix 管理脚本"
    echo "开源去中心化聊天服务，支持私聊、群组及端到端加密"
    echo "部署组件：Synapse + PostgreSQL + Element Web"
    echo "开源地址："
    echo "https://github.com/element-hq/synapse"
    echo "https://github.com/element-hq/element-web"
    echo "=================================="
    echo
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份（home目录）"
    echo "4. 恢复（从home/目录获取）"
    echo "5. 配置SMTP"
    registration_menu_line
    echo "9. 卸载"
    echo "0. 退出"
    echo
}
main() {
    [[ $EUID -eq 0 ]] || { fail '请以 root 运行。'; return 1; }
    local cmd option
    for cmd in python3 tar mktemp; do command -v "$cmd" >/dev/null || { fail "缺少依赖：$cmd"; return 1; }; done
    while true; do
        show_menu
        ask '请输入选项: ' option || break
        case "$option" in
            1) install_app ;;
            2) update_app ;;
            3) backup_app ;;
            4) restore_app ;;
            5) configure_smtp ;;
            6) manage_users ;;
            9) uninstall_app ;;
            0) info '已退出'; break ;;
            *) info '无效选项。' ;;
        esac
        read -r -p '按回车继续...' || break
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
