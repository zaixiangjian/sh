#!/bin/bash

# 配置路径
INSTALL_DIR="/home/docker"
BTCPAY_DIR="$INSTALL_DIR/btcpayserver-docker"
COMPOSE_FILE="Generated/docker-compose.generated.yml"

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

    # 获取域名
    read -p "请输入你的域名 (例如 btcpay.example.com): " MY_HOST
    export BTCPAY_HOST="$MY_HOST"
    export NBITCOIN_NETWORK="mainnet"
    export BTCPAYGEN_CRYPTO1="btc"
    export BTCPAYGEN_REVERSEPROXY="nginx"

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
}

show_menu() {
    clear
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${YELLOW}    BTCPay Server 精简管理 (FalconVM)    ${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo "1. 安装 (裁剪模式 + LND)"
    echo "2. 更新 (Update)"
    echo "3. 卸载 (含清理数据)"
    echo "------------------------------------------"
    echo "11. 全量安装 (不裁剪, 无闪电网络)"
    echo "12. 全量更新"
    echo "13. 彻底卸载 (含本地目录)"
    echo "------------------------------------------"
    echo "15. 停止服务 (Down)"
    echo "16. 启动容器 (直接拉起)"
    echo -e "17. ${CYAN}强制申请/续期 SSL 证书${NC}"
    echo "0. 退出"
    echo "------------------------------------------"
}

while true; do
    show_menu
    read -p "选择 [0-17]: " choice
    case $choice in
        1)  do_install "pruned" ;;
        2)  cd "$BTCPAY_DIR" && . ./btcpay-update.sh ;;
        3)  cd "$BTCPAY_DIR" && . ./btcpay-down.sh && echo -e "${RED}容器已停止并移除。${NC}" ;;
        11) do_install "full" ;;
        12) cd "$BTCPAY_DIR" && . ./btcpay-update.sh ;;
        13) if [ -d "$BTCPAY_DIR" ]; then
                cd "$BTCPAY_DIR" && . ./btcpay-down.sh
                rm -rf "$BTCPAY_DIR"
                echo -e "${RED}所有数据已彻底清除。${NC}"
            fi ;;
        15) cd "$BTCPAY_DIR" && . ./btcpay-down.sh ;;
        16) cd "$BTCPAY_DIR" && docker-compose -f "$COMPOSE_FILE" up -d ;;
        17) echo -e "${YELLOW}正在强制更新 Nginx 及其证书配置...${NC}"
            cd "$BTCPAY_DIR"
            . ./btcpay-setup.sh -i
            docker restart letsencrypt-nginx-proxy-companion
            echo -e "${GREEN}任务已提交，请观察 1 分钟。${NC}" ;;
        0)  exit 0 ;;
        *)  echo -e "${RED}无效选择${NC}" ;;
    esac
    echo -e "\n按回车返回菜单..."
    read
done
