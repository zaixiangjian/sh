#!/bin/bash

FRP_DIR="/home/frp"
FRPC_CONFIG="$FRP_DIR/frpc.toml"
DOCKER_NAME="frpc"
SERVER_PORT=8055

# 检查是否安装FRP客户端
check_frp_app() {
  if [ -d "$FRP_DIR" ]; then
    echo "FRP客户端已安装"
  else
    echo "FRP客户端未安装"
  fi
}

# 下载并运行frpc Docker容器
run_frpc() {
  local config_file="$FRPC_CONFIG"
  docker pull kjlion/frp:alpine

  # 停止并删除旧容器（如果有）
  docker rm -f "$DOCKER_NAME" 2>/dev/null || true

  docker run -d --name "$DOCKER_NAME" --restart=always --network host \
    -v "$config_file":/frp/frpc.toml kjlion/frp:alpine /frpc -c /frp/frpc.toml
}

# 生成基础配置文件
generate_frpc_config() {
  mkdir -p "$FRP_DIR"

  echo "请输入外网服务端IP地址:"
  read -rp "服务端IP: " server_addr
  echo "请输入服务端Token:"
  read -rp "Token: " token

  cat > "$FRPC_CONFIG" <<EOF
[common]
server_addr = $server_addr
server_port = $SERVER_PORT
token = $token

EOF
  echo "基础配置生成成功：$FRPC_CONFIG"
}

# 添加内网穿透服务
add_forwarding_service() {
  echo "添加内网穿透服务"
  read -rp "服务名称（唯一标识）: " service_name
  read -rp "协议 (tcp/udp) [默认tcp]: " service_type
  service_type=${service_type:-tcp}
  read -rp "内网IP地址 [默认127.0.0.1]: " local_ip
  local_ip=${local_ip:-127.0.0.1}
  read -rp "内网端口: " local_port
  read -rp "映射的远端端口: " remote_port

  cat >> "$FRPC_CONFIG" <<EOF
[$service_name]
type = $service_type
local_ip = $local_ip
local_port = $local_port
remote_port = $remote_port

EOF
  echo "服务 $service_name 已添加"
}

# 删除内网穿透服务
delete_forwarding_service() {
  echo "删除内网穿透服务"
  read -rp "请输入要删除的服务名称: " service_name
  sed -i "/\[$service_name\]/,/^$/d" "$FRPC_CONFIG"
  echo "服务 $service_name 已删除"
}

# 查看已配置的内网穿透服务
list_forwarding_services() {
  echo "当前已配置的内网穿透服务："
  awk '
  /^\[.*\]/ {section=$0; next}
  /^[ \t]*type *=/ {type=$0}
  /^[ \t]*local_ip *=/ {local_ip=$0}
  /^[ \t]*local_port *=/ {local_port=$0}
  /^[ \t]*remote_port *=/ {remote_port=$0}
  /^[ \t]*$/ {
    if (section != "[common]") {
      print section
      print "  " type
      print "  " local_ip
      print "  " local_port
      print "  " remote_port
      print ""
    }
    section=""; type=""; local_ip=""; local_port=""; remote_port=""
  }
  ' "$FRPC_CONFIG"
}

# 安装frpc
install_frpc() {
  echo "开始安装FRP客户端..."
  generate_frpc_config
  run_frpc
  echo "FRP客户端安装完成"
  read -rp "按回车继续..."
}

# 更新frpc
update_frpc() {
  echo "开始更新FRP客户端..."
  docker rm -f "$DOCKER_NAME" 2>/dev/null || true
  run_frpc
  echo "更新完成"
  read -rp "按回车继续..."
}

# 卸载frpc
uninstall_frpc() {
  echo "开始卸载FRP客户端..."
  docker rm -f "$DOCKER_NAME" 2>/dev/null || true
  rm -rf "$FRP_DIR"
  echo "卸载完成"
  read -rp "按回车继续..."
}

# 主菜单
frpc_menu() {
  while true; do
    clear
    check_frp_app
    echo "========== FRP 客户端管理 =========="
    list_forwarding_services
    echo "===================================="
    echo "1) 安装 FRP 客户端"
    echo "2) 更新 FRP 客户端"
    echo "3) 卸载 FRP 客户端"
    echo "4) 添加内网穿透服务"
    echo "5) 删除内网穿透服务"
    echo "0) 退出"
    echo "===================================="
    read -rp "请选择操作: " choice

    case $choice in
      1) install_frpc ;;
      2) update_frpc ;;
      3) uninstall_frpc ;;
      4) add_forwarding_service; run_frpc ;;
      5) delete_forwarding_service; run_frpc ;;
      0) echo "退出"; exit 0 ;;
      *) echo "无效选项，请重试" ;;
    esac
  done
}

# 运行菜单
frpc_menu
