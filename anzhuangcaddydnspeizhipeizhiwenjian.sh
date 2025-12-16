#!/bin/bash
# Caddy + Cloudflare DNS 一键管理脚本
# 适用于 Debian / Ubuntu

set -e

CADDY_BIN="/usr/local/bin/caddy"
CADDY_DIR="/etc/caddy"
CADDY_FILE="$CADDY_DIR/Caddyfile"
SERVICE_FILE="/etc/systemd/system/caddy.service"

color_ok='\033[32m'
color_err='\033[31m'
color_info='\033[36m'
color_end='\033[0m'

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${color_err}请使用 root 运行脚本${color_end}"
    exit 1
  fi
}

# =========================
# 自动显示 Caddyfile 配置
# =========================
show_caddy_config() {
  echo "=============================="
  echo " Caddy 当前配置 ($CADDY_FILE)"
  echo "=============================="

  if [ -f "$CADDY_FILE" ] && [ -s "$CADDY_FILE" ]; then
    sed 's/^/  /' "$CADDY_FILE"
  else
    echo "  ⚠️ 暂无配置（文件不存在或为空）"
  fi

  echo "=============================="
}

# =========================
# 添加 Cloudflare API
# =========================
add_api() {
  echo -e "${color_info}添加 Cloudflare API 环境变量${color_end}"
  read -p "请输入变量名（默认 CF_API_TOKEN）：" api_name
  api_name=${api_name:-CF_API_TOKEN}

  read -p "请输入 API Token（必填）：" api_value
  if [ -z "$api_value" ]; then
    echo -e "${color_err}API Token 不能为空${color_end}"
    return
  fi

  sed -i "/^export $api_name=/d" /etc/profile 2>/dev/null || true
  echo "export $api_name=\"$api_value\"" >> /etc/profile
  export "$api_name=$api_value"

  echo -e "${color_ok}已添加环境变量 $api_name${color_end}"
}

# =========================
# 添加反向代理配置
# =========================
add_reverse_proxy() {
  echo -e "${color_info}添加反向代理配置${color_end}"

  read -p "请输入域名和端口（如 www.123.com:2053）：" domain_port
  [ -z "$domain_port" ] && echo "不能为空" && return

  read -p "反代地址（默认 127.0.0.1）：" proxy_host
  proxy_host=${proxy_host:-127.0.0.1}

  read -p "反代端口（必填）：" proxy_port
  [ -z "$proxy_port" ] && echo "不能为空" && return

  mkdir -p "$CADDY_DIR"

  cat >> "$CADDY_FILE" <<'EOF'

DOMAIN_PLACEHOLDER {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy PROXY_PLACEHOLDER {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF

  sed -i \
    -e "s|DOMAIN_PLACEHOLDER|$domain_port|" \
    -e "s|PROXY_PLACEHOLDER|$proxy_host:$proxy_port|" \
    "$CADDY_FILE"

  systemctl restart caddy || true
  echo -e "${color_ok}反向代理已添加${color_end}"
}

# =========================
# 创建 / 重建 systemd 服务
# =========================
create_service() {
  echo -e "${color_info}创建 caddy systemd 服务${color_end}"

  read -p "API 变量名（默认 CF_API_TOKEN）：" api_name
  api_name=${api_name:-CF_API_TOKEN}

  read -p "API Token：" api_value
  [ -z "$api_value" ] && echo "不能为空" && return

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Caddy Web Server
After=network.target

[Service]
Type=simple
ExecStart=$CADDY_BIN run --environ --config $CADDY_FILE
Environment=$api_name=$api_value
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable caddy
  systemctl restart caddy
  systemctl status caddy --no-pager
}

# =========================
# 重载 / 停止 Caddy
# =========================
reload_caddy() {
  systemctl restart caddy
  systemctl status caddy --no-pager
}

stop_caddy() {
  systemctl stop caddy
  echo -e "${color_ok}Caddy 已停止${color_end}"
}

# =========================
# 查看 DNS 模块
# =========================
check_dns_module() {
  echo "DNS 模块检测："
  $CADDY_BIN list-modules | grep dns || echo "❌ 未发现 DNS 模块"
}

# =========================
# 删除反代配置
# =========================
delete_reverse_proxy() {
  [ ! -f "$CADDY_FILE" ] && echo "Caddyfile 不存在" && return

  mapfile -t BLOCKS < <(awk '
  /^[^ \t].*\{/ { block=$0 }
  block {
    block = block "\n" $0
    if ($0 ~ /^}/) {
      print block
      block=""
    }
  }' "$CADDY_FILE")

  [ ${#BLOCKS[@]} -eq 0 ] && echo "没有可删除的配置" && return

  echo "请选择要删除的域名："
  for i in "${!BLOCKS[@]}"; do
    echo "$((i+1)). $(echo "${BLOCKS[$i]}" | head -n1 | sed 's/{.*//')"
  done

  read -p "请输入序号：" n
  idx=$((n-1))

  [ "$idx" -lt 0 ] || [ "$idx" -ge "${#BLOCKS[@]}" ] && echo "无效选择" && return

  domain=$(echo "${BLOCKS[$idx]}" | head -n1 | sed 's/{.*//')
  echo "🗑 删除：$domain"

  awk -v d="$domain" '
  BEGIN{skip=0}
  {
    if ($0 ~ d && skip==0) {skip=1;next}
    if (skip && $0 ~ /^}/) {skip=0;next}
    if (!skip) print
  }' "$CADDY_FILE" > /tmp/caddy.tmp && mv /tmp/caddy.tmp "$CADDY_FILE"

  systemctl restart caddy
}

edit_caddyfile() {
  echo -e "${color_info}正在编辑 Caddy 配置文件: $CADDY_FILE${color_end}"
  nano "$CADDY_FILE"
  systemctl restart caddy
  echo -e "${color_ok}编辑完成并已重启 Caddy${color_end}"
}





# =========================
# 菜单
# =========================
menu() {
  echo "=============================="
  echo " Caddy + Cloudflare 管理脚本"
  echo "=============================="
  echo "1. 添加 Cloudflare API 配置"
  echo "2. 添加反向代理配置"
  echo "3. 创建/重建 caddy.service"
  echo "4. 重载 Caddy"
  echo "5. 停止 Caddy"
  echo "6. 重载 systemd 并启动"
  echo "7. 查看 Caddy DNS 模块"
  echo "8. 删除反向代理配置"
  echo "9. 编辑 Caddy 配置文件"
  echo "0. 退出"
  echo "=============================="
}

# =========================
# 主循环
# =========================
check_root

while true; do
  clear
  show_caddy_config    # 自动显示当前配置或提示暂无
  menu
  read -p "请选择操作编号：" choice
  case "$choice" in
    1) add_api ;;
    2) add_reverse_proxy ;;
    3) create_service ;;
    4) reload_caddy ;;
    5) stop_caddy ;;
    6) systemctl daemon-reload && systemctl restart caddy && systemctl status caddy --no-pager ;;
    7) check_dns_module ;;
    8) delete_reverse_proxy ;;
    9) edit_caddyfile ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
  read -p "按回车继续..."
done
