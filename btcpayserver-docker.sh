#!/bin/bash

# 配置路径
INSTALL_DIR="/home/docker"
BTCPAY_DIR="$INSTALL_DIR/btcpayserver-docker"

# 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 root 权限或 sudo 运行此脚本。"
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
    echo -e "${YELLOW}[ 推荐：裁剪模式 + 闪电网络 ]${NC}"
    echo "1. 安装 (省空间, 含LND)"
    echo "2. 更新"
    echo "3. 快速备份 (仅配置, 排除区块数据)"
    echo "4. 恢复 (从 /home 下的备份包恢复)"
    echo "5. 卸载 (含清理数据)"
    echo "------------------------------------------"
    echo -e "${RED}[ 进阶：全量模式 - 需 1TB 磁盘 ]${NC}"
    echo "11. 全量安装 (不裁剪, 无闪电网络)"
    echo "12. 全量更新"
    echo "13. 全量备份 (含所有数据)"
    echo "14. 全量恢复"
    echo "15. 全量卸载"
    echo "------------------------------------------"
    echo "0. 退出"
    echo "------------------------------------------"
}

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
        export BTCPAYGEN_LIGHTNING="lnd"
        export BTCPAYGEN_ADDITIONAL_FRAGMENTS="opt-save-storage-xs"
        echo -e "${GREEN}配置已加载：裁剪模式 + LND${NC}"
    else
        unset BTCPAYGEN_LIGHTNING
        unset BTCPAYGEN_ADDITIONAL_FRAGMENTS
        echo -e "${RED}配置已加载：全量账本模式 (无裁剪)${NC}"
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

# 恢复逻辑函数
do_restore() {
    echo -e "${YELLOW}正在扫描 /home 目录下的备份文件...${NC}"
    # 查找以 btcpay 开头并以 .tar.gz 结尾的文件
    backups=($(ls /home/btcpay_*.tar.gz 2>/dev/null))
    
    if [ ${#backups[@]} -eq 0 ]; then
        echo -e "${RED}错误：在 /home 下未找到任何备份文件 (btcpay_*.tar.gz)${NC}"
        return
    fi

    echo "发现以下备份文件："
    for i in "${!backups[@]}"; do
        echo "$i) ${backups[$i]}"
    done
    
    read -p "请选择要恢复的文件编号: " b_idx
    selected_file="${backups[$b_idx]}"

    if [ -f "$selected_file" ]; then
        echo -e "${YELLOW}正在停止当前服务并备份旧数据至 /tmp...${NC}"
        [ -d "$BTCPAY_DIR" ] && cd $BTCPAY_DIR && . ./btcpay-down.sh && mv $BTCPAY_DIR /tmp/btcpayserver_old_$(date +%s)
        
        echo -e "${GREEN}正在从 $selected_file 恢复数据...${NC}"
        sudo mkdir -p $INSTALL_DIR
        tar -xzf "$selected_file" -C $INSTALL_DIR
        
        echo -e "${GREEN}数据已还原，正在尝试启动...${NC}"
        cd $BTCPAY_DIR
        setup_env "$1"
        . ./btcpay-setup.sh -i
    else
        echo -e "${RED}无效的选择。${NC}"
    fi
}

while true; do
    show_menu
    read -p "请选择操作 [0-15]: " choice
    case $choice in
        1)  do_install "standard" ;;
        2)  cd $BTCPAY_DIR && setup_env "standard" && . ./btcpay-setup.sh ;;
        3)  # 快速备份
            cd $BTCPAY_DIR && . ./btcpay-down.sh
            tar -czf /home/btcpay_config_$(date +%F).tar.gz -C $INSTALL_DIR btcpayserver-docker --exclude="*.dat"
            echo -e "${GREEN}配置备份完成：/home/btcpay_config_$(date +%F).tar.gz${NC}"
            . ./btcpay-setup.sh ;;
        4)  do_restore "standard" ;;
        5)  cd $BTCPAY_DIR && . ./btcpay-down.sh
            read -p "是否删除所有硬盘数据? (y/n): " cf
            [[ "$cf" == "y" ]] && rm -rf $BTCPAY_DIR ;;

        11) do_install "full" ;;
        12) cd $BTCPAY_DIR && setup_env "full" && . ./btcpay-setup.sh ;;
        13) # 全量备份
            cd $BTCPAY_DIR && . ./btcpay-down.sh
            tar -czf /home/btcpay_full_$(date +%F).tar.gz -C $INSTALL_DIR btcpayserver-docker
            echo -e "${GREEN}全量备份完成：/home/btcpay_full_$(date +%F).tar.gz${NC}"
            . ./btcpay-setup.sh ;;
        14) do_restore "full" ;;
        15) cd $BTCPAY_DIR && . ./btcpay-down.sh ;;

        0)  exit 0 ;;
        *)  echo "无效选项"; sleep 1 ;;
    esac
    echo "操作完成，按任意键返回..."
    read -n 1
done
