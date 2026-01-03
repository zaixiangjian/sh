#!/bin/bash
set -e

##########################
# 全局变量
##########################

BACKUP_DIR="/home/caddy"
BACKUP_FILE="$BACKUP_DIR/caddy_backup.tar.gz"

CADDY_DATA="/var/lib/caddy/.local/share/caddy"
CADDY_BIN="/usr/bin/caddy"
CADDY_SERVICE="/etc/systemd/system/caddy.service"
CADDY_CONF="/etc/caddy"
CONFIG_FILE="/etc/caddy/Caddyfile"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

##########################
# 公共函数
##########################

die() { echo -e "${RED}❌ $1${RESET}"; exit 1; }
check_root() { [ "$EUID" -eq 0 ] || die "请使用 root 运行"; }

ensure_user() {
    if ! id caddy &>/dev/null; then
        echo "➕ 创建 caddy 用户"
        useradd -r -d /var/lib/caddy -s /usr/sbin/nologin caddy
    fi
}

ensure_service() {
    if [ ! -f "$CADDY_SERVICE" ]; then
        echo -e "${YELLOW}⚠️ 未检测到 caddy.service，正在创建${RESET}"
        cat > "$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy
After=network.target

[Service]
User=caddy
Group=nogroup
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reexec
        systemctl daemon-reload
        systemctl enable caddy
    fi
}

format_and_reload() {
    echo "🧹 格式化配置文件..."
    caddy fmt --overwrite "$CONFIG_FILE" 2>/dev/null || true
    echo "🔁 重载配置..."
    if ! caddy reload --config "$CONFIG_FILE" --adapter caddyfile; then
        echo "⚠️ 重载失败，尝试重启服务..."
        systemctl restart caddy
    fi
    echo "✅ 配置已生效。"
}

##########################
# 备份 / 恢复 / 管理
##########################

backup_caddy() {
    echo -e "${GREEN}▶️ 开始打包 Caddy...${RESET}"
    mkdir -p "$BACKUP_DIR"
    tar -czvf "$BACKUP_FILE" "$CADDY_CONF" "$CADDY_DATA" "$CADDY_SERVICE" "$CADDY_BIN"
    echo -e "${GREEN}✅ 打包完成：$BACKUP_FILE${RESET}"
}

restore_caddy() {
    [ -f "$BACKUP_FILE" ] || die "未找到备份文件 $BACKUP_FILE"
    file "$BACKUP_FILE" | grep -q gzip || die "备份文件不是 gzip 格式"
    echo -e "${GREEN}▶️ 开始恢复 Caddy...${RESET}"
    systemctl stop caddy 2>/dev/null
    mkdir -p /var/lib/caddy
    tar -xzvf "$BACKUP_FILE" -C / || die "解压失败"
    ensure_user
    ensure_service
    chown -R caddy:nogroup /var/lib/caddy
    chmod -R 700 /var/lib/caddy
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable caddy
    echo -e "${GREEN}✅ 恢复完成${RESET}"
}

reload_caddy() { echo -e "${GREEN}▶️ 重载 Caddy 配置...${RESET}"; systemctl reload caddy || die "Caddy 重载失败"; echo -e "${GREEN}✅ 配置已重载${RESET}"; }
start_caddy() { echo -e "${GREEN}▶️ 启动 Caddy...${RESET}"; systemctl start caddy || die "Caddy 启动失败"; systemctl status caddy --no-pager; }
stop_caddy() { echo -e "${GREEN}▶️ 停止 Caddy...${RESET}"; systemctl stop caddy || die "Caddy 停止失败"; echo -e "${GREEN}✅ Caddy 已停止${RESET}"; }
view_logs() { echo -e "${GREEN}▶️ 实时查看 Caddy 日志（Ctrl+C 停止）...${RESET}"; journalctl -u caddy -f; }
status_caddy() { echo -e "${GREEN}▶️ 查看 Caddy 实时状态...${RESET}"; systemctl status caddy; }

update_caddy() {
    echo -e "${GREEN}▶️ 更新 Caddy 到最新版本...${RESET}"
    systemctl stop caddy
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || die "无法进入临时目录"
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
    [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="arm64"
    echo -e "${GREEN}➡️ 下载最新 Caddy...${RESET}"
    curl -sL "https://caddyserver.com/api/download?os=linux&arch=$ARCH&idempotency=$(date +%s)" -o caddy.tar.gz || die "下载失败"
    tar -xzf caddy.tar.gz caddy || die "解压失败"
    chmod +x caddy
    mv caddy /usr/bin/caddy
    cd /
    rm -rf "$TMP_DIR"
    systemctl daemon-reload
    systemctl start caddy
    echo -e "${GREEN}✅ Caddy 已更新到最新版本${RESET}"
}

show_version() {
    echo -e "${GREEN}▶️ 当前 Caddy 版本:${RESET}"
    [ -x "$CADDY_BIN" ] && "$CADDY_BIN" version || echo -e "${RED}Caddy 未安装${RESET}"
}

##########################
# 安装 / 配置 / 反向代理
##########################

install_caddy_official() {
    echo "🔄 安装 Caddy（官方二进制，兼容 Debian）中..."
    apt update
    apt install -y sudo curl ca-certificates
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64) CADDY_ARCH="amd64" ;;
        arm64) CADDY_ARCH="arm64" ;;
        *) die "❌ 不支持的架构: $ARCH" ;;
    esac
    echo "📥 下载 Caddy 二进制 (${CADDY_ARCH})..."
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o /usr/bin/caddy
    chmod +x /usr/bin/caddy
    ensure_user
    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:nogroup /var/lib/caddy /var/log/caddy
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
    ensure_service
    systemctl enable --now caddy
    echo "✅ Caddy 安装完成"
    caddy version
}

add_domain() {
    read -p "请输入域名: " DOMAIN
    read -p "请输入反向代理端口: " PORT
    cat <<EOF >> "$CONFIG_FILE"

$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF
    format_and_reload
}

add_tls_skip_verify() {
    read -p "请输入域名: " DOMAIN
    read -p "请输入反向代理端口: " PORT
    cat <<EOF >> "$CONFIG_FILE"

$DOMAIN {
    reverse_proxy https://127.0.0.1:$PORT {
        transport http {
            tls_insecure_skip_verify
        }
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF
    format_and_reload
}

m3u8yunxing() {
    read -p "请输入域名: " DOMAIN
    cat <<EOF >> "$CONFIG_FILE"

$DOMAIN {
    root * /home/m3u8-app
    file_server
    header Access-Control-Allow-Origin *
}
EOF
    format_and_reload
}

delete_config() {
    if [ ! -f "$CONFIG_FILE" ]; then echo "❌ 找不到配置文件"; return; fi
    mapfile -t BLOCKS < <(awk 'BEGIN{block="";inside=0}/^[^# \t].*{$/{block=$0"\n";inside=1;next}inside==1{block=block $0 "\n";if($0~/^}/){print block;block="";inside=0}}' "$CONFIG_FILE")
    if [ ${#BLOCKS[@]} -eq 0 ]; then echo "⚠️ 没有配置块可删除"; return; fi
    echo "请选择要删除的域名："
    for i in "${!BLOCKS[@]}"; do DOMAIN_LINE=$(echo "${BLOCKS[$i]}" | head -n 1 | sed 's/{.*//;s/ *$//'); echo "$((i+1)). $DOMAIN_LINE"; done
    read -p "请输入序号: " SELECTED; INDEX=$((SELECTED - 1))
    if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#BLOCKS[@]}" ]; then
        DOMAIN_TO_DELETE=$(echo "${BLOCKS[$INDEX]}" | head -n1 | sed 's/{.*//;s/ *$//')
        echo "🗑 正在删除配置域名：$DOMAIN_TO_DELETE"
        awk -v domain="$DOMAIN_TO_DELETE" 'BEGIN{skip=0}{if(skip==0){if($0~domain){skip=1;next}print}else{if($0~/^}/){skip=0;next}}' "$CONFIG_FILE" > /tmp/caddy_tmp && mv /tmp/caddy_tmp "$CONFIG_FILE"
        format_and_reload
    else
        echo "❌ 无效选择"
    fi
}

uninstall_caddy() {
    echo "⚠️ 正在卸载 Caddy..."
    systemctl stop caddy
    apt remove --purge -y caddy
    rm -f "$CONFIG_FILE"
    echo "✅ Caddy 已卸载"
}

restart_caddy() { systemctl restart caddy; echo "✅ Caddy 已重启"; }

##########################
# 菜单
##########################

check_root

while true; do
    echo "=============================="
    echo " Caddy 一键管理工具（融合版）"
    echo "=============================="
    echo "1) 打包 Caddy"
    echo "2) 解压恢复"
    echo "3) 启动 Caddy"
    echo "4) 重载配置"
    echo "5) 实时日志"
    echo "6) 查看实时状态"
    echo "7) 启动"
    echo "8) 停止"
    echo "9) 更新 Caddy"
    echo "10) 查看当前版本"
    echo "21) 安装 Caddy"
    echo "22) 添加普通反向代理"
    echo "23) 添加 TLS Skip Verify 反向代理"
    echo "24) 删除指定域名配置"
    echo "25) 卸载 Caddy"
    echo "88) 添加 M3U8 反代配置"
    echo "0) 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) backup_caddy ;;
        2) restore_caddy ;;
        3) start_caddy ;;
        4) reload_caddy ;;
        5) view_logs ;;
        6) status_caddy ;;
        7) start_caddy ;;
        8) stop_caddy ;;
        9) update_caddy ;;
        10) show_version ;;
        21) install_caddy_official ;;
        22) add_domain ;;
        23) add_tls_skip_verify ;;
        24) delete_config ;;
        25) uninstall_caddy ;;
        88) m3u8yunxing ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项，请重试" ;;
    esac
done
