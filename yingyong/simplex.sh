#!/usr/bin/env bash
# SimpleX SMP 消息中继管理；不安装网页客户端或 XFTP 文件服务器。
set -uo pipefail
umask 077
APP_DIR=/home/docker/simplex
BACKUP_DIR=/home
PROJECT=simplex
SMP_IMAGE=simplexchat/smp-server:latest
info() { printf '\n%s\n' "$*"; }
fail() { printf '\n错误：%s\n' "$*" >&2; return 1; }
ask() { read -r -p "$1" "$2"; }
compose() { docker compose --project-name "$PROJECT" --project-directory "$APP_DIR" -f "$APP_DIR/compose.yaml" "$@"; }
installed() { [[ -f "$APP_DIR/compose.yaml" && -f "$APP_DIR/.simplex-managed" ]]; }
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
    for ((n=0;n<60;n++)); do
        if compose exec -T smp sh -c 'test -s /etc/opt/simplex/fingerprint && test -s /etc/opt/simplex/smp-server.ini' >/dev/null 2>&1; then
            if python3 - "$APP_DIR/compose.yaml" <<'PY'
import json,socket,sys
c=json.load(open(sys.argv[1])); port=int(c['services']['smp']['ports'][0].split(':')[1])
with socket.create_connection(('127.0.0.1',port),timeout=2): pass
PY
            then return 0; fi
        fi
        sleep 2
    done
    fail 'SMP服务未就绪，请检查 /home/docker/simplex 下 docker compose -p simplex logs --tail=80'
}
show_address() {
    require_install || return 1
    python3 - "$APP_DIR" <<'PY'
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1]); c=json.loads((p/'compose.yaml').read_text())['services']['smp']
fp=(p/'smp/config/fingerprint').read_text().strip(); host=c['environment']['ADDR']; port=c['ports'][0].split(':')[1]
print('客户端服务器地址：smp://'+fp+'@'+host+(':'+port if port!='5223' else ''))
print('若安装时设置密码，请在客户端填写服务器密码；配置文件中保存真实密码。')
PY
}
write_stack() {
    printf '%s\0' "$HOST" "$PORT" "$PASSWORD" | python3 -c '
import json,sys,pathlib
host,port,password=sys.stdin.buffer.read().decode().split("\0")[:-1]
p=pathlib.Path(sys.argv[1]); log={"driver":"json-file","options":{"max-size":"10m","max-file":"3"}}
c={"services":{"smp":{"image":sys.argv[2],"restart":"unless-stopped","environment":{"ADDR":host,"PASS":password,"WEB_MANUAL":"1"},"ports":["0.0.0.0:"+port+":5223"],"volumes":["./smp/config:/etc/opt/simplex","./smp/logs:/var/opt/simplex"],"stop_signal":"SIGINT","stop_grace_period":"120s","logging":log}}}
(p/"compose.yaml").write_text(json.dumps(c,indent=2)+"\n")
(p/".simplex-managed").write_text("simplex-manager-v1\n")
' "$APP_DIR" "$SMP_IMAGE"
}
install_app() {
    require_docker || return 1
    [[ ! -e "$APP_DIR" ]] || { fail '安装目录已存在，不覆盖；已有安装请选择更新。'; return 1; }
    local HOST PORT PASSWORD
    info '部署SMP消息中继；域名需直接解析到可访问的服务器，或通过TCP端口转发。无需申请网站证书，SMP使用自己的证书指纹。'
    ask '公网域名或IPv4地址: ' HOST || return 0
    [[ "$HOST" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && "$HOST" == *.* && "$HOST" != *..* ]] || { fail '地址格式无效。'; return 1; }
    ask '公网/本机TCP端口 [5223]: ' PORT || return 0; PORT=${PORT:-5223}
    [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$PORT <= 65535)) || { fail '端口无效。'; return 1; }
    read -r -s -p '服务器密码（回车不设密码，推荐设置）: ' PASSWORD || { echo; return 0; }; echo
    [[ "$PASSWORD" =~ ^[a-zA-Z0-9_-]*$ ]] || { fail '密码仅使用字母、数字、下划线或短横线。'; return 1; }
    docker pull "$SMP_IMAGE" || return 1
    mkdir -p "$APP_DIR/smp/config" "$APP_DIR/smp/logs" || return 1
    write_stack || return 1
    unset PASSWORD
    compose config -q && compose up -d && wait_ready || return 1
    info '安装完成。请在SimpleX手机/桌面客户端的服务器设置中添加此SMP服务器。'
    show_address
    info '请放行或转发所选TCP端口；Cloudflare普通橙云/HTTP反代不适用。PVE跨虚拟机使用TCP转发而非location代理。'
    info '证书及队列必须备份；ca.key请额外离线妥善保存。此脚本不安装XFTP，客户端仍可使用其他文件服务器。'
}
backup_app() {
    require_install && require_docker || return 1
    mkdir -p "$BACKUP_DIR" || return 1
    local file ids rc=0
    file=$(python3 - "$BACKUP_DIR" <<'PY'
import datetime,os,pathlib,sys,time
for _ in range(100):
    stamp=datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    path=pathlib.Path(sys.argv[1])/f"SimpleX-{stamp}.tar.gz"
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
    info '备份包含消息队列、未投递消息、配置及证书密钥，请妥善保管。正在停止服务保证一致性……'
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
    info '更新前自动备份；保留服务器证书、队列和配置；升级前请查看官方兼容性说明。'
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
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!='simplex': raise ValueError('非法备份路径')
        if not (m.isfile() or m.isdir()) or str(p) in seen: raise ValueError('不允许链接、特殊文件或重复路径')
        seen.add(str(p))
    required={'simplex/compose.yaml','simplex/.simplex-managed','simplex/smp/config/smp-server.ini','simplex/smp/config/fingerprint'}
    if not required <= seen: raise ValueError('不是完整的 SimpleX 备份')
    t.extractall(dest,members=members,numeric_owner=True)
PY
}
restore_app() {
    require_docker || return 1
    local selected confirm stage old='' ids='' path n
    local -a files=()
    mapfile -d '' files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'SimpleX-*.tar.gz' -print0 | sort -zr)
    ((${#files[@]})) || { fail '未发现 /home/SimpleX-*.tar.gz 备份。'; return 1; }
    info '检测到以下备份文件：'
    for n in "${!files[@]}"; do printf '%s. %s\n' "$((n+1))" "${files[n]##*/}"; done
    printf '\n'
    ask '请选择要恢复的备份编号（回车恢复最新备份）: ' selected || { info '已取消恢复。'; return 0; }
    selected=${selected:-1}
    [[ "$selected" == 0 ]] && return 0
    [[ "$selected" =~ ^[1-9][0-9]{0,5}$ ]] && ((selected <= ${#files[@]})) || { fail '编号无效。'; return 1; }
    path=${files[selected-1]}
    info "将恢复：$path；当前数据将保存到 /home/docker/simplex.before_restore.*。只恢复自己生成的可信备份。"
    ask '输入 yes 确认恢复: ' confirm || { info '已取消恢复。'; return 0; }
    [[ "$confirm" == yes ]] || { info '已取消恢复。'; return 0; }
    mkdir -p /home/docker || return 1
    stage=$(mktemp -d /home/docker/.simplex-restore-XXXXXX) || return 1
    cp -- "$path" "$stage/archive.tar.gz" && extract_archive "$stage/archive.tar.gz" "$stage" || { rm -rf -- "$stage"; fail '备份校验或解压失败，原数据未改动。'; return 1; }
    docker compose -p "$PROJECT" --project-directory "$stage/simplex" -f "$stage/simplex/compose.yaml" config -q || { rm -rf -- "$stage"; return 1; }
    if [[ -e "$APP_DIR" ]]; then
        require_install || { rm -rf -- "$stage"; return 1; }
        ids=$(running_ids) || { rm -rf -- "$stage"; return 1; }
        compose stop -t 120 || { restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
        old=$(mktemp -d "${APP_DIR}.before_restore.$(date +%Y%m%d-%H%M%S).XXXXXX") || { restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
        if ! mv -T -- "$APP_DIR" "$old"; then restart_ids "$ids"; rm -rf -- "$stage"; return 1; fi
        chmod 700 "$old" || { mv -T -- "$old" "$APP_DIR"; restart_ids "$ids"; rm -rf -- "$stage"; return 1; }
    fi
    if mv -T -- "$stage/simplex" "$APP_DIR"; then
        if compose up -d --force-recreate && wait_ready; then
            rm -rf -- "$stage"
            info '恢复完成。'; [[ -z "$old" ]] || info "原数据保留：$old"; return 0
        fi
        compose stop -t 120 || { fail "恢复启动失败且无法停止容器，请手动处理；旧数据：$old"; return 1; }
        mv -T -- "$APP_DIR" "$stage/failed-simplex" || { fail "无法移动失败数据；旧数据：$old"; return 1; }
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
    info "卸载将删除本脚本的 SimpleX 容器、网络，以及 $APP_DIR 中全部聊天记录、媒体、数据库和密钥。保留 /home 中备份及共享 Docker 镜像。"
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
    echo "        SimpleX 管理脚本"
    echo "隐私通信的SMP消息中继，无全局用户标识"
    echo "部署组件：SimpleX SMP Server"
    echo "开源地址："
    echo "https://github.com/simplex-chat/simplexmq"
    echo "=================================="
    echo
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份（home目录）"
    echo "4. 恢复（从home/目录获取）"
    echo "5. 查看服务器地址"
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
            5) show_address ;;
            9) uninstall_app ;;
            0) info '已退出'; break ;;
            *) info '无效选项。' ;;
        esac
        read -r -p '按回车继续...' || break
    done
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
