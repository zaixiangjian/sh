#!/bin/bash

# 日志记录函数
log_file="/var/log/frp_install.log"
log_message() {
  echo "$(date) - $1" >> "$log_file"
}

# 检查并安装依赖
install() {
  for pkg in "$@"; do
    dpkg -l | grep -qw "$pkg" || apt install -y "$pkg"
  done
}

# 安装 Docker（如果未安装）
install_docker() {
  if ! command -v docker &>/dev/null; then
    log_message "Docker 未安装，正在安装 Docker..."
    install apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker --now
  fi
}

# 检查是否存在 Docker 镜像
check_docker_image() {
  local image="$1"
  docker image inspect "$image" > /dev/null 2>&1
}

# 检查是否安装 frp
check_frp_app() {
  if [ -d "/home/frp/" ]; then
    check_frp="已安装"
  else
    check_frp="未安装"
  fi
}

# 下载并运行 FRP 服务端/客户端容器
download_frp() {
  role="$1"
  config_file="/home/frp/${role}.toml"

  # 检查 Docker 镜像是否存在，不存在则拉取
  if ! check_docker_image "kjlion/frp:alpine"; then
    echo "Docker 镜像 kjlion/frp:alpine 不存在，正在拉取..."
    docker pull kjlion/frp:alpine
  fi

  # 运行 Docker 容器
  docker run -d \
    --name "$role" \
    --restart=always \
    --network host \
    -v "$config_file":"/frp/${role}.toml" \
    kjlion/frp:alpine \
    "/frp/${role}" -c "/frp/${role}.toml"
}

# 生成 FRP 服务端配置
generate_frps_config() {
  send_stats "安装FRP服务端"
  local bind_port=8055
  local dashboard_port=8056
  local token=$(openssl rand -hex 16)
  local dashboard_user="user_$(openssl rand -hex 4)"
  local dashboard_pwd=$(openssl rand -hex 8)

  mkdir -p /home/frp
  touch /home/frp/frps.toml
  cat <<EOF > /home/frp/frps.toml
[common]
bind_port = $bind_port
authentication_method = token
token = $token
dashboard_port = $dashboard_port
dashboard_user = $dashboard_user
dashboard_pwd = $dashboard_pwd
EOF

  download_frp frps

  # 输出生成的信息
  ip_address
  echo "------------------------"
  echo "客户端部署时需要用的参数"
  echo "服务IP: $ipv4_address"
  echo "token: $token"
  echo
  echo "FRP面板信息"
  echo "FRP面板地址: http://$ipv4_address:$dashboard_port"
  echo "FRP面板用户名: $dashboard_user"
  echo "FRP面板密码: $dashboard_pwd"
  echo

  open_port 8055 8056
}

# 配置 FRP 客户端
configure_frpc() {
  send_stats "安装FRP客户端"
  read -e -p "请输入外网对接IP: " server_addr
  read -e -p "请输入外网对接token: " token
  echo

  mkdir -p /home/frp
  touch /home/frp/frpc.toml
  cat <<EOF > /home/frp/frpc.toml
[common]
server_addr = ${server_addr}
server_port = 8055
token = ${token}
EOF

  download_frp frpc
  open_port 8055
}

# 添加内网服务
add_forwarding_service() {
  send_stats "添加FRP内网服务"
  read -e -p "请输入服务名称: " service_name
  read -e -p "请输入转发类型 (tcp/udp) [回车默认tcp]: " service_type
  local service_type=${service_type:-tcp}
  read -e -p "请输入内网IP [回车默认127.0.0.1]: " local_ip
  local local_ip=${local_ip:-127.0.0.1}
  read -e -p "请输入内网端口: " local_port
  read -e -p "请输入外网端口: " remote_port

  cat <<EOF >> /home/frp/frpc.toml
[$service_name]
type = ${service_type}
local_ip = ${local_ip}
local_port = ${local_port}
remote_port = ${remote_port}
EOF

  echo "服务 $service_name 已成功添加到 frpc.toml"
  docker restart frpc
  open_port $local_port
}

# 删除内网服务
delete_forwarding_service() {
  send_stats "删除FRP内网服务"
  read -e -p "请输入需要删除的服务名称: " service_name
  sed -i "/\[$service_name\]/,/^$/d" /home/frp/frpc.toml
  echo "服务 $service_name 已成功从 frpc.toml 删除"
  docker restart frpc
}

# 打印当前内网服务
list_forwarding_services() {
  local config_file="$1"
  printf "%-20s %-25s %-30s %-10s\n" "服务名称" "内网地址" "外网地址" "协议"
  awk '
  BEGIN {
    server_addr=""
    server_port=""
    current_service=""
  }
  /^server_addr = / {
    gsub(/"|'"'"'/, "", $3)
    server_addr=$3
  }
  /^server_port = / {
    gsub(/"|'"'"'/, "", $3)
    server_port=$3
  }
  /^\[.*\]/ {
    if (current_service != "" && current_service != "common" && local_ip != "" && local_port != "") {
      printf "%-16s %-21s %-26s %-10s\n", current_service, local_ip ":" local_port, server_addr ":" remote_port, type
    }
    if ($1 != "[common]") {
      gsub(/[\[\]]/, "", $1)
      current_service=$1
      local_ip=""
      local_port=""
      remote_port=""
      type=""
    }
  }
  /^local_ip = / {
    gsub(/"|'"'"'/, "", $3)
    local_ip=$3
  }
  /^local_port = / {
    gsub(/"|'"'"'/, "", $3)
    local_port=$3
  }
  /^remote_port = / {
    gsub(/"|'"'"'/, "", $3)
    remote_port=$3
  }
  /^type = / {
    gsub(/"|'"'"'/, "", $3)
    type=$3
  }
  END {
    if (current_service != "" && current_service != "common" && local_ip != "" && local_port != "") {
      printf "%-16s %-21s %-26s %-10s\n", current_service, local_ip ":" local_port, server_addr ":" remote_port, type
    }
  }' "$config_file"
}

# 获取 FRP 服务端端口
get_frp_ports() {
  mapfile -t ports < <(ss -tulnape | grep frps | awk '{print $5}' | awk -F':' '{print $NF}' | sort -u)
}

# 生成 FRP 访问地址
generate_access_urls() {
  get_frp_ports
  local has_valid_ports=false
  for port in "${ports[@]}"; do
    if [[ $port != "8055" && $port != "8056" ]]; then
      has_valid_ports=true
      break
    fi
  done

  if [ "$has_valid_ports" = true ]; then
    echo "FRP服务对外访问地址:"
    for port in "${ports[@]}"; do
      if [[ $port != "8055" && $port != "8056" ]]; then
        echo "http://${ipv4_address}:${port}"
      fi
    done

    if [ -n "$ipv6_address" ]; then
      for port in "${ports[@]}"; do
        if [[ $port != "8055" && $port != "8056" ]]; then
          echo "http://[${ipv6_address}]:${port}"
        fi
      done
    fi
  fi
}

# FRP 服务端主端口配置
frps_main_ports() {
  ip_address
  generate_access_urls
}

# 控制 FRP 服务端和客户端面板的逻辑
frps_panel() {
  send_stats "FRP服务端"
  local app_id="55"
  local docker_name="frps"
  local docker_port=8056
  while true; do
    clear
    check_frp_app
    check_docker_image_update $docker_name
    echo -e "FRP服务端 $check_frp $update_status"
    echo "构建FRP内网穿透服务环境，将无公网IP的设备暴露到互联网"
    echo "官网介绍: https://github.com/fatedier/frp/"
    echo "视频教学: https://www.bilibili.com/video/BV1yMw6e2EwL?t=124.0"
    if [ -d "/home/frp/" ]; then
      check_docker_app_ip
      frps_main_ports
    fi
    echo ""
    echo "------------------------"
    echo "1. 安装                  2. 更新                  3. 卸载"
    echo "------------------------"
    echo "5. 内网服务域名访问      6. 删除域名访问"
    echo "------------------------"
    echo "7. 允许IP+端口访问       8. 阻止IP+端口访问"
    echo "------------------------"
    echo "00. 刷新服务状态         0. 返回上一级选单"
    echo "------------------------"
    read -e -p "输入你的选择: " choice
    case $choice in
      1)
        install jq grep ss
        install_docker
        generate_frps_config
        add_app_id
        echo "FRP服务端已经安装完成"
        ;;
      2)
        crontab -l | grep -v 'frps' | crontab - > /dev/null 2>&1
        tmux kill-session -t frps >/dev/null 2>&1
        docker rm -f frps && docker rmi kjlion/frp:alpine >/dev/null 2>&1
        [ -f /home/frp/frps.toml ] || cp /home/frp/frp_0.61.0_linux_amd64/frps.toml /home/frp/frps.toml
        download_frp frps
        add_app_id
        echo "FRP服务端已经更新完成"
        ;;
      3)
        crontab -l | grep -v 'frps' | crontab - > /dev/null 2>&1
        tmux kill-session -t frps >/dev/null 2>&1
        docker rm -f frps && docker rmi kjlion/frp:alpine
        rm -rf /home/frp
        close_port 8055 8056
        sed -i "/\b${app_id}\b/d" /home/docker/appno.txt
        echo "应用已卸载"
        ;;
      *)
        break
        ;;
    esac
    break_end
  done
}
