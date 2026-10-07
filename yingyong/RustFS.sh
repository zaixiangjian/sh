#!/usr/bin/env bash
# RustFS 单机 Docker 管理；不会操作现有 MinIO。
set -o pipefail
APP_DIR=/home/docker/rustfs
NAME=rustfs
IMAGE=rustfs/rustfs:latest

pause() { read -r -p "按回车继续..." _; }
require_docker() {
    command -v docker >/dev/null && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || {
        echo "缺少可用的 Docker / Docker Compose，请先安装并启动。"; return 1;
    }
}
installed() { [ -f "$APP_DIR/compose.yaml" ] && [ -f "$APP_DIR/runtime.env" ]; }
confirm() {
    local answer
    IFS= read -r -p "确认请输入小写 yes：" answer || return 1
    [ "$answer" = yes ]
}
compose() { docker compose -p rustfs -f "$APP_DIR/compose.yaml" "$@"; }
healthy() {
    local i
    for i in {1..60}; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]; then
            sleep 1; continue
        fi
        if docker exec "$NAME" sh -c 'curl -fsS http://127.0.0.1:9000/health >/dev/null && curl -fsS http://127.0.0.1:9001/rustfs/console/health >/dev/null' 2>/dev/null; then return 0; fi
        sleep 1
    done
    echo "健康检查未通过，请选择日志查看；不等同于安装成功。"
    return 1
}
addresses() {
    local api console
    api=$(docker port "$NAME" 9000/tcp 2>/dev/null)
    console=$(docker port "$NAME" 9001/tcp 2>/dev/null)
    echo "S3 API：http://$api"
    echo "管理控制台：http://$console/rustfs/console/"
    echo "若绑定 0.0.0.0，请将地址中的 0.0.0.0 换成服务器 IP。"
    echo "若绑定 127.0.0.1，需本机访问、SSH 隧道或反向代理。"
    echo "凭证保存在：$APP_DIR/runtime.env（仅 root 可读）"
}
port_input() {
    local label="$1" default="$2" value
    read -r -p "$label（回车 $default）：" value >&2 || return 1
    value=${value:-$default}
    [[ "$value" =~ ^[0-9]{1,5}$ ]] && ((10#$value >= 1 && 10#$value <= 65535)) || { echo "端口无效" >&2; return 1; }
    python3 - "$value" <<'PY'
import socket,sys
s=socket.socket()
try: s.bind(('0.0.0.0',int(sys.argv[1])))
except OSError: sys.exit('端口已占用，取消安装')
finally: s.close()
PY
    [ $? -eq 0 ] || return 1
    printf '%s' "$value"
}
install() {
    require_docker || return 1
    if [ -e "$APP_DIR" ] || docker container inspect "$NAME" >/dev/null 2>&1; then
        echo "目录或同名容器已存在，不覆盖。已有安装请选更新。"; return 1
    fi
    local api console bind access secret
    api=$(port_input "API 端口" 9100) || return 1
    console=$(port_input "控制台端口" 9101) || return 1
    [ "$api" != "$console" ] || { echo "两个端口不能相同"; return 1; }
    read -r -p "绑定 IPv4（回车 127.0.0.1，仅本机；公网访问填 0.0.0.0）：" bind || return 1
    bind=${bind:-127.0.0.1}
    python3 - "$bind" <<'PY'
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
    [ $? -eq 0 ] || return 1
    access=$(openssl rand -hex 16) || return 1
    secret=$(openssl rand -hex 24) || return 1
    docker pull "$IMAGE" || return 1
    umask 077
    mkdir -p "$APP_DIR/data" "$APP_DIR/logs" || return 1
    chown 10001:10001 "$APP_DIR/data" "$APP_DIR/logs" || return 1
    chmod 750 "$APP_DIR/data" "$APP_DIR/logs"
    printf 'RUSTFS_ACCESS_KEY=%s\nRUSTFS_SECRET_KEY=%s\nRUSTFS_CONSOLE_ENABLE=true\nRUSTFS_OBS_LOG_DIRECTORY=/logs\n' "$access" "$secret" > "$APP_DIR/runtime.env"
    cat > "$APP_DIR/compose.yaml" <<EOF
services:
  rustfs:
    image: $IMAGE
    container_name: rustfs
    restart: unless-stopped
    env_file:
      - runtime.env
    ports:
      - "$bind:$api:9000"
      - "$bind:$console:9001"
    volumes:
      - ./data:/data
      - ./logs:/logs
    command: ["/data"]
EOF
    compose config --quiet && compose up -d || return 1
    healthy || return 1
    echo "安装完成，单机单盘不提供磁盘冗余，请另做备份。"
    echo "管理员账号：$access"
    echo "管理员密码：$secret"
    addresses
}
backup() {
    installed || { echo "尚未安装"; return 1; }
    require_docker || return 1
    local file running=no rc=0
    file=$(python3 - <<'PY'
import os,time,datetime
while True:
 p='/home/RustFS-'+datetime.datetime.now().strftime('%Y%m%d%H%M%S')+'.tar.gz'
 try:
  fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd);print(p);break
 except FileExistsError: time.sleep(1)
PY
    ) || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] && running=yes
    if [ "$running" = yes ]; then
        compose stop --timeout 30 || { rm -f -- "$file"; return 1; }
    fi
    tar --exclude='./logs' -czf "$file" -C "$APP_DIR" . && tar -tzf "$file" >/dev/null || rc=1
    if [ "$running" = yes ]; then compose start && healthy || rc=1; fi
    if [ "$rc" -eq 0 ]; then
        echo "备份完成：$file（包含账号密码，请妥善保管）"
    else
        echo "备份或恢复运行失败，检查文件与容器状态：$file"; return 1
    fi
}
update() {
    installed || { echo "尚未安装"; return 1; }
    require_docker || return 1
    backup || return 1
    compose pull && compose up -d && healthy || { echo "更新失败，保留备份，请检查日志。"; return 1; }
    echo "更新完成"; addresses
}
restore() {
    require_docker || return 1
    local files=() file choice i=1 stage old
    mapfile -t files < <(python3 - <<'PY'
from pathlib import Path
for p in sorted(Path('/home').glob('RustFS-*.tar.gz'),reverse=True):
 if p.is_file() and not p.is_symlink(): print(p)
PY
    )
    [ ${#files[@]} -gt 0 ] || { echo "没有检测到备份"; return 1; }
    echo "检测到以下备份文件："
    for file in "${files[@]}"; do echo "$i. ${file##*/}"; ((i++)); done
    read -r -p "请选择要恢复的备份编号（回车恢复最新备份，0 取消）：" choice || return 1
    choice=${choice:-1}
    [ "$choice" = 0 ] && return 0
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le ${#files[@]} ] || { echo "编号无效"; return 1; }
    file=${files[choice-1]}
    echo "将停止 RustFS 并替换 $APP_DIR，备份：${file##*/}"
    confirm || { echo "已取消"; return 0; }
    stage=$(mktemp -d /home/docker/rustfs.restore.XXXXXX) || return 1
    if ! python3 - "$file" "$stage" <<'PY'
import tarfile,sys,pathlib
with tarfile.open(sys.argv[1]) as t:
 for m in t.getmembers():
  p=pathlib.PurePosixPath(m.name)
  if p.is_absolute() or '..' in p.parts or not (m.isfile() or m.isdir()):
   raise ValueError('拒绝危险归档成员: '+m.name)
 t.extractall(sys.argv[2],filter='data')
p=pathlib.Path(sys.argv[2])
for name in ['compose.yaml','runtime.env','data']:
 if not (p/name).exists(): raise ValueError('归档缺少 '+name)
PY
    then rm -rf -- "$stage"; return 1; fi
    # 只接受本管理器生成的 compose，防止恢复任意外部挂载或特权服务。
    if ! docker compose -f "$stage/compose.yaml" config --format json | python3 -c 'import json,sys; x=json.load(sys.stdin); s=x["services"]; assert set(s)=={"rustfs"}; r=s["rustfs"]; assert r["image"]=="rustfs/rustfs:latest" and r["container_name"]=="rustfs"; assert not r.get("privileged") and not r.get("network_mode"); assert set(v["target"] for v in r["volumes"])=={"/data","/logs"}; assert all(v["source"].startswith(sys.argv[1]+"/") for v in r["volumes"])' "$stage"; then
        echo "恢复配置校验失败"; rm -rf -- "$stage"; return 1
    fi
    if docker container inspect "$NAME" >/dev/null 2>&1; then
        installed || { echo "存在非本脚本管理的同名容器，取消"; rm -rf -- "$stage"; return 1; }
        compose stop --timeout 30 || return 1
    fi
    old=$(mktemp -d /home/docker/rustfs.before_restore.XXXXXX) || return 1
    if [ -d "$APP_DIR" ]; then
        mv -T "$APP_DIR" "$old" || return 1
    fi
    if ! mv -T "$stage" "$APP_DIR"; then
        [ -f "$old/compose.yaml" ] && mv -T "$old" "$APP_DIR" && compose start
        return 1
    fi
    mkdir -p "$APP_DIR/logs"
    chmod 600 "$APP_DIR/runtime.env"
    chown -R 10001:10001 "$APP_DIR/data" "$APP_DIR/logs"
    if compose up -d && healthy; then
        echo "恢复完成；恢复前目录保留：$old"
    else
        echo "恢复后启动失败，保留恢复前目录：$old；不要删除，请检查日志。"; return 1
    fi
}
uninstall() {
    installed || { echo "尚未安装"; return 1; }
    require_docker || return 1
    echo "将删除 RustFS 容器和 $APP_DIR 全部数据；保留 /home 备份及 Docker。"
    confirm || { echo "已取消"; return 0; }
    compose down || return 1
    rm -rf -- "$APP_DIR"
    echo "已卸载，备份保留。"
}
main() {
    [ "$(id -u)" -eq 0 ] || { echo "请以 root 运行"; return 1; }
    for tool in python3 openssl tar; do command -v "$tool" >/dev/null || { echo "缺少依赖：$tool"; return 1; }; done
    while true; do
        [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
        echo "=================================="
        echo "        RustFS 管理脚本"
        echo "单机 Docker S3 对象存储，与 MinIO 独立"
        echo "开源地址："
        echo "https://github.com/rustfs/rustfs"
        echo "=================================="
        echo
        echo "1. 安装（默认端口 9100/9101）"
        echo "2. 更新"
        echo "3. 备份（home目录）"
        echo "4. 恢复（从home/目录获取）"
        echo "5. 状态与地址"
        echo "6. 查看日志"
        echo "9. 卸载"
        echo "0. 退出"
        echo
        read -r -p "请输入选项：" choice || break
        case "$choice" in
            1) install ;;
            2) update ;;
            3) backup ;;
            4) restore ;;
            5) docker ps -a --filter name='^/rustfs$'; addresses ;;
            6) docker logs --tail 100 "$NAME" ;;
            9) uninstall ;;
            0) echo "已退出"; return 0 ;;
            *) echo "无效选项" ;;
        esac
        pause || break
    done
}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
