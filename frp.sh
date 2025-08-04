#!/bin/bash

FRP_DIR="/home/frp"
DOCKER_IMAGE="kjlion/frp:alpine"

# ----------------------
# 通用工具函数
# ----------------------

install_docker_if_missing() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker 未安装，正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
  else
    echo "Docker 已安装"
  fi
}

# ----------------------
# FRP 服务端相关
# ----------------------

FRPS_CONFIG="$FRP_DIR/frps.toml"
FRPS_DOCKER_NAME="frps"
FRPS_PORT=8055
FRPS_DASHBOARD_PORT=8056

generate_frps_config() {
  mkdir -p "$FRP_DIR"
  local token=$(openssl rand -hex 16)
  local dashboard_user="user_$(openssl rand -hex 4)"
  local dashboard_pwd=$(openssl rand -hex 8)

  cat > "$FRPS_CONFIG" <<EOF
[common]
bind_port = $FRPS_PORT
authentication_method = token
token = $token
dashboard_port = $FRPS_DASHBOARD_PORT
dashboard_user = $dashboard_user
dashboard_pwd = $dashboard_pwd
EOF

  echo "$token" "$dashboard_user" "$dashboard_pwd"
}

start_frps() {
  docker rm -f "$FRPS_DOCKER_NAME" >/dev/null 2>&1 || true
  docker pull $DOCKER_IMAGE

  docker run -d --name "$FRPS_DOCKER_NAME" --restart=always --network host \
    -v "$FRPS_CONFIG":/frp/frps.toml \
    $DOCKER_IMAGE frps -c /frp/frps.toml
}

install_frps() {
  echo "开始安装 FRP 服务端..."
  install_docker_if_missing
  read -r token dashboard_user dashboard_pwd < <(generate_frps_config)
  start_frps

  ip_addr=$(curl -s https://api.ipify.org)
  echo
  echo "FRP 服务端安装成功！"
  echo "面板地址：http://$ip_addr:$FRPS_DASHBOARD_PORT"
  echo "Token: $token"
  echo "用户名: $dashboard_user"
  echo "密码: $dashboard_pwd"
  echo
  read -rp "按回车继续..."
}

update_frps() {
  echo "更新 FRP 服务端..."
  docker pull $DOCKER_IMAGE
  docker restart "$FRPS_DOCKER_NAME"
  echo "更新完成"
  read -rp "按回车继续..."
}

uninstall_frps() {
  echo "卸载 FRP 服务端..."
  docker rm -f "$FRPS_DOCKER_NAME" >/dev/null 2>&1 || true
  rm -rf "$FRP_DIR"
  echo "卸载完成"
  read -rp "按回车继续..."
}

# ----------------------
# FRP 客户端相关
# ----------------------

FRPC_CONFIG="$FRP_DIR/frpc.toml"
FRPC_DOCKER_NAME="frpc"
FRPC_SERVER_PORT=$FRPS_PORT

generate_frpc_config() {
  read -rp "请输入 FRP 服务端地址（IP 或域名）: " SERVER_ADDR
  read -rp "请输入 FRP 服务端 token: " TOKEN

  mkdir -p "$FRP_DIR"

  cat > "$FRPC_CONFIG" <<EOF
[common]
server_addr = $SERVER_ADDR
server_port = $FRPC_SERVER_PORT
token = $TOKEN

EOF

  echo "已生成客户端配置文件: $FRPC_CONFIG"
}

start_frpc() {
  docker rm -f "$FRPC_DOCKER_NAME" >/dev/null 2>&1 || true
  docker pull $DOCKER_IMAGE

  docker run -d --name "$FRPC_DOCKER_NAME" --restart=always --network host \
    -v "$FRPC_CONFIG":/frp/frpc.toml \
    $DOCKER_IMAGE frpc -c /frp/frpc.toml
}

install_frpc() {
  echo "开始安装 FRP 客户端..."
  install_docker_if_missing
  generate_frpc_config
  start_frpc
  echo "FRP 客户端安装成功！"
  read -rp "按回车继续..."
}

update_frpc() {
  echo "更新 FRP 客户端..."
  docker pull $DOCKER_IMAGE
  docker restart "$FRPC_DOCKER_NAME"
  echo "更新完成"
  read -rp "按回车继续..."
}

uninstall_frpc() {
  echo "卸载 FRP 客户端..."
  docker rm -f "$FRPC_DOCKER_NAME" >/dev/null 2>&1 || true
  rm -rf "$FRP_DIR"
  echo "卸载完成"
  read -rp "按回车继续..."
}

add_forwarding_service() {
  echo "添加转发服务："

  read -rp "服务名称 (唯一): " SERVICE_NAME
  read -rp "转发类型 (tcp/udp，默认tcp): " SERVICE_TYPE
  SERVICE_TYPE=${SERVICE_TYPE:-tcp}
  read -rp "内网IP地址 (默认127.0.0.1): " LOCAL_IP
  LOCAL_IP=${LOCAL_IP:-127.0.0.1}
  read -rp "内网端口: " LOCAL_PORT
  read -rp "映射到外网端口: " REMOTE_PORT

  if grep -q "^\[$SERVICE_NAME\]" "$FRPC_CONFIG"; then
    echo "服务名已存在，请先删除后再添加。"
    return
  fi

  cat >> "$FRPC_CONFIG" <<EOF

[$SERVICE_NAME]
type = $SERVICE_TYPE
local_ip = $LOCAL_IP
local_port = $LOCAL_PORT
remote_port = $REMOTE_PORT
EOF

  echo "已添加服务 $SERVICE_NAME 到客户端配置。"
  docker restart "$FRPC_DOCKER_NAME"
  read -rp "按回车继续..."
}

delete_forwarding_service() {
  read -rp "请输入要删除的服务名称: " SERVICE_NAME

  if ! grep -q "^\[$SERVICE_NAME\]" "$FRPC_CONFIG"; then
    echo "服务不存在。"
    read -rp "按回车继续..."
    return
  fi

  sed -i "/^\[$SERVICE_NAME\]/,/^\[/ { /^\[$SERVICE_NAME\]/d; /^$/d; }" "$FRPC_CONFIG"
  sed -i "/^\[$SERVICE_NAME\]/d" "$FRPC_CONFIG"

  echo "已删除服务 $SERVICE_NAME 。"
  docker restart "$FRPC_DOCKER_NAME"
  read -rp "按回车继续..."
}

list_forwarding_services() {
  echo "当前转发服务列表："
  echo -e "服务名称\t内网地址\t外网端口\t协议"

  awk '
    /^\[.*\]$/ {
      if ($0 != "[common]") {
        service=substr($0, 2, length($0)-2)
        getline
        while ($0 !~ /^\[/ && $0 != "") {
          if ($1 == "local_ip") ip=$3
          if ($1 == "local_port") local_port=$3
          if ($1 == "remote_port") remote_port=$3
          if ($1 == "type") type=$3
          getline
        }
        printf "%s\t%s:%s\t%s\t%s\n", service, ip, local_port, remote_port, type
      }
    }
  ' FS="[= \t]+" "$FRPC_CONFIG"

  read -rp "按回车继续..."
}

# ----------------------
# 主菜单
# ----------------------

while true; do
  clear
  echo "===== FRP 一键管理脚本 ====="
  echo "1) 安装 FRP 服务端"
  echo "2) 更新 FRP 服务端"
  echo "3) 卸载 FRP 服务端"
  echo "4) 安装 FRP 客户端"
  echo "5) 更新 FRP 客户端"
  echo "6) 卸载 FRP 客户端"
  echo "7) 显示客户端转发服务列表"
  echo "8) 添加客户端转发服务"
  echo "9) 删除客户端转发服务"
  echo "0) 退出"
  echo "==========================="
  read -rp "请选择操作: " choice

  case "$choice" in
    1) install_frps ;;
    2) update_frps ;;
    3) uninstall_frps ;;
    4) install_frpc ;;
    5) update_frpc ;;
    6) uninstall_frpc ;;
    7) list_forwarding_services ;;
    8) add_forwarding_service ;;
    9) delete_forwarding_service ;;
    0) echo "退出脚本"; exit 0 ;;
    *) echo "无效选项，请重试。" ; read -rp "按回车继续..." ;;
  esac
done
