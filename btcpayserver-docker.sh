#!/bin/bash

# 配置路径
INSTALL_DIR="/home/docker"
BTCPAY_DIR="$INSTALL_DIR/btcpayserver-docker"

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
    echo -e "当前状态: $([ -d "$BTCPAY_DIR" ] && echo -e "${GREEN}已安装${NC}" || echo -e "${RED}未安装${NC}")"
    echo -e "安装目录: ${BTCPAY_DIR}"
    echo "------------------------------------------"
    echo -e "${YELLOW}[ 推荐：裁剪模式 + 闪电网络 ]${NC}"
    echo "1. 安装 (省空间, 含LND)"
    echo "2. 更新"
    echo -e "3. ${YELLOW}全量备份 (含区块数据 - 备份后自动重启)${NC}"
    echo "4. 恢复 (从 /home 下的备份包恢复)"
    echo "5. 卸载 (含清理数据)"
    echo "6. 快速备份 (仅配置 - 备份后自动重启)"
    echo "------------------------------------------"
    echo -e "${RED}[ 进阶：全量模式 - 需 1TB 磁盘 ]${NC}"
    echo "11. 全量安装 (不裁剪, 无闪电网络)"
    echo "12. 全量更新"
    echo "13. 全量备份 (含完整账本 - 备份后自动重启)"
    echo "14. 全量恢复"
    echo "15. 全量卸载"
    echo "------------------------------------------"
    echo "0. 退出"
    echo "------------------------------------------"
}

setup_env() {
    # 自动获取或输入域名
    if [ -z "$BTCPAY_HOST" ]; then
        read -p "请输入你的域名 (例如: btcpay.yourdomain.com): " MY_HOST
        export BTCPAY_HOST="$MY_HOST"
    fi
    export NBITCOIN_NETWORK="mainnet"
    export BTCPAYGEN_CRYPTO1="btc"
    export BTCPAYGEN_REVERSEPROXY="nginx"
    export BTCPAY_DOCKER_REPO_DIR="$BTCPAY_DIR"
    
    if [ "$1" == "standard" ]; then
        export BTCPAYGEN_LIGHTNING="lnd"
        export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-xs"
    else
        unset BTCPAYGEN_LIGHTNING
        unset BTCPAYGEN_ADDITIONAL_FRAGMENTS
    fi
}

do_install() {
    sudo apt update && sudo apt install git curl -y
    sudo mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    if [ ! -d "$BTCPAY_DIR" ]; then
        sudo git clone https://github.com/btcpayserver/btcpayserver-docker
    fi
    cd $BTCPAY_DIR
    setup_env $1
    . ./btcpay-setup.sh -i
}

# 核心备份逻辑：包含停止与重启
run_backup() {
    local mode=$1 
    local env_type=$2
    
    if [ ! -d "$BTCPAY_DIR" ]; then
        echo -e "${RED}错误：未找到安装目录，无法备份。${NC}"
        return
    fi

    echo -e "${YELLOW}正在停止 BTCPay 服务以确保数据一致性...${NC}"
    cd $BTCPAY_DIR && . ./btcpay-down.sh
    
    local timestamp=$(date +%F_%H%M)
    local filename=""
    
    if [ "$mode" == "fast" ]; then
        filename="/home/btcpay_config_$timestamp.tar.gz"
        echo -e "${YELLOW}正在执行：快速备份（排除区块数据）...${NC}"
        tar -czf "$filename" -C $INSTALL_DIR btcpayserver-docker --exclude="*.dat" --exclude="blocks" --exclude="chainstate"
    else
        filename="/home/btcpay_full_data_$timestamp.tar.gz"
        echo -e "${YELLOW}正在执行：全量备份（含区块数据）...${NC}"
        tar -czf "$filename" -C $INSTALL_DIR btcpayserver-docker
    fi
    
    echo -e "${GREEN}备份成功！文件已存至: $filename${NC}"
    
    echo -e "${YELLOW}正在重新启动服务...${NC}"
    setup_env "$env_type"
    . ./btcpay-setup.sh
    echo -e "${GREEN}服务已尝试重新拉起。${NC}"
}

do_restore() {
    echo -e "${YELLOW}正在扫描 /home 目录下的备份文件...${NC}"
    backups=($(ls /home/btcpay_*.tar.gz 2>/dev/null))
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}未找到任何备份文件。${NC}"; return
    fi
    for i in "${!backups[@]}"; do echo "$i) ${backups[$i]}"; done
    read -p "选择要恢复的编号: " b_idx
    selected_file="${backups[$b_idx]}"
    
    if [ -f "$selected_file" ]; then
        echo -e "${YELLOW}准备恢复，正在清理旧环境...${NC}"
        [ -d "$BTCPAY_DIR" ] && cd $BTCPAY_DIR && . ./btcpay-down.sh && mv $BTCPAY_DIR "/tmp/btcpayserver_old_$(date +%s)"
        sudo mkdir -p $INSTALL_DIR
        tar -xzf "$selected_file" -C $INSTALL_DIR
        echo -e "${GREEN}数据解压完成，正在启动服务...${NC}"
        cd $BTCPAY_DIR && setup_env "$1" && . ./btcpay-setup.sh -i
    fi
}

# 交互主循环
while true; do
    show_menu
    read -p "选择 [0-15]: " choice
    case $choice in
        1)  do_install "standard" ;;
        2)  cd $BTCPAY_DIR && setup_env "standard" && . ./btcpay-setup.sh ;;
        3)  run_backup "full" "standard" ;;
        4)  do_restore "standard" ;;
        5)  cd $BTCPAY_DIR && . ./btcpay-down.sh && read -p "确认删除所有数据? (y/n): " cf && [[ "$cf" == "y" ]] && rm -rf $BTCPAY_DIR ;;
        6)  run_backup "fast" "standard" ;;

        11) do_install "full" ;;
        12) cd $BTCPAY_DIR && setup_env "full" && . ./btcpay-setup.sh ;;
        13) run_backup "full" "full" ;;
        14) do_restore "full" ;;
        15) cd $BTCPAY_DIR && . ./btcpay-down.sh ;;
        0)  echo "退出。"; exit 0 ;;
        *)  echo "无效输入"; sleep 1 ;;
    esac
    echo -e "\n${GREEN}操作执行完毕，按回车键返回菜单...${NC}"
    read
done
