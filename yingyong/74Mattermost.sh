#!/usr/bin/env bash
# Mattermost Team Edition + PostgreSQL；复用已有反向代理。
set -uo pipefail
umask 077
APP_DIR=/home/docker/mattermost
BACKUP_DIR=/home
PROJECT=mattermost
MM_IMAGE=mattermost/mattermost-team-edition:latest
PG_IMAGE=postgres:16-alpine
info() { printf '\n%s\n' "$*"; }
fail() { printf '\n错误：%s\n' "$*" >&2; return 1; }
ask() { read -r -p "$1" "$2"; }
compose() { docker compose --project-name "$PROJECT" --project-directory "$APP_DIR" -f "$APP_DIR/compose.yaml" "$@"; }
installed() { [[ -f "$APP_DIR/compose.yaml" && -f "$APP_DIR/.mattermost-managed" ]]; }
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
    for ((n=0;n<120;n++)); do
        if python3 - "$APP_DIR/compose.yaml" 2>/dev/null <<'PY'
import json,sys,urllib.request
c=json.load(open(sys.argv[1])); port=c['services']['mattermost']['ports'][0].split(':')[1]
with urllib.request.urlopen('http://127.0.0.1:'+port+'/api/v4/system/ping',timeout=4) as r:
    if json.load(r).get('status')!='OK': raise RuntimeError('not ready')
PY
        then return 0; fi
        sleep 2
    done
    fail '服务未就绪，请在 /home/docker/mattermost 执行 docker compose -p mattermost logs --tail=80'
}
write_stack() {
    python3 - "$APP_DIR" "$SITE_URL" "$PORT" "$MM_IMAGE" "$PG_IMAGE" <<'PY'
import pathlib,secrets,json,sys
root,url,port,mm,pg=sys.argv[1:]; p=pathlib.Path(root); password=secrets.token_hex(32)
(p/'.env').write_text('DB_PASSWORD='+password+'\n')
log={'driver':'json-file','options':{'max-size':'10m','max-file':'3'}}
services={
 'postgres':{'image':pg,'restart':'unless-stopped','environment':{'POSTGRES_USER':'mmuser','POSTGRES_PASSWORD':'${DB_PASSWORD}','POSTGRES_DB':'mattermost'},'volumes':['./postgres:/var/lib/postgresql/data'],'healthcheck':{'test':['CMD-SHELL','pg_isready -U mmuser -d mattermost'],'interval':'10s','timeout':'5s','retries':12},'logging':log},
 'mattermost':{'image':mm,'restart':'unless-stopped','depends_on':{'postgres':{'condition':'service_healthy'}},'environment':{'MM_SQLSETTINGS_DRIVERNAME':'postgres','MM_SQLSETTINGS_DATASOURCE':'postgres://mmuser:${DB_PASSWORD}@postgres:5432/mattermost?sslmode=disable&connect_timeout=10','MM_SERVICESETTINGS_SITEURL':url,'MM_BLEVESETTINGS_INDEXDIR':'/mattermost/bleve-indexes'},'ports':['0.0.0.0:'+port+':8065'],'volumes':['./app/'+name+':/mattermost/'+target for name,target in [('config','config'),('data','data'),('logs','logs'),('plugins','plugins'),('client-plugins','client/plugins'),('bleve-indexes','bleve-indexes')]],'logging':log}}
(p/'compose.yaml').write_text(json.dumps({'services':services},indent=2)+'\n')
(p/'.mattermost-managed').write_text('mattermost-manager-v1\n')
PY
}
install_app() {
    require_docker || return 1
    [[ ! -e "$APP_DIR" ]] || { fail '安装目录已存在，不覆盖；请选择更新或先检查旧数据。'; return 1; }
    local SITE_URL PORT uid=2000 gid=2000
    ask '公网HTTPS地址（如 https://mm.example.com）: ' SITE_URL || return 0
    [[ "$SITE_URL" =~ ^https://[a-zA-Z0-9.-]+(:[0-9]+)?/?$ ]] || { fail '请输入无子路径的HTTPS地址。'; return 1; }
    SITE_URL=${SITE_URL%/}
    ask '本机HTTP端口 [8065]: ' PORT || return 0; PORT=${PORT:-8065}
    [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$PORT <= 65535)) || { fail '端口无效。'; return 1; }
    docker pull "$MM_IMAGE" && docker pull "$PG_IMAGE" || return 1
    # 官方镜像使用 UID/GID 2000；精简镜像中没有 id 或 shell。
    [[ "$(docker image inspect "$MM_IMAGE" --format '{{.Config.User}}')" == mattermost ]] || { fail '镜像用户与官方部署约定不符，请检查。'; return 1; }
    mkdir -p "$APP_DIR/postgres" "$APP_DIR/app" || return 1
    local dir
    for dir in config data logs plugins client-plugins bleve-indexes; do mkdir -p "$APP_DIR/app/$dir" || return 1; done
    chown -R "$uid:$gid" "$APP_DIR/app" || return 1
    write_stack || return 1
    compose config -q && compose up -d && wait_ready || return 1
    info "安装完成：$SITE_URL；后端HTTP端口：$PORT。首次打开网页创建系统管理员。"
    info '请将已有nginx反代到此机器内网IP和上述端口，支持WebSocket，并设置Host、X-Forwarded-For、X-Forwarded-Proto。'
    info 'SMTP、注册权限等在Mattermost系统控制台配置；脚本不会修改nginx、证书、防火墙。数据库不对外开放。'
    info '未映射Calls音视频8443端口；需要通话时按官方指南单独配置。建议至少2核/4GB内存。'
}
backup_app() {
    require_install && require_docker || return 1
    mkdir -p "$BACKUP_DIR" || return 1
    local file ids rc=0
    file=$(python3 - "$BACKUP_DIR" <<'PY'
import datetime,os,pathlib,sys,time
for _ in range(100):
    stamp=datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    path=pathlib.Path(sys.argv[1])/f"Mattermost-{stamp}.tar.gz"
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
    info '备份包含数据库、上传文件、插件、配置及凭证，请妥善保管。正在停止服务保证一致性……'
    if ! compose stop -t 120; then
        restart_ids "$ids" || fail '原运行容器恢复失败。'
        rm -f -- "$file"; return 1
    fi
    tar -czf "$file" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" || rc=1
    if ((rc==0)); then chmod 600 "$file" && tar -tzf "$file" >/dev/null || rc=1; fi
    restart_ids "$ids" || { fail '备份后原运行容器未能重启，请检查。'; rc=1; }
    if ((rc!=0)); then info "备份操作失败；临时归档（可能不完整）：$file"; return 1; fi
    LAST_BACKUP=$file
    info "备份完成：$file"
}
update_app() {
    require_install && require_docker || return 1
    info '更新前自动备份；保留数据库、上传文件和配置；升级前请查看官方兼容性说明。'
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
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='mattermost': raise ValueError('非法备份路径')
        if not (m.isfile() or m.isdir()) or str(p) in seen: raise ValueError('不允许链接、特殊文件或重复路径')
        seen.add(str(p))
    required={'mattermost/compose.yaml','mattermost/.mattermost-managed','mattermost/.env'}
    if not required <= seen: raise ValueError('不是完整的 Mattermost 备份')
    t.extractall(dest,members=members,numeric_owner=True)
PY
}
restore_app() {
    require_docker || return 1
    local selected confirm stage old='' ids='' path n
    local -a files=()
    mapfile -d '' files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'Mattermost-*.tar.gz' -print0 | sort -zr)
    ((${#files[@]})) || { fail '未发现 /home/Mattermost-*.tar.gz 备份。'; return 1; }
    info '检测到以下备份文件：'
    for n in "${!files[@]}"; do printf '%s. %s\n' "$((n+1))" "${files[n]##*/}"; done
    printf '\n'
    ask '请选择要恢复的备份编号（回车恢复最新备份）: ' selected || { info '已取消恢复。'; return 0; }
    selected=${selected:-1}
    [[ "$selected" == 0 ]] && return 0
    [[ "$selected" =~ ^[1-9][0-9]{0,5}$ ]] && ((selected <= ${#files[@]})) || { fail '编号无效。'; return 1; }
    path=${files[selected-1]}
    info "将恢复：$path；当前数据将保存到 /home/docker/mattermost.before_restore.*。只恢复自己生成的可信备份。"
    ask '输入 yes 确认恢复: ' confirm || { info '已取消恢复。'; return 0; }
    [[ "$confirm" == yes ]] || { info '已取消恢复。'; return 0; }
    mkdir -p /home/docker || return 1
    stage=$(mktemp -d /home/docker/.mattermost-restore-XXXXXX) || return 1
    cp -- "$path" "$stage/archive.tar.gz" && extract_archive "$stage/archive.tar.gz" "$stage" || { rm -rf -- "$stage"; fail '备份校验或解压失败，原数据未改动。'; return 1; }
    docker compose -p "$PROJECT" --project-directory "$stage/mattermost" -f "$stage/mattermost/compose.yaml" config -q || { rm -rf -- "$stage"; return 1; }
    if [[ -e "$APP_DIR" ]]; then
        require_install || { rm -rf -- "$stage"; return 1; }
        ids=$(running_ids) || { rm -rf -- "$stage"; return 1; }
        compose stop -t 120 || { restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
        old=$(mktemp -d "${APP_DIR}.before_restore.$(date +%Y%m%d-%H%M%S).XXXXXX") || { restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
        if ! mv -T -- "$APP_DIR" "$old"; then restart_ids "$ids"; rm -rf -- "$stage"; return 1; fi
        chmod 700 "$old" || { mv -T -- "$old" "$APP_DIR"; restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
    fi
    if mv -T -- "$stage/mattermost" "$APP_DIR"; then
        if compose up -d --force-recreate && wait_ready; then
            rm -rf -- "$stage"
            info '恢复完成。'; [[ -z "$old" ]] || info "原数据保留：$old"; return 0
        fi
        compose stop -t 120 || { fail "恢复启动失败且无法停止容器，请手动处理；旧数据：$old"; return 1; }
        mv -T -- "$APP_DIR" "$stage/failed-mattermost" || { fail "无法移动失败数据；旧数据：$old"; return 1; }
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
    info "卸载将删除本脚本的 Mattermost 容器、网络，以及 $APP_DIR 中全部聊天记录、媒体、数据库和密钥。保留 /home 中备份及共享 Docker 镜像。"
    ask '输入 yes 确认卸载: ' confirm || { info '已取消卸载。'; return 0; }
    [[ "$confirm" == yes ]] || { info '已取消卸载。'; return 0; }
    require_install && require_docker || return 1
    compose down --remove-orphans || return 1
    rm -rf -- "$APP_DIR" || return 1
    info '卸载完成，备份已保留。'
}
show_menu() {
    if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then clear; fi
    echo "=================================="
    echo "        Mattermost 管理脚本"
    echo "开源团队协作平台，支持频道聊天、文件分享与集成"
    echo "部署组件：Mattermost Team Edition + PostgreSQL"
    echo "开源地址："
    echo "https://github.com/mattermost/mattermost"
    echo "=================================="
    echo
    echo "------------------------"
    echo "出现反复跳转访问/create_team路径创建团队"
    echo "------------------------"
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份（home目录）"
    echo "4. 恢复（从home/目录获取）"
    echo "9. 卸载"
    echo "0. 退出"
    echo
}
main() {
    [[ $EUID -eq 0 ]] || { fail '请以root运行。'; return 1; }
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
            9) uninstall_app ;;
            0) info '已退出'; break ;;
            *) info '无效选项。' ;;
        esac
        read -r -p '按回车继续...' || break
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
