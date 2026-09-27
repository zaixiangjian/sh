#!/bin/bash

# 配置路径
INSTALL_DIR="/home/docker"
BTCPAY_DIR="$INSTALL_DIR/btcpayserver-docker"
COMPOSE_FILE="Generated/docker-compose.generated.yml"
BTCPAY_HTTP_BIND="0.0.0.0:10080"
BTCPAY_ENV_FILE="$INSTALL_DIR/.env"
BTCPAY_PROFILE_FILE="/etc/profile.d/btcpay-env.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本。${NC}"
  exit 1
fi

# [环境检查]
check_env() {
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}正在安装 Docker...${NC}"
        apt update && apt install -y git curl docker.io docker-compose
        systemctl enable --now docker
    fi
}

set_or_append_env() {
    local file="$1"
    local key="$2"
    local value="$3"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if grep -qE "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

apply_btcpay_env_overrides() {
    # BTCPay 官方把环境保存到 /home/docker/.env；更新脚本会先读取它，所以更新前必须写回这里。
    set_or_append_env "$BTCPAY_ENV_FILE" "BTCPAYGEN_REVERSEPROXY" "none"
    set_or_append_env "$BTCPAY_ENV_FILE" "BTCPAY_PROTOCOL" "http"
    set_or_append_env "$BTCPAY_ENV_FILE" "NOREVERSEPROXY_HTTP_PORT" "$BTCPAY_HTTP_BIND"
    # none 模式实际使用 NOREVERSEPROXY_HTTP_PORT；保留这个值只用于避免旧配置误导。
    set_or_append_env "$BTCPAY_ENV_FILE" "REVERSEPROXY_HTTP_PORT" "$BTCPAY_HTTP_BIND"
}


compose_down_with_volumes() {
    if [ -f "$COMPOSE_FILE" ]; then
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose -f "$COMPOSE_FILE" down -v --remove-orphans
        else
            docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
        fi
    elif [ -f "docker-compose.yml" ]; then
        if command -v docker-compose >/dev/null 2>&1; then
            docker-compose -f docker-compose.yml down -v --remove-orphans
        else
            docker compose -f docker-compose.yml down -v --remove-orphans
        fi
    elif [ -f "./btcpay-down.sh" ]; then
        . ./btcpay-down.sh
    else
        echo -e "${YELLOW}未找到 compose 文件或 btcpay-down.sh，跳过容器停止。${NC}"
    fi
}

uninstall_btcpay() {
    if [ ! -d "$BTCPAY_DIR" ]; then
        echo -e "${YELLOW}未找到 BTCPay 安装目录：$BTCPAY_DIR${NC}"
        return 0
    fi

    cd "$BTCPAY_DIR" || return 1
    echo -e "${YELLOW}正在停止并删除 BTCPay 容器、网络和 Docker volumes...${NC}"
    compose_down_with_volumes
    cd / || return 1
    rm -rf "$BTCPAY_DIR"
    rm -f "$BTCPAY_ENV_FILE" "$BTCPAY_PROFILE_FILE"
    echo -e "${GREEN}卸载完成：已删除本地目录、/home/docker/.env、环境文件和 compose 管理的 volumes。${NC}"
}

uninstall_btcpay_confirm() {
    echo -e "${RED}警告：彻底卸载会删除 BTCPay 本地目录和 Docker volumes。${NC}"
    echo -e "${RED}包括 Bitcoin 节点数据、BTCPay 数据库、LND 钱包/通道数据等。${NC}"
    echo -e "${YELLOW}卸载后重新安装需要重新同步，时间可能很长，请确认已备份。${NC}"
    read -p "请输入 yes 确认彻底卸载: " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}已取消彻底卸载。${NC}"
        return 0
    fi
    uninstall_btcpay
}


get_saved_btcpay_host() {
    if [ -f "$BTCPAY_ENV_FILE" ]; then
        grep -E '^BTCPAY_HOST=' "$BTCPAY_ENV_FILE" | tail -n1 | cut -d= -f2-
    fi
}

read_btcpay_host() {
    local saved_host
    saved_host="$(get_saved_btcpay_host)"
    if [ -n "$saved_host" ]; then
        read -p "请输入你的域名 (例如 btcpay.example.com，回车沿用 $saved_host): " MY_HOST
        MY_HOST="${MY_HOST:-$saved_host}"
    else
        while [ -z "$MY_HOST" ]; do
            read -p "请输入你的域名 (例如 btcpay.example.com): " MY_HOST
            if [ -z "$MY_HOST" ]; then
                echo -e "${RED}域名不能为空。${NC}"
            fi
        done
    fi
}

get_btcpay_container_name() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(generated_btcpayserver_1|btcpayserver)$' | head -n1
}

get_running_btcpay_host() {
    local container host external_url
    container="$(get_btcpay_container_name)"
    if [ -n "$container" ]; then
        host="$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^BTCPAY_HOST=//p' | head -n1)"
        external_url="$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^BTCPAY_EXTERNALURL=//p' | head -n1)"
        if [ -n "$host" ]; then
            echo "$host"
            return 0
        fi
        if [ -n "$external_url" ]; then
            echo "$external_url" | sed -E 's#^https?://([^/]+)/?.*$#\1#'
            return 0
        fi
    fi
    get_saved_btcpay_host
}

print_btcpay_info() {
    local host="${BTCPAY_HOST:-$(get_running_btcpay_host)}"
    local bind="${NOREVERSEPROXY_HTTP_PORT:-$BTCPAY_HTTP_BIND}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}BTCPay Server 配置信息${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "安装目录: ${CYAN}${BTCPAY_DIR}${NC}"
    echo -e "域名: ${CYAN}${host}${NC}"
    echo -e "BTCPay 内部HTTP映射: ${CYAN}${bind}${NC}"
    echo -e "反代模式: ${CYAN}使用现有 Nginx，BTCPay 不启动自带 nginx/letsencrypt${NC}"
    echo -e "Nginx 反代目标: ${CYAN}http://127.0.0.1:10080${NC}"
    echo -e "公网访问地址: ${CYAN}https://${host}/${NC}"
    echo -e "${YELLOW}如果后期只允许本机访问，把脚本里的 BTCPAY_HTTP_BIND 改为 127.0.0.1:10080 后运行更新。${NC}"
}

# [核心安装逻辑]
do_install() {
    check_env
    mkdir -p "$INSTALL_DIR"
    if [ ! -d "$BTCPAY_DIR" ]; then
        cd "$INSTALL_DIR"
        git clone https://github.com/btcpayserver/btcpayserver-docker
        cd "$BTCPAY_DIR"
    else
        cd "$BTCPAY_DIR"
    fi

    # 获取域名：BTCPay 需要它生成外部访问地址、回调地址和后台 URL。
    read_btcpay_host
    export BTCPAY_HOST="$MY_HOST"
    export NBITCOIN_NETWORK="mainnet"
    export BTCPAYGEN_CRYPTO1="btc"
    # 使用现有 Nginx 反代：BTCPay 只暴露 HTTP 端口，不启动自带 nginx/letsencrypt。
    # 反代 none 模式使用 NOREVERSEPROXY_HTTP_PORT；后期如需仅本机访问，改 BTCPAY_HTTP_BIND 即可。
    export BTCPAYGEN_REVERSEPROXY="none"
    export BTCPAY_PROTOCOL="http"
    export NOREVERSEPROXY_HTTP_PORT="$BTCPAY_HTTP_BIND"
    unset REVERSEPROXY_HTTP_PORT
    apply_btcpay_env_overrides

    if [[ "$1" == "pruned" ]]; then
        export BTCPAYGEN_LIGHTNING="lnd"
        export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-xs"
        echo -e "${GREEN}模式: 裁剪 + LND 闪电网络${NC}"
    else
        unset BTCPAYGEN_LIGHTNING
        unset BTCPAYGEN_ADDITIONAL_FRAGMENTS
        echo -e "${GREEN}模式: 全量索引 (无闪电网络)${NC}"
    fi

    . ./btcpay-setup.sh -i
    print_btcpay_info
}

# [更新逻辑：沿用现有 Nginx 反代模式]
do_update() {
    check_env
    cd "$BTCPAY_DIR" || { echo -e "${RED}未找到 BTCPay 安装目录：$BTCPAY_DIR${NC}"; return 1; }
    export BTCPAYGEN_REVERSEPROXY="none"
    export BTCPAY_PROTOCOL="http"
    export NOREVERSEPROXY_HTTP_PORT="$BTCPAY_HTTP_BIND"
    unset REVERSEPROXY_HTTP_PORT
    apply_btcpay_env_overrides
    . ./btcpay-update.sh
    print_btcpay_info
}

show_menu() {
    local dir_status container_status current_host
    clear
    if [ -d "$BTCPAY_DIR" ]; then
        dir_status="${GREEN}目录已存在：$BTCPAY_DIR${NC}"
    else
        dir_status="${YELLOW}暂无：$BTCPAY_DIR${NC}"
    fi

    if [ -n "$(get_btcpay_container_name)" ]; then
        container_status="${GREEN}BTCPay 运行中${NC}"
    else
        container_status="${YELLOW}未安装或未运行${NC}"
    fi

    current_host="$(get_running_btcpay_host)"
    [ -z "$current_host" ] && current_host="未安装"

    echo -e "${GREEN}==========================================${NC}"
    echo -e "${YELLOW}    BTCPay Server 精简管理 (FalconVM)    ${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "状态：${dir_status}"
    echo -e "容器：${container_status}"
    echo "------------------------------------------"
    echo -e "${RED}外部访问域名必须一致${NC}"
    echo -e "${YELLOW}${current_host}${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo "1. 安装 (裁剪模式 + LND，建议50GB+ 存储)"
    echo "2. 更新 (Update)"
    echo "3. 卸载 (需确认，谨慎操作)"
    echo "------------------------------------------"
    echo "11. 全量安装 (不裁剪, 无闪电网络，2026/9月建议1TB+，后续需更多存储)"
    echo "12. 全量更新"
    echo "13. 彻底卸载 (卸载后需要重新同步，时间可能很长，谨慎操作)"
    echo "------------------------------------------"
    echo "15. 停止服务 (Down，保留数据)"
    echo "16. 启动容器 (按现有配置拉起)"
    echo -e "17. ${CYAN}重载系统 Nginx${NC}"
    echo "0. 退出"
    echo "------------------------------------------"
}

while true; do
    show_menu
    read -p "选择 [0-17]: " choice
    case $choice in
        1)  do_install "pruned" ;;
        2)  do_update ;;
        3)  uninstall_btcpay_confirm ;;
        11) do_install "full" ;;
        12) do_update ;;
        13) uninstall_btcpay_confirm ;;
        15) cd "$BTCPAY_DIR" && . ./btcpay-down.sh ;;
        16) cd "$BTCPAY_DIR" && docker-compose -f "$COMPOSE_FILE" up -d && print_btcpay_info ;;
        17) echo -e "${YELLOW}正在重启系统 Nginx 容器...${NC}"
            docker restart nginx
            echo -e "${GREEN}Nginx 已重启。${NC}" ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}无效选择${NC}" ;;
    esac
    echo -e "\n按回车返回菜单..."
    read
done
