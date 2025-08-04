#!/bin/bash

FRP_DIR="/home/frp"
FRPS_CONFIG="$FRP_DIR/frps.toml"
FRPC_CONFIG="$FRP_DIR/frpc.toml"
DOCKER_IMAGE="kjlion/frp:alpine"

# 获取公网IP
get_ip() {
  curl -s https://api.ipify.org
}

# 安装 Docker（Debian/Ubuntu示例）
install_docker() {
  if ! command -v docker &>/dev/null; then
    echo "检测到未安装 Docker，开始安装..."
    apt update && apt install -y docker.io
    systemctl enable docker --now
  else
    echo "Docker 已安装"
  fi
}

# 安装 FRP 服务端
install_frps() {
  install_docker
  mkdir -p "$FRP_DIR"

  # 生成配置
  bind_port=8055
  dashboard_port=8056
  token=$(openssl rand -hex 16)
  dashboard_user="user_$(openssl rand -hex 4)"
  dashboard_pwd=$(openssl rand -hex 8)

  cat > "$FRPS_CONFIG" <<EOF
[common]
bind_port = $bind_port
authentication_method = token
token = $token
dashboard_port = $dashboard_port
dashboard_user = $dashboard_user
dashboard_pwd = $dashboard_pwd
EOF

  # 拉取镜像、启动容器
  docker pull $DOCKER_IMAGE
  docker rm -f frps 2>/dev/null || true
  docker run -d --name frps --restart=always --network host \
    -v "$FRPS_CONFIG":/frp/frps.toml \
    $DOCKER_IMAGE /frps -c /frp/frps.toml

  echo "FRP 服务端已安装启动！"
  echo "Token: $token"
  echo "Dashboard: http://$(get_ip):$dashboard_port"
  echo "用户名: $dashboard_user"
  echo "密码: $dashboard_pwd"
  read -rp "按回车继续..."
}

# 更新 FRP 服务端
update_frps() {
  echo "更新 FRP 服务端..."
  docker rm -f frps 2>/dev/null || true
  docker pull $DOCKER_IMAGE
  docker run -d --name frps --restart=always --network host \
    -v "$FRPS_CONFIG":/frp/frps.toml \
    $DOCKER_IMAGE /frps -c /frp/frps.toml
  echo "更新完成！"
  read -rp "按回车继续..."
}

# 卸载 FRP 服务端
uninstall_frps() {
  echo "卸载 FRP 服务端..."
  docker rm -f frps 2>/dev/null || true
  rm -rf "$FRP_DIR"
  echo "卸载完成！"
  read -rp "按回车继续..."
}

# 显示已连接客户端（通过Dashboard API）
show_connected_services() {
  if ! docker ps | grep -q frps; then
    echo "FRP 服务端未运行"
    read -rp "按回车返回..."
    return
  fi

  # 读取token和面板账号密码
  token=$(grep '^token' "$FRPS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' "')
  dashboard_user=$(grep '^dashboard_user' "$FRPS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' "')
  dashboard_pwd=$(grep '^dashboard_pwd' "$FRPS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' "')

  echo "连接的 TCP 服务："
  curl -s -u "$dashboard_user:$dashboard_pwd" "http://127.0.0.1:$dashboard_port/api/status" | jq -r '
    .data.tcp | to_entries[] |
    "服务名: \(.key) 远端端口: \(.value.remote_port) 内网地址: \(.value.local_ip):\(.value.local_port)"
  '

  read -rp "按回车返回..."
}

# 主菜单
main_menu() {
  while true; do
    clear
    echo "========== FRP 服务端管理 =========="
    echo "1) 安装 FRP 服务端"
    echo "2) 更新 FRP 服务端"
    echo "3) 卸载 FRP 服务端"
    echo "4) 显示已连接客户端"
    echo "5) 刷新已连接客户端"
    echo "0) 退出"
    echo "==================================="

    read -rp "请选择操作: " choice

    case $choice in
      1) install_frps ;;
      2) update_frps ;;
      3) uninstall_frps ;;
      4|5) show_connected_services ;;
      0) echo "退出"; exit 0 ;;
      *) echo "无效选项"; read -rp "按回车继续..." ;;
    esac
  done
}

# 先检测依赖 jq
if ! command -v jq &>/dev/null; then
  echo "检测到未安装 jq，正在安装..."
  apt update && apt install -y jq
fi

main_menu
