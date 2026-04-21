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
    echo -e "当前安装目录: ${BTCPAY_DIR}"
    echo "------------------------------------------"
    echo -e "${YELLOW}[ 推荐：裁剪模式 + 闪电网络 ]${NC}"
    echo "1. 安装 (省空间, 含LND)"
    echo "2. 更新"
    echo -e "3. ${YELLOW}全量备份 (含已同步的裁剪区块数据)${NC}"
    echo "4. 恢复 (从 /home 下的备份包恢复并重启)"
    echo "5. 卸载 (含清理数据)"
    echo "6. 快速备份 (仅配置, 排除区块数据)"
    echo "------------------------------------------"
    echo -e "${RED}[ 进阶：全量模式 - 需 1TB 磁盘 ]${NC}"
    echo "11. 全量安装 (不裁剪, 无闪电网络)"
    echo "12. 全量更新"
    echo "13. 全量备份 (含数百GB完整账本)"
    echo "14. 全量恢复"
    echo "15. 全量卸载"
    echo "------------------------------------------"
    echo "0. 退出"
    echo "------------------------------------------"
}

# 环境变量配置
setup_env() {
    if [ -z "$BTCPAY_HOST" ]; then
        read -p "请输入你的域名 (例如: btcpay.yourdomain.com): " MY_HOST
        export BTCPAY_HOST="$MY_HOST"
    fi
    export NBITCOIN_NETWORK="mainnet"
    export BTCPAYGEN_CRYPTO1="btc"
    export BTCPAYGEN_REVERSEPROXY="nginx"
    export BTCPAY_DOCKER_REPO_DIR="$BTCPAY_DIR"
    
    if [ "$1" == "standard" ]; then
        # 推荐模式：带裁剪和闪电网络
        export BTCPAYGEN_LIGHTNING="lnd"
        export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-xs"
    else
        # 进阶模式：全量节点
        unset BTCPAYGEN_LIGHTNING
        unset BTCPAYGEN_ADDITIONAL_FRAGMENTS
    fi
}

# 执行安装
do_install() {
    echo -e "${YELLOW}准备安装环境...${NC}"
    sudo apt update && sudo apt install git curl -y
    sudo mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    if [ ! -d "$BTCPAY_DIR" ]; then
        sudo git clone https://github.com/btcpayserver/btcpayserver-docker
    fi
    cd $BTCPAY_DIR
    setup_env $1
    echo -e "${GREEN}正在启动安装脚本...${NC}"
    . ./btcpay-setup.sh -i
}

# 备份逻辑 (3, 6, 13)
run_backup() {
    local mode=$1 # "fast" 或 "full"
    if [ ! -d "$BTCPAY_DIR" ]; then
        echo -e "${RED}错误：未找到安装目录，无法备份。${NC}"; return
    fi

    echo -e "${YELLOW}正在停止服务以保证备份完整性...${NC}"
    cd $BTCPAY_DIR && . ./btcpay-down.sh
    
    local timestamp=$(date +%F_%H%M)
    local filename=""
    
    if [ "$mode" == "fast" ]; then
        filename="/home/btcpay_config_$timestamp.tar.gz"
        echo -e "${YELLOW}正在执行快速备份（仅核心配置）...${NC}"
        tar -czf "$filename" -C $INSTALL_DIR btcpayserver-docker --exclude="*.dat" --exclude="blocks" --exclude="chainstate"
    else
        filename="/home/btcpay_full_data_$timestamp.tar.gz"
        echo -e "${YELLOW}正在执行全量备份（含区块数据，请耐心等待）...${NC}"
        tar -czf "$filename" -C $INSTALL_DIR btcpayserver-docker
    fi
    
    echo -e "${GREEN}备份成功：$filename${NC}"
    echo -e "${YELLOW}正在自动重启服务...${NC}"
    . ./btcpay-setup.sh
}

# 恢复逻辑 (4, 14)
do_restore() {
    echo -e "${YELLOW}正在查找 /home 下的备份文件...${NC}"
    backups=($(ls /home/btcpay_*.tar.gz 2>/dev/null))
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}未找到备份文件(btcpay_*.tar.gz)${NC}"; return
    fi

    for i in "${!backups[@]}"; do echo "$i) ${backups[$i]}"; done
    read -p "请输入备份文件编号: " b_idx
    selected_file="${backups[$b_idx]}"

    if [ -f "$selected_file" ]; then
        echo -e "${RED}正在清理当前数据并恢复备份...${NC}"
        [ -d "$BTCPAY_DIR" ] && cd $BTCPAY_DIR && . ./btcpay-down.sh && mv $BTCPAY_DIR "/tmp/btcpayserver_old_$(date +%s)"
        
        sudo mkdir -p $INSTALL_DIR
        tar -xzf "$selected_file" -C $INSTALL_DIR
        
        echo -e "${GREEN}数据恢复成功！正在自动启动服务...${NC}"
        cd $BTCPAY_DIR
        setup_env "$1"
        . ./btcpay-setup.sh -i
    else
        echo -e "${RED}无效选项。${NC}"
    fi
}

# 主循环
while true; do
    show_menu
    read -p "请输入指令 [0-15]: " choice
    case $choice in
        1)  do_install "standard" ;;
        2)  if [ -d "$BTCPAY_DIR" ]; then cd $BTCPAY_DIR && setup_env "standard" && . ./btcpay-setup.sh; else echo "未安装"; fi ;;
        3)  run_backup "full" ;;
        4)  do_restore "standard" ;;
        5)  if [ -d "$BTCPAY_DIR" ]; then 
                cd $BTCPAY_DIR && . ./btcpay-down.sh
                read -p "确认彻底删除数据目录吗? (y/n): " cf
                [[ "$cf" == "y" ]] && rm -rf $BTCPAY_DIR && echo "数据已清理。"
            fi ;;
        6)  run_backup "fast" ;;

        11) do_install "full" ;;
        12) if [ -d "$BTCPAY_DIR" ]; then cd $BTCPAY_DIR && setup_env "full" && . ./btcpay-setup.sh; else echo "未安装"; fi ;;
        13) run_backup "full" ;;
        14) do_restore "full" ;;
        15) if [ -d "$BTCPAY_DIR" ]; then cd $BTCPAY_DIR && . ./btcpay-down.sh; fi ;;

        0)  echo "感谢使用，再见！"; exit 0 ;;
        *)  echo -e "${RED}无效输入，请重新选择。${NC}"; sleep 1 ;;
    esac
    echo -e "\n${GREEN}操作执行完毕。${NC}按回车键返回主菜单..."
    read
done
