#!/bin/bash

# 配置路径
INSTALL_DIR="/home/docker"
BTCPAY_DIR="$INSTALL_DIR/btcpayserver-docker"
COMPOSE_FILE="Generated/docker-compose.generated.yml"

# 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo -e "\033[0;31m请使用 root 权限或 sudo 运行此脚本。\033[0m"
  exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_menu() {
    clear
    echo -e "${GREEN}==========================================${NC}"
    echo -e "${YELLOW}    BTCPay Server 管理脚本 (FalconVM版)    ${NC}"
    echo -e "${GREEN}==========================================${NC}"
    echo -e "当前目录: ${BTCPAY_DIR}"
    echo "------------------------------------------"
    echo -e "${YELLOW}[ 常用功能 ]${NC}"
    echo "1. 安装 (省空间, 含LND)"
    echo "2. 更新 (Update)"
    echo -e "3. ${YELLOW}全量备份 (含已同步的裁剪区块数据)${NC}"
    echo "4. 恢复 (从备份包还原并重启)"
    echo "5. 卸载 (含清理数据)"
    echo "6. 快速备份 (仅配置, 排除区块数据)"
    echo "------------------------------------------"
    echo -e "${RED}[ 进阶功能 ]${NC}"
    echo "11. 全量安装 (不裁剪, 无闪电网络)"
    echo "12. 全量更新"
    echo "13. 全量备份 (含所有数据)"
    echo "14. 全量恢复"
    echo "15. 停止所有容器"
    echo -e "16. ${GREEN}手动启动/重启服务${NC}"
    echo "------------------------------------------"
    echo "0. 退出"
    echo "------------------------------------------"
}

# 确保环境变量正确（启动前调用）
setup_env() {
    if [ -z "$BTCPAY_HOST" ]; then
        read -p "请输入你的域名 (例如: btcpay.yourdomain.com): " MY_HOST
        export BTCPAY_HOST="$MY_HOST"
    fi
    export NBITCOIN_NETWORK="mainnet"
    export BTCPAYGEN_CRYPTO1="btc"
    export BTCPAYGEN_REVERSEPROXY="nginx"
    export BTCPAY_DOCKER_REPO_DIR="$BTCPAY_DIR"
    [[ "$1" == "standard" ]] && export BTCPAYGEN_LIGHTNING="lnd" && export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-xs"
}

# 统一启动函数
start_service() {
    echo -e "${YELLOW}正在启动服务...${NC}"
    cd $BTCPAY_DIR
    if [ -f "$COMPOSE_FILE" ]; then
        docker-compose -f "$COMPOSE_FILE" up -d
    else
        echo -e "${RED}未发现生成配置文件，尝试执行 setup 启动...${NC}"
        . ./btcpay-setup.sh
    fi
}

# 执行安装
do_install() {
    sudo apt update && sudo apt install git curl -y
    sudo mkdir -p $INSTALL_DIR && cd $INSTALL_DIR
    [ ! -d "$BTCPAY_DIR" ] && sudo git clone https://github.com/btcpayserver/btcpayserver-docker
    cd $BTCPAY_DIR
    setup_env $1
    . ./btcpay-setup.sh -i
}

# 备份逻辑
run_backup() {
    local mode=$1
    echo -e "${YELLOW}正在停止容器...${NC}"
    cd $BTCPAY_DIR && . ./btcpay-down.sh
    
    local timestamp=$(date +%F_%H%M)
    if [ "$mode" == "fast" ]; then
        local filename="/home/btcpay_config_$timestamp.tar.gz"
        tar -czf "$filename" -C $INSTALL_DIR btcpayserver-docker --exclude="*.dat" --exclude="blocks" --exclude="chainstate"
    else
        local filename="/home/btcpay_full_$timestamp.tar.gz"
        tar -czf "$filename" -C $INSTALL_DIR btcpayserver-docker
    fi
    echo -e "${GREEN}备份成功：$filename${NC}"
    start_service
}

# 恢复逻辑
do_restore() {
    backups=($(ls /home/btcpay_*.tar.gz 2>/dev/null))
    [[ ${#backups[@]} -eq 0 ]] && echo "无备份文件" && return
    for i in "${!backups[@]}"; do echo "$i) ${backups[$i]}"; done
    read -p "选择编号: " b_idx
    selected_file="${backups[$b_idx]}"
    if [ -f "$selected_file" ]; then
        [ -d "$BTCPAY_DIR" ] && cd $BTCPAY_DIR && . ./btcpay-down.sh && mv $BTCPAY_DIR "/tmp/btc_old_$(date +%s)"
        tar -xzf "$selected_file" -C $INSTALL_DIR
        start_service
    fi
}

while true; do
    show_menu
    read -p "选择 [0-16]: " choice
    case $choice in
        1)  do_install "standard" ;;
        2)  cd $BTCPAY_DIR && setup_env "standard" && . ./btcpay-setup.sh ;;
        3)  run_backup "full" ;;
        4)  do_restore "standard" ;;
        5)  cd $BTCPAY_DIR && . ./btcpay-down.sh && read -p "删数据? (y/n): " cf && [[ "$cf" == "y" ]] && rm -rf $BTCPAY_DIR ;;
        6)  run_backup "fast" ;;
        11) do_install "full" ;;
        12) cd $BTCPAY_DIR && setup_env "full" && . ./btcpay-setup.sh ;;
        13) run_backup "full" ;;
        14) do_restore "full" ;;
        15) cd $BTCPAY_DIR && . ./btcpay-down.sh ;;
        16) start_service ;;
        0)  exit 0 ;;
    esac
    echo -e "\n按回车返回..."
    read
done
