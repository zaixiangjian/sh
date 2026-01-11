#!/bin/bash
set -e

BACKUP_DIR="/home/caddy"
BACKUP_FILE="$BACKUP_DIR/caddy_backup.tar.gz"

CADDY_DATA="/var/lib/caddy"
CADDY_BIN="/usr/bin/caddy"
CADDY_SERVICE="/etc/systemd/system/caddy.service"
CADDY_CONF="/etc/caddy"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

die() {
    echo -e "${RED}❌ $1${RESET}"
    exit 1
}

check_root() {
    [ "$EUID" -eq 0 ] || die "请使用 root 运行"
}

install_caddy() {
    echo -e "${GREEN}▶️ 安装 / 修复 Caddy（系统优先，官方二进制备用）...${RESET}"

    if command -v caddy >/dev/null 2>&1; then
        echo "⚙️ 系统已安装 Caddy，使用系统版本"
    else
        echo "⚠️ 未检测到 Caddy，安装官方二进制..."
        apt update
        apt install -y sudo curl ca-certificates

        ARCH="$(dpkg --print-architecture)"
        case "$ARCH" in
            amd64) CADDY_ARCH="amd64" ;;
            arm64) CADDY_ARCH="arm64" ;;
            *) die "不支持架构: $ARCH" ;;
        esac

        echo "📥 下载 Caddy 二进制 (${CADDY_ARCH})..."
        curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o "$CADDY_BIN"
        chmod +x "$CADDY_BIN"
    fi

    # 创建用户和目录
    getent group caddy >/dev/null || groupadd caddy
    id -u caddy >/dev/null 2>&1 || useradd --system --gid caddy --home "$CADDY_DATA" --shell /usr/sbin/nologin caddy

    mkdir -p "$CADDY_CONF" "$CADDY_DATA" /var/log/caddy
    chown -R caddy:caddy "$CADDY_CONF" "$CADDY_DATA" /var/log/caddy
    [ -f "$CADDY_CONF/Caddyfile" ] || touch "$CADDY_CONF/Caddyfile"

    # 创建 systemd 服务（不存在才创建）
    if [ ! -f "$CADDY_SERVICE" ]; then
        cat > "$CADDY_SERVICE" <<EOF
[Unit]
Description=Caddy
After=network.target

[Service]
User=caddy
Group=caddy
ExecStart=$CADDY_BIN run --environ --config $CADDY_CONF/Caddyfile
ExecReload=$CADDY_BIN reload --config $CADDY_CONF/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable caddy
    fi

    systemctl restart caddy
    echo -e "${GREEN}✅ Caddy 安装 / 修复完成${RESET}"
    caddy version
}

backup_caddy() {
    echo -e "${GREEN}▶️ 开始备份 Caddy...${RESET}"
    mkdir -p "$BACKUP_DIR"

    tar -czvf "$BACKUP_FILE" \
        "$CADDY_CONF" \
        "$CADDY_DATA" \
        "$CADDY_SERVICE" \
        "$CADDY_BIN"

    echo -e "${GREEN}✅ 备份完成：$BACKUP_FILE${RESET}"
}

restore_caddy() {
    [ -f "$BACKUP_FILE" ] || die "未找到备份文件 $BACKUP_FILE"
    file "$BACKUP_FILE" | grep -q gzip || die "备份文件不是 gzip 格式"

    echo -e "${GREEN}▶️ 开始恢复 Caddy...${RESET}"
    systemctl stop caddy 2>/dev/null

    TMP_DIR=$(mktemp -d)
    tar -xzvf "$BACKUP_FILE" -C "$TMP_DIR"

    install_caddy

    # 保留本地 Caddy 配置与证书，不覆盖已有文件
    [ -d "$TMP_DIR/etc/caddy" ] && rsync -a --ignore-existing "$TMP_DIR/etc/caddy/" "$CADDY_CONF/"
    [ -d "$TMP_DIR/var/lib/caddy" ] && rsync -a --ignore-existing "$TMP_DIR/var/lib/caddy/" "$CADDY_DATA/"

    chown -R caddy:caddy "$CADDY_CONF" "$CADDY_DATA" /var/log/caddy

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy

    rm -rf "$TMP_DIR"
    echo -e "${GREEN}✅ Caddy 恢复完成${RESET}"
}

reload_caddy() {
    echo -e "${GREEN}▶️ 重载 Caddy 配置...${RESET}"
    systemctl reload caddy || die "Caddy 重载失败"
    echo -e "${GREEN}✅ 配置已重载${RESET}"
}

start_caddy() {
    echo -e "${GREEN}▶️ 启动 Caddy...${RESET}"
    systemctl start caddy || die "Caddy 启动失败"
    systemctl status caddy --no-pager
}

stop_caddy() {
    echo -e "${GREEN}▶️ 停止 Caddy...${RESET}"
    systemctl stop caddy || die "Caddy 停止失败"
    echo -e "${GREEN}✅ Caddy 已停止${RESET}"
}

view_logs() {
    echo -e "${GREEN}▶️ 实时查看 Caddy 日志（Ctrl+C 停止）...${RESET}"
    journalctl -u caddy -f
}

status_caddy() {
    echo -e "${GREEN}▶️ 查看 Caddy 实时状态...${RESET}"
    systemctl status caddy
}

check_root

echo "=============================="
echo " Caddy 一键管理工具"
echo "=============================="
echo "1) 备份 Caddy"
echo "2) 恢复 Caddy（保留本地配置与证书）"
echo "3) 启动 Caddy"
echo "4) 重载配置"
echo "5) 实时日志"
echo "6) 查看状态"
echo "7) 停止 Caddy"
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
    7) stop_caddy ;;
    0) exit 0 ;;
    *) die "无效选项" ;;
esac
