#!/bin/bash

BACKUP_DIR="/home/caddy"
BACKUP_FILE="$BACKUP_DIR/caddy_backup.tar.gz"

CADDY_DATA="/var/lib/caddy/.local/share/caddy"
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
  fi
}

backup_caddy() {
  echo -e "${GREEN}▶️ 开始打包 Caddy...${RESET}"
  mkdir -p "$BACKUP_DIR"

  tar -czvf "$BACKUP_FILE" \
    "$CADDY_CONF" \
    "$CADDY_DATA" \
    "$CADDY_SERVICE" \
    "$CADDY_BIN"

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
echo "1) 打包 Caddy 到 /home/caddy"
echo "2) 解压恢复到系统并设置自启动"
echo "3) 启动 Caddy"
echo "4) 重载配置"
echo "5) 实时日志查看"
echo "6) 查看实时状态"
echo "7) 启动"
echo "8) 停止"
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
  0) exit 0 ;;
  *) die "无效选项" ;;
esac
