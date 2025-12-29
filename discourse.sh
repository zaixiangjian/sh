#!/bin/bash
# Discourse 多实例分开管理脚本
# root 用户运行
set -e

# 实例目录与容器名映射
INSTANCES=(
  "/var/discourse app"      # 官方
  "/var/discourse1 app1"    # 配置1
  "/var/discourse2 app2"    # 配置2
)

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本！"
  exit 1
fi

# 安装依赖
function install_dependencies() {
    echo "更新系统并安装依赖..."
    apt update -y
    apt install -y sudo curl git netcat-openbsd docker.io
    systemctl enable docker
    systemctl start docker
}

# 停止所有 Discourse 实例
function stop_all_instances() {
    for i in 0 1 2; do
        dir=$(echo "${INSTANCES[$i]}" | awk '{print $1}')
        container=$(echo "${INSTANCES[$i]}" | awk '{print $2}')
        if [ -d "$dir" ]; then
            cd "$dir" || continue
            ./launcher stop "$container" 2>/dev/null || true
            echo "🛑 已停止实例 $container"
        fi
    done
}

# 停止 Caddy
function stop_caddy() {
    if systemctl is-active --quiet caddy; then
        echo "🛑 Caddy 正在运行，先停止..."
        systemctl stop caddy
    fi
}

# 安装单个实例
function install_instance() {
    local index=$1
    local dir container
    dir=$(echo "${INSTANCES[$index]}" | awk '{print $1}')
    container=$(echo "${INSTANCES[$index]}" | awk '{print $2}')

    stop_all_instances
    stop_caddy

    if [ -d "$dir" ]; then
        echo "⚠️ 目录 $dir 已存在，跳过安装 $container"
        return
    fi

    echo "安装实例 $container 到目录 $dir..."
    git clone https://github.com/discourse/discourse_docker.git "$dir"
    cd "$dir" || exit
    chmod 700 containers

    echo "请为 $container 配置域名、端口和邮箱等信息："
    ./discourse-setup

    echo "✅ 实例 $container 安装完成"
}

# 启动实例
function start_instance() {
    local index=$1
    local dir container
    dir=$(echo "${INSTANCES[$index]}" | awk '{print $1}')
    container=$(echo "${INSTANCES[$index]}" | awk '{print $2}')

    if [ ! -d "$dir" ]; then
        echo "❌ 目录 $dir 不存在"
        return
    fi

    cd "$dir" || exit
    echo "▶️ 启动容器 $container..."
    ./launcher start "$container"
}

# 重启 Caddy
function restart_caddy() {
    echo "🔁 重启 Caddy..."
    systemctl restart caddy
    echo "✅ Caddy 已重启"
}

# 菜单
while true; do
    echo "=============================="
    echo "🛠 Discourse 多实例分开管理"
    echo "1) 安装 官方原版"
    echo "2) 安装 app1"
    echo "3) 安装 app2"
    echo "4) 启动 官方原版"
    echo "5) 启动 app1"
    echo "6) 启动 app2"
    echo "7) 重启 Caddy"
    echo "0) 退出"
    echo "=============================="
    read -rp "请输入选项: " choice

    case "$choice" in
        1) install_dependencies; install_instance 0 ;;
        2) install_dependencies; install_instance 1 ;;
        3) install_dependencies; install_instance 2 ;;
        4) start_instance 0 ;;
        5) start_instance 1 ;;
        6) start_instance 2 ;;
        7) restart_caddy ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项" ;;
    esac
done
