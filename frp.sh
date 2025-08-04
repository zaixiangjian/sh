#!/bin/bash

FRP_DIR="/home/frp"
FRPS_CONFIG="$FRP_DIR/frps.toml"
DOCKER_NAME="frps"
DASHBOARD_PORT=8056

# 读取配置里的token和dashboard用户名密码
get_frps_info() {
  if [ -f "$FRPS_CONFIG" ]; then
    token=$(grep '^token' "$FRPS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' "')
    dashboard_user=$(grep '^dashboard_user' "$FRPS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' "')
    dashboard_pwd=$(grep '^dashboard_pwd' "$FRPS_CONFIG" | awk -F '=' '{print $2}' | tr -d ' "')
  fi
}

# 显示面板地址
show_dashboard_info() {
  local ip
  ip=$(curl -s https://api.ipify.org)
  echo "访问面板：http://$ip:$DASHBOARD_PORT"
  echo "用户名：$dashboard_user"
  echo "密码：$dashboard_pwd"
}

# 显示已连接端口信息（通过api或者读取日志，简单示范用API）
show_connected_services() {
  # 先确认docker运行
  if ! docker ps | grep -q "$DOCKER_NAME"; then
    echo "FRP服务端未运行"
    return
  fi

  echo "已连接的服务端口列表:"

  # 通过dashboard API获取TCP隧道信息（需要jq）
  curl -s -u "$dashboard_user:$dashboard_pwd" "http://127.0.0.1:$DASHBOARD_PORT/api/status" | jq -r '
    .data.tcp | to_entries[] |
    "服务名: \(.key) 远端端口: \(.value.remote_port) 内网地址: \(.value.local_ip):\(.value.local_port)"
  '
}

main_menu() {
  get_frps_info

  while true; do
    clear
    echo "========== FRP 服务端管理 =========="
    show_dashboard_info
    echo "-------------------------------"
    show_connected_services
    echo "==============================="
    echo "1) 安装 FRP 服务端"
    echo "2) 更新 FRP 服务端"
    echo "3) 卸载 FRP 服务端"
    echo "4) 显示已连接客户端"
    echo "5) 刷新已连接客户端"
    echo "0) 退出"
    echo "==================================="
    read -rp "请选择操作: " choice

    case $choice in
      1)
        # 安装函数示例，需自己实现
        install_frps
        ;;
      2)
        update_frps
        ;;
      3)
        uninstall_frps
        ;;
      4)
        show_connected_services
        read -rp "按回车返回..."
        ;;
      5)
        echo "刷新中..."
        show_connected_services
        read -rp "按回车返回..."
        ;;
      0)
        echo "退出"
        exit 0
        ;;
      *)
        echo "无效选项，请重试"
        ;;
    esac
  done
}

# 伪函数示例（根据你已有逻辑补充）
install_frps() {
  echo "安装中..."
  # 你的安装逻辑
  read -rp "按回车继续..."
}

update_frps() {
  echo "更新中..."
  # 你的更新逻辑
  read -rp "按回车继续..."
}

uninstall_frps() {
  echo "卸载中..."
  # 你的卸载逻辑
  read -rp "按回车继续..."
}

main_menu
