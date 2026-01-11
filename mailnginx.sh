#!/usr/bin/env bash
set -e

INSTALL_DIR="/home/docker"
MAILCOW_DIR="${INSTALL_DIR}/mailcow-dockerized"
BACKUP_DIR="/home/mail"

# 检查是否 root
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# 菜单函数
show_menu() {
    clear
    echo "=============================="
    echo " Mailcow 管理脚本"
    echo "=============================="
    echo "Mailcow: Dockerized"
    echo "支持多域、多账户，内置 SMTP/IMAP/POP3、反垃圾邮件（Rspamd）、Webmail（SOGo）、管理面板。"
    echo "自动 DKIM/SPF/DMARC 占用资源稍大（2GB+ 内存推荐）"
    echo "开源地址: https://github.com/mailcow/mailcow-dockerized"
    echo "=============================="
    echo "1) 安装 Mailcow"
    echo "2) 更新 Mailcow"
    echo "3) 备份 Mailcow"
    echo "4) 恢复 手动创建/home/docker 安装docker"
    echo "9) 卸载 Mailcow"
    echo "0) 退出"
    echo "=============================="
}

read_choice() {
    read -rp "请输入选项 [0-9]: " choice
    case "$choice" in
        1) install_mailcow ;;
        2) update_mailcow ;;
        3) backup_mailcow ;;
        4) restore_mailcow ;;
        9) uninstall_mailcow ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
}

# 安装
install_mailcow() {
    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    echo "🔧 安装系统依赖..."
    apt update
    apt install -y ca-certificates curl gnupg lsb-release git jq

    # Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo "🐳 安装 Docker..."
        curl -fsSL https://get.docker.com | sh
    fi

    # docker-compose 插件
    if ! docker compose version >/dev/null 2>&1; then
        echo "🐳 安装 docker-compose..."
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -SL https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-linux-x86_64 \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi

    systemctl enable docker
    systemctl restart docker

    # 下载 Mailcow
    if [ ! -d "${MAILCOW_DIR}" ]; then
        echo "📥 克隆 Mailcow 仓库..."
        git clone https://github.com/mailcow/mailcow-dockerized.git
    else
        echo "📁 Mailcow 目录已存在，跳过 clone"
    fi

    cd "${MAILCOW_DIR}"

    # —— 交互式输入部分（更新） —— #

    # 强制输入 MAILCOW_HOSTNAME
    while true; do
        read -rp "请输入 Mailcow 域名（如 mail.example.com，必填）: " MAILCOW_HOSTNAME
        if [ -n "$MAILCOW_HOSTNAME" ]; then
            break
        fi
        echo "❌ 域名不能为空，请重新输入"
    done

    # 时区默认 Asia/Shanghai
    read -rp "请输入时区（默认 Asia/Shanghai）: " TIMEZONE
    TIMEZONE=${TIMEZONE:-Asia/Shanghai}

    # 是否禁用 ClamAV
    read -rp "是否禁用 ClamAV（小内存 VPS 推荐 Y）[Y/n]: " DISABLE_CLAMAV
    DISABLE_CLAMAV=${DISABLE_CLAMAV:-Y}

    echo
    echo "➡ 域名: $MAILCOW_HOSTNAME"
    echo "➡ 时区: $TIMEZONE"
    echo "➡ 禁用 ClamAV: $DISABLE_CLAMAV"
    echo

    # —— 继续原来的安装流程 —— #

    echo "⚙️ 运行 Mailcow 配置生成脚本..."
    export MAILCOW_HOSTNAME TIMEZONE
    yes | bash generate_config.sh

    # 根据选择禁用 ClamAV
    if [[ "$DISABLE_CLAMAV" =~ ^[Yy]$ ]]; then
        sed -i 's/^SKIP_CLAMD=.*/SKIP_CLAMD=y/' mailcow.conf
    fi

    # 拉取镜像并启动
    echo "📦 拉取 Docker 镜像..."
    docker compose pull

    echo "🚀 启动 Mailcow..."
    docker compose up -d

    # 读取域名
    MAILCOW_HOSTNAME=$(grep '^MAILCOW_HOSTNAME=' mailcow.conf | cut -d= -f2)

    clear
    echo "------------------------------------------------"
    echo "✅ Mailcow 安装完成！"
    echo "📂 安装目录: ${MAILCOW_DIR}"
    echo "------------------------------------------------"
    echo "DNS配置"
    echo "A记录"
    echo "名称: mail"
    echo "值: 1.1.1.1"
    echo "------------------------------------------------"
    echo "CNAME有两个配置"
    echo "名称: autodiscover"
    echo "值: ${MAILCOW_HOSTNAME}"
    echo "------------------------------------------------"
    echo "名称: autoconfig"
    echo "值: ${MAILCOW_HOSTNAME}"
    echo "------------------------------------------------"
    echo "MX"
    echo "名称: @"
    echo "${MAILCOW_HOSTNAME}"
    echo "优先级10"
    echo "------------------------------------------------"
    echo "TXT"
    echo "@"
    echo "v=spf1 mx a -all"
    echo "------------------------------------------------"
    echo "名称: _dmarc"
    echo "值"
    echo "v=DMARC1; p=reject; aspf=s; adkim=s; fo=1; rua=mailto:noreply@你的域名.com"
    echo "------------------------------------------------"
    echo "dkim._domainkey"
    echo "查看你的域名获取"
    echo "https://${MAILCOW_HOSTNAME}/admin/mailbox"
    echo "------------------------------------------------"
    echo "🌐 管理后台"
    echo "https://${MAILCOW_HOSTNAME}/admin"
    echo "账号: admin"
    echo "密码: moohoo"
    echo "请尽快修改密码"
    echo "------------------------------------------------"
    read -rp "按回车继续..." _
}

# 更新
update_mailcow() {
    cd "${MAILCOW_DIR}"
    echo "📥 更新 Mailcow 仓库..."
    git pull
    echo "📦 更新 Docker 镜像..."
    docker compose pull
    echo "🚀 重启 Mailcow..."
    docker compose up -d
    echo "✅ 更新完成"
    read -rp "按回车继续..." _
}



# ------------------------------
# 备份 Mailcow（官方 nginx，全量）
# ------------------------------
backup_mailcow() {
    MAILCOW_DIR="/home/docker/mailcow-dockerized"
    BACKUP_FILE="/home/mailnginx-$(date +%F_%H%M%S).tar.gz"

    # 检查 Mailcow 是否存在
    if [ ! -d "${MAILCOW_DIR}" ]; then
        echo "❌ Mailcow 未安装"
        read -rp "按回车继续..." _
        return
    fi

    echo "🛑 停止 Mailcow 容器，保证数据一致性..."
    cd "$MAILCOW_DIR"
    docker compose down

    echo "📦 检测 Docker 卷..."
    # 自动获取所有 mailcow 卷路径
    VOLUMES=()
    for VOL in $(docker volume ls --format '{{.Name}}' | grep mailcowdockerized_); do
        VOL_PATH="/var/lib/docker/volumes/${VOL}/_data"
        if [ -d "$VOL_PATH" ]; then
            VOLUMES+=("$VOL_PATH")
        else
            echo "⚠️ 卷不存在或路径不对：$VOL_PATH"
        fi
    done

    echo "📦 开始全量备份 Mailcow 主程序 + 所有卷..."
    tar czpf "$BACKUP_FILE" --ignore-failed-read "$MAILCOW_DIR" "${VOLUMES[@]}"

    echo "🚀 启动 Mailcow..."
    docker compose up -d

    echo "✅ 全量备份完成：$BACKUP_FILE"
    read -rp "按回车继续..." _
}


# ------------------------------
# 恢复 Mailcow（官方 nginx，全量）
# ------------------------------
restore_mailcow() {
    MAILCOW_DIR="/home/docker/mailcow-dockerized"

    FILE=$(ls /home/mailnginx-*.tar.gz 2>/dev/null | tail -n1)
    if [ -z "$FILE" ]; then
        echo "❌ 找不到备份文件"
        read -rp "按回车继续..." _
        return
    fi

    read -rp "⚠️ 确认恢复 ${FILE}？将覆盖当前 Mailcow！（yes/no）: " confirm
    [ "$confirm" != "yes" ] && echo "取消恢复" && read -rp "按回车继续..." _ && return

    echo "🔧 安装系统依赖..."
    apt update
    apt install -y ca-certificates curl gnupg lsb-release git jq

    # Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo "🐳 安装 Docker..."
        curl -fsSL https://get.docker.com | sh
    fi

    # docker-compose 插件
    if ! docker compose version >/dev/null 2>&1; then
        echo "🐳 安装 docker-compose..."
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -SL https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-linux-x86_64 \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi

    systemctl enable docker
    systemctl restart docker




    echo "🛑 停止 Mailcow..."
    [ -d "$MAILCOW_DIR" ] && cd "$MAILCOW_DIR" && docker compose down

    echo "🔓 解除不可变锁..."
    find "${MAILCOW_DIR}" -type f -exec chattr -i {} \; 2>/dev/null || true

    echo "📦 解压全量备份..."
    tar xzpf "$FILE" -C /

    echo "🚀 启动 Mailcow..."
    cd "$MAILCOW_DIR" && docker compose up -d

    echo "✅ 全量恢复完成"
    read -rp "按回车继续..." _
}




# 卸载
uninstall_mailcow() {
    read -rp "⚠️ 确认卸载 Mailcow？(yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo "取消卸载"
        read -rp "按回车继续..." _
        return
    fi
    cd "${MAILCOW_DIR}" || return
    echo "🛑 停止容器..."
    docker compose down
    echo "🗑️ 删除目录..."
    rm -rf "${MAILCOW_DIR}"
    echo "✅ 卸载完成"
    read -rp "按回车继续..." _
}

# 主循环
while true; do
    show_menu
    read_choice
done
