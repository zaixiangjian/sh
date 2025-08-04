#!/bin/bash

# 颜色和状态
gl_lv="\e[32m"  # 绿色
gl_hui="\e[90m"  # 灰色
gl_bai="\e[0m"   # 重置

check_frp_app() {
  if [ -d "/home/frp/" ]; then
    check_frp="${gl_lv}已安装${gl_bai}"
  else
    check_frp="${gl_hui}未安装${gl_bai}"
  fi
}

is_docker_running() {
  docker ps --format '{{.Names}}' | grep -w "$1" >/dev/null 2>&1
}

donlond_frp() {
  role="$1"
  config_file="/home/frp/${role}.toml"

  if is_docker_running "$role"; then
    echo "$role 容器已运行，先停止并删除"
    docker rm -f "$role"
  fi

  docker run -d \
    --name "$role" \
    --restart=always \
    --network host \
    -v "$config_file":"/frp/${role}.toml" \
    kjlion/frp:alpine \
    "/frp/${role}" -c "/frp/${role}.toml"
}

configure_frpc() {
  echo "安装 FRP 客户端..."
  read -e -p "请输入服务端IP地址: " server_addr
  read -e -p "请输入服务端token: " token
  echo

  mkdir -p /home/frp
  cat > /home/frp/frpc.toml <<EOF
[common]
server_addr = ${server_addr}
server_port = 8055
token = ${token}
EOF

  donlond_frp frpc
  echo "FRP客户端已安装并启动"
}

add_forwarding_service() {
  echo "添加内网转发服务"
  read -e -p "服务名称: " service_name
  read -e -p "转发类型 (tcp/udp) [默认tcp]: " service_type
  service_type=${service_type:-tcp}
  read -e -p "内网IP地址 [默认127.0.0.1]: " local_ip
  local_ip=${local_ip:-127.0.0.1}
  read -e -p "内网端口: " local_port
  read -e -p "映射到外网端口: " remote_port

  cat >> /home/frp/frpc.toml <<EOF

[${service_name}]
type = ${service_type}
local_ip = ${local_ip}
local_port = ${local_port}
remote_port = ${remote_port}
EOF

  docker restart frpc
  echo "服务 ${service_name} 已添加并生效"
}

delete_forwarding_service() {
  read -e -p "请输入要删除的服务名称: " service_name
  sed -i "/^\[${service_name}\]/,/^\[/{
    /^\[${service_name}\]/!{ /^\[/!d }
  }" /home/frp/frpc.toml
  # 也删除最后一个服务情况
  sed -i "/^\[${service_name}\]/,${d}" /home/frp/frpc.toml 2>/dev/null

  docker restart frpc
  echo "服务 ${service_name} 已删除并生效"
}

list_forwarding_services() {
  echo "当前转发服务列表："
  awk '
  BEGIN {print "服务名称          内网地址            外网地址           协议"}
  /^\[.*\]/ {service=$0; getline; getline; getline; getline;
    if (service && $0 ~ /local_ip = /) {
      ip=$3
      getline; port=$3
      getline; rport=$3
      getline; proto=$3
      gsub(/\[|\]/,"",service)
      printf "%-16s %-18s %-18s %-6s\n", service, ip ":" port, "服务端:" rport, proto
    }
  }' /home/frp/frpc.toml
}

update_frpc() {
  echo "更新 FRP 客户端..."
  docker rm -f frpc 2>/dev/null
  docker rmi kjlion/frp:alpine 2>/dev/null
  donlond_frp frpc
  echo "更新完成"
}

uninstall_frpc() {
  echo "卸载 FRP 客户端..."
  docker rm -f frpc 2>/dev/null
  docker rmi kjlion/frp:alpine 2>/dev/null
  rm -rf /home/frp
  echo "卸载完成"
}

frpc_menu() {
  while true; do
    clear
    check_frp_app
    echo -e "FRP 客户端管理 - 状态: $check_frp"
    echo "===================================="
    echo "1) 安装 FRP 客户端"
    echo "2) 更新 FRP 客户端"
    echo "3) 卸载 FRP 客户端"
    echo "4) 显示转发服务列表"
    echo "5) 添加转发服务"
    echo "6) 删除转发服务"
    echo "0) 退出"
    echo "===================================="
    read -p "请选择: " choice
    case $choice in
      1) configure_frpc ;;
      2) update_frpc ;;
      3) uninstall_frpc ;;
      4) list_forwarding_services; read -p "回车继续..." ;;
      5) add_forwarding_service; read -p "回车继续..." ;;
      6) delete_forwarding_service; read -p "回车继续..." ;;
      0) break ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

# 运行菜单
frpc_menu
