#!/bin/bash

FRP_DIR="/home/frp"
FRPC_CONFIG="$FRP_DIR/frpc.toml"
DOCKER_IMAGE="kjlion/frp:alpine"
DOCKER_NAME="frpc"
SERVER_PORT=8055

# 检查 Docker 并安装
install_docker_if_missing() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker 未安装，正在安装 Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
  else
    echo "Docker 已安装"
  fi
}

# 生成基础 frpc.toml
generate_frpc_config() {
  read -rp "请输入 FRP 服务端地址（IP 或域名）: " SERVER_ADDR
  read -rp "请输入 FRP 服务端 token: " TOKEN

  mkdir -p "$FRP_DIR"

  cat > "$FRPC_CONFIG" <<EOF
[common]
server_addr = $SERVER_ADDR
server_port = $SERVER_PORT
token = $TOKEN

EOF

  echo "已生成配置文件: $FRPC_CONFIG"
}

# 启动 FRP 客户端容器
start_frpc() {
  docker rm -f "$DOCKER_NAME" >/dev/null 2>&1
  docker run -d --name "$DOCKER_NAME" --restart=always --network host \
    -v "$FRPC_CONFIG":/frp/frpc.toml \
    $DOCKER_IMAGE /usr/local/bin/frpc -c /frp/frpc.toml

  if [ $? -eq 0 ]; then
    echo "FRP 客户端启动成功！"
  else
    echo "FRP 客户端启动失败！"
  fi
}

# 添加转发服务
add_forwarding_service() {
  echo "添加转发服务："

  read -rp "服务名称 (唯一): " SERVICE_NAME
  read -rp "转发类型 (tcp/udp，默认tcp): " SERVICE_TYPE
  SERVICE_TYPE=${SERVICE_TYPE:-tcp}
  read -rp "内网IP地址 (默认127.0.0.1): " LOCAL_IP
  LOCAL_IP=${LOCAL_IP:-127.0.0.1}
  read -rp "内网端口: " LOCAL_PORT
  read -rp "映射到外网端口: " REMOTE_PORT

  # 检查服务名称是否已存在
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

  echo "已添加服务 $SERVICE_NAME 到配置。"

  docker restart "$DOCKER_NAME"
}

# 删除转发服务
delete_forwarding_service() {
  read -rp "请输入要删除的服务名称: " SERVICE_NAME

  if ! grep -q "^\[$SERVICE_NAME\]" "$FRPC_CONFIG"; then
    echo "服务不存在。"
    return
  fi

  # 删除该服务段，从 [服务名] 开始，到下一空行或下一个服务名
  sed -i "/^\[$SERVICE_NAME\]/,/^\[/ { /^\[$SERVICE_NAME\]/d; /^$/d; }" "$FRPC_CONFIG"
  # 删除服务名行本身
  sed -i "/^\[$SERVICE_NAME\]/d" "$FRPC_CONFIG"

  echo "已删除服务 $SERVICE_NAME 。"

  docker restart "$DOCKER_NAME"
}

# 列出所有转发服务
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
}

# 卸载
uninstall_frpc() {
  docker rm -f "$DOCKER_NAME" >/dev/null 2>&1
  rm -rf "$FRP_DIR"
  echo "FRP 客户端已卸载。"
}

# 更新（示例：拉取镜像并重启）
update_frpc() {
  docker pull $DOCKER_IMAGE
  docker restart "$DOCKER_NAME"
  echo "FRP 客户端已更新并重启。"
}

# 主菜单
while true; do
  clear
  echo "===== FRP 客户端管理 ====="
  echo "1) 安装 FRP 客户端"
  echo "2) 更新 FRP 客户端"
  echo "3) 卸载 FRP 客户端"
  echo "4) 显示转发服务列表"
  echo "5) 添加转发服务"
  echo "6) 删除转发服务"
  echo "0) 退出"
  echo "========================="
  read -rp "请选择操作: " choice

  case "$choice" in
    1)
      install_docker_if_missing
      generate_frpc_config
      start_frpc
      read -rp "按回车继续..."
      ;;
    2)
      update_frpc
      read -rp "按回车继续..."
      ;;
    3)
      uninstall_frpc
      read -rp "按回车继续..."
      ;;
    4)
      list_forwarding_services
      read -rp "按回车继续..."
      ;;
    5)
      add_forwarding_service
      read -rp "按回车继续..."
      ;;
    6)
      delete_forwarding_service
      read -rp "按回车继续..."
      ;;
    0)
      echo "退出"
      exit 0
      ;;
    *)
      echo "无效选项，请重试。"
      read -rp "按回车继续..."
      ;;
  esac
done
