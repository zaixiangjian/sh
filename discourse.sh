#!/bin/bash
# Discourse 多实例分开管理脚本（安装时自动停止运行实例，支持多容器名）
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

# 停止所有运行实例和 Caddy（仅安装时调用）
function stop_running_instances() {
    for i in "${!INSTANCES[@]}"; do
        local dir container
        dir=$(echo "${INSTANCES[$i]}" | awk '{print $1}')
        container=$(echo "${INSTANCES[$i]}" | awk '{print $2}')
        if [ -d "$dir" ]; then
            cd "$dir" || continue
            if ./launcher status "$container" &>/dev/null; then
                echo "🛑 实例 $container 正在运行，先停止..."
                ./launcher stop "$container"
            fi
        fi
    done

    if systemctl is-active --quiet caddy; then
        echo "🛑 Caddy 正在运行，先停止..."
        systemctl stop caddy
    fi
}

# 停止单个实例
function stop_instance() {
    local index=$1
    local dir container
    dir=$(echo "${INSTANCES[$index]}" | awk '{print $1}')
    container=$(echo "${INSTANCES[$index]}" | awk '{print $2}')

    if [ ! -d "$dir" ]; then
        echo "❌ 目录 $dir 不存在"
        return
    fi

    cd "$dir" || return
    ./launcher stop "$container" 2>/dev/null || true
    echo "🛑 实例 $container 已停止"
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
    ./launcher start "$container"
    echo "▶️ 实例 $container 已启动"
}

# 安装单个实例（安装时会先停止运行实例和 Caddy）
function install_instance() {
    local index=$1
    local dir container
    dir=$(echo "${INSTANCES[$index]}" | awk '{print $1}')
    container=$(echo "${INSTANCES[$index]}" | awk '{print $2}')

    install_dependencies
    stop_running_instances

    if [ -d "$dir" ]; then
        echo "⚠️ 目录 $dir 已存在，跳过安装 $container"
        return
    fi

    echo "安装实例 $container 到目录 $dir..."
    git clone https://github.com/discourse/discourse_docker.git "$dir"
    cd "$dir" || exit
    chmod 700 containers

    # 为不同实例生成不同容器名
    if [ "$container" != "app" ]; then
        cp containers/app.yml containers/"$container".yml
        sed -i "s/container_name: app/container_name: $container/" containers/"$container".yml
        ./launcher bootstrap "$container"
        ./launcher start "$container"
    else
        ./discourse-setup
    fi

    echo "✅ 实例 $container 安装完成"
}

# 重建实例（不检测运行状态）
function rebuild_instance() {
    local index=$1
    local dir container
    dir=$(echo "${INSTANCES[$index]}" | awk '{print $1}')
    container=$(echo "${INSTANCES[$index]}" | awk '{print $2}')

    if [ ! -d "$dir" ]; then
        echo "❌ 目录 $dir 不存在，无法重建"
        return
    fi

    cd "$dir" || exit
    echo "🔧 重建容器 $container..."
    ./launcher rebuild "$container"
    echo "✅ 容器 $container 重建完成"
}

# 重启 Caddy
function restart_caddy() {
    echo "🔁 重启 Caddy..."
    systemctl restart caddy
    echo "✅ Caddy 已重启"
}

# 停止 Caddy
function stop_caddy() {
    echo "🛑 停止 Caddy..."
    systemctl stop caddy
    echo "✅ Caddy 已停止"
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
    echo ""
    echo "7) 重建 官方原版"
    echo "8) 重建 app1"
    echo "9) 重建 app2"
    echo "10) 停止 官方原版"
    echo "11) 停止 app1"
    echo "12) 停止 app2"
    echo "13) 重启 Caddy"
    echo "14) 停止 Caddy"
    echo "0) 退出"
    echo "=============================="
    read -rp "请输入选项: " choice

    case "$choice" in
        1) install_instance 0 ;;
        2) install_instance 1 ;;
        3) install_instance 2 ;;
        4) start_instance 0 ;;
        5) start_instance 1 ;;
        6) start_instance 2 ;;
        7) rebuild_instance 0 ;;
        8) rebuild_instance 1 ;;
        9) rebuild_instance 2 ;;
        10) stop_instance 0 ;;
        11) stop_instance 1 ;;
        12) stop_instance 2 ;;
        13) restart_caddy ;;
        14) stop_caddy ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项" ;;
    esac
done
