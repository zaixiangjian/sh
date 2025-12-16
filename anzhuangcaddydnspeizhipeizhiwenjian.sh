#!/bin/bash
# Caddy + Cloudflare DNS 一键管理脚本
# Author: ChatGPT
# 适用于 Debian / Ubuntu

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

add_api() {
  echo -e "${color_info}添加 Cloudflare API 环境变量${color_end}"
  read -p "请输入变量名（默认 CF_API_TOKEN）：" api_name
  api_name=${api_name:-CF_API_TOKEN}
  read -p "请输入 API Token（必填）：" api_value
  if [ -z "$api_value" ]; then
    echo -e "${color_err}API Token 不能为空${color_end}"
    return
  fi

  mkdir -p "$CADDY_DIR"
  grep -q "^export $api_name=" /etc/profile 2>/dev/null && \
    sed -i "/^export $api_name=/d" /etc/profile

  echo "export $api_name=\"$api_value\"" >> /etc/profile
  export "$api_name=$api_value"

  echo -e "${color_ok}已添加环境变量 $api_name${color_end}"
}

add_reverse_proxy() {
  echo -e "${color_info}添加反向代理配置${color_end}"
  read -p "请输入域名和端口（如 www.123.com:2053）：" domain_port
  if [ -z "$domain_port" ]; then
    echo -e "${color_err}域名端口不能为空${color_end}"
    return
  fi

  read -p "反代地址（默认 127.0.0.1）：" proxy_host
  proxy_host=${proxy_host:-127.0.0.1}

  read -p "反代端口（必填）：" proxy_port
  if [ -z "$proxy_port" ]; then
    echo -e "${color_err}反代端口不能为空${color_end}"
    return
  fi

  mkdir -p "$CADDY_DIR"

  cat >> "$CADDY_FILE" <<EOF

$domain_port {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy $proxy_host:$proxy_port {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF

  echo -e "${color_ok}反向代理已写入 $CADDY_FILE${color_end}"
}

create_service() {
  echo -e "${color_info}创建 caddy systemd 服务${color_end}"
  read -p "请输入 API 环境变量名（默认 CF_API_TOKEN）：" api_name
  api_name=${api_name:-CF_API_TOKEN}
  read -p "请输入 API Token：" api_value

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
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  systemctl status caddy --no-pager
}

reload_caddy() {
  systemctl restart caddy
  systemctl status caddy --no-pager
}

stop_caddy() {
  systemctl stop caddy
  echo -e "${color_ok}Caddy 已停止${color_end}"
}

check_dns_module() {
  $CADDY_BIN list-modules | grep dns || echo "未发现 DNS 模块"
}

check_config_exist() {
  echo -e "${color_info}检查 Caddy 配置文件${color_end}"
  if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
    echo -e "${color_ok}已存在配置：$CONFIG_FILE${color_end}"
    echo "--------------------------------"
    sed -n '1,200p' "$CONFIG_FILE"
  else
    echo -e "${color_err}未发现任何 Caddy 配置${color_end}"
  fi
}

delete_reverse_proxy() {
  CONFIG_FILE="$CADDY_FILE"
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "⚠️  Caddyfile 不存在"
    return
  fi

  mapfile -t BLOCKS < <(awk '
  BEGIN { block="" }
  /^[^ 	].*\{/ { block=$0; next }
  block != "" {
    block=block"
"$0
    if ($0 ~ /^}/) {
      print block
      block=""
    }
  }
  ' "$CONFIG_FILE")

  if [ ${#BLOCKS[@]} -eq 0 ]; then
    echo "⚠️  没有找到可删除的配置块。"
    return
  fi

  echo "请选择要删除的域名："
  for i in "${!BLOCKS[@]}"; do
    DOMAIN_LINE=$(echo "${BLOCKS[$i]}" | head -n 1 | sed 's/{.*//;s/ *$//')
    echo "$((i+1)). $DOMAIN_LINE"
  done

  read -p "请输入序号: " SELECTED
  INDEX=$((SELECTED - 1))

  if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#BLOCKS[@]}" ]; then
    DOMAIN_TO_DELETE=$(echo "${BLOCKS[$INDEX]}" | head -n 1 | sed 's/{.*//;s/ *$//')
    echo "🗑 正在删除配置域名：$DOMAIN_TO_DELETE"

    awk -v domain="$DOMAIN_TO_DELETE" '
    BEGIN { skip=0 }
    {
        if (skip==0) {
            if ($0 ~ domain) {
                skip=1
                next
            }
            print
        } else {
            if ($0 ~ /^}/) {
                skip=0
                next
            }
        }
    }
    ' "$CONFIG_FILE" > /tmp/caddy_tmp && mv /tmp/caddy_tmp "$CONFIG_FILE"

    systemctl restart caddy
    systemctl status caddy --no-pager
  else
    echo "❌ 无效的选择。"
  fi
}

menu() {
  clear
  echo "=============================="
  echo " Caddy + Cloudflare 管理脚本"
  echo "=============================="
  echo "1. 添加 Cloudflare API 配置"
  echo "2. 添加反向代理配置"
  echo "3. 创建/重建 caddy.service"
  echo "4. 重载 Caddy"
  echo "5. 停止 Caddy"
  echo "6. 重载 systemd 并启动"
  echo "7. 查看是否已有 Caddy 配置"
  echo "8. 删除反向代理配置"
  echo "9. 查看 Caddy DNS 模块""
  echo "0. 退出"
  echo "=============================="
}

check_root

while true; do
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
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
  read -p "按回车继续..."
done
