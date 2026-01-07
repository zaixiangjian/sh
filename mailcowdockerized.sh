#!/bin/bash
# ==========================
# Mailcow 一键管理脚本
# ==========================

# 固定路径
MAILCOW_DIR="/home/docker/mailcow-dockerized"
BACKUP_DIR="/home"
BACKUP_PREFIX="mailcow-beifen"

# 工具检查
command -v docker >/dev/null 2>&1 || { echo "❌ Docker 未安装，请先安装 Docker"; exit 1; }
command -v docker-compose >/dev/null 2>&1 || { echo "❌ docker-compose 未安装"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq 未安装，请先运行：sudo apt install -y jq"; exit 1; }

# 彩色输出
green() { echo -e "\e[32m$1\e[0m"; }
red()   { echo -e "\e[31m$1\e[0m"; }
yellow(){ echo -e "\e[33m$1\e[0m"; }

# --------------------------
# 安装 Mailcow
# --------------------------
install_mailcow() {
    mkdir -p "$MAILCOW_DIR"
    cd "$MAILCOW_DIR" || exit 1

    # 克隆最新仓库
    if [[ ! -d "$MAILCOW_DIR/.git" ]]; then
        git clone https://github.com/mailcow/mailcow-dockerized . || { red "❌ Git clone 失败"; exit 1; }
    else
        git pull
    fi

    # 安装依赖
    sudo apt update
    sudo apt install -y jq curl

    # 生成配置
    bash generate_config.sh

    # 拉取镜像并启动
    docker compose pull
    docker compose up -d

    # 读取域名
    MAILCOW_HOSTNAME=$(grep '^MAILCOW_HOSTNAME=' mailcow.conf | cut -d= -f2)

    clear
    green "✅ Mailcow 安装完成！"
    echo "📂 安装目录: $MAILCOW_DIR"
    echo "🌐 管理后台: https://$MAILCOW_HOSTNAME/admin"
}

# --------------------------
# 更新 Mailcow
# --------------------------
update_mailcow() {
    cd "$MAILCOW_DIR" || { red "❌ 安装目录不存在"; return; }
    git pull
    docker compose pull
    docker compose up -d
    green "✅ Mailcow 已更新完成！"
}

# --------------------------
# 备份 Mailcow
# --------------------------
backup_mailcow() {
    TIMESTAMP=$(date +%Y%m%d_%H%M)
    BACKUP_FILE="$BACKUP_DIR/${BACKUP_PREFIX}_$TIMESTAMP.tar.gz"

    if [[ ! -d "$MAILCOW_DIR" ]]; then
        red "❌ 安装目录不存在，无法备份"
        return
    fi

    tar czf "$BACKUP_FILE" -C "$MAILCOW_DIR" .
    green "✅ 备份完成：$BACKUP_FILE"
}

# --------------------------
# 恢复 Mailcow
# --------------------------
restore_mailcow() {
    echo "⚠️ 你即将恢复 Mailcow，可能覆盖当前安装！"
    read -p "确定要继续吗？输入 Y 确认，其它键取消: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        red "❌ 恢复已取消"
        return
    fi

    # 查找最新备份
    backup_file=$(ls /home/${BACKUP_PREFIX}_*.tar.gz 2>/dev/null | tail -n1)
    if [[ -z "$backup_file" ]]; then
        red "❌ 未找到备份文件 /home/${BACKUP_PREFIX}_*.tar.gz"
        return
    fi

    yellow "📦 找到备份：$backup_file"

    # 停止旧容器
    cd "$MAILCOW_DIR" || mkdir -p "$MAILCOW_DIR"
    docker compose down 2>/dev/null

    # 删除旧目录
    rm -rf "$MAILCOW_DIR"/*

    # 解压备份
    tar xzf "$backup_file" -C "$MAILCOW_DIR"

    # 启动 Mailcow
    cd "$MAILCOW_DIR" || exit 1
    docker compose up -d

    # 输出完成信息
    MAILCOW_HOSTNAME=$(grep '^MAILCOW_HOSTNAME=' mailcow.conf | cut -d= -f2)
    clear
    green "✅ Mailcow 恢复完成！"
    echo "📂 安装目录: $MAILCOW_DIR"
    echo "🌐 管理后台: https://$MAILCOW_HOSTNAME/admin"
}

# --------------------------
# 卸载 Mailcow
# --------------------------
uninstall_mailcow() {
    echo "⚠️ 卸载会删除安装目录及容器！"
    read -p "确定要继续吗？输入 Y 确认，其它键取消: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        red "❌ 卸载已取消"
        return
    fi

    cd "$MAILCOW_DIR" || return
    docker compose down
    rm -rf "$MAILCOW_DIR"
    green "✅ Mailcow 已卸载完成！"
}

# --------------------------
# 菜单
# --------------------------
while true; do
    echo ""
    echo "============================"
    echo " Mailcow 管理脚本"
    echo "============================"
    echo "1) 安装 Mailcow"
    echo "2) 更新 Mailcow"
    echo "3) 备份 Mailcow"
    echo "4) 恢复 Mailcow"
    echo "9) 卸载 Mailcow"
    echo "0) 退出"
    echo "============================"
    read -p "请选择操作 [0-9]: " choice
    case "$choice" in
        1) install_mailcow ;;
        2) update_mailcow ;;
        3) backup_mailcow ;;
        4) restore_mailcow ;;
        9) uninstall_mailcow ;;
        0) exit 0 ;;
        *) red "❌ 无效选项，请重新输入" ;;
    esac
done
