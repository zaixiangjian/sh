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


# ------------------------------
# 查询并显示证书同步定时任务（不关心日志）
# ------------------------------
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
echo "=============================="
# Caddy 同步脚本
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshufuzhi.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 容器 nginx 证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ Caddy 证书同步定时任务不存在"
fi



    echo "=============================="

    echo "Mailcow: Dockerized"
    echo "支持多域、多账户，内置 SMTP/IMAP/POP3、反垃圾邮件（Rspamd）、Webmail（SOGo）、管理面板。"
    echo "自动 DKIM/SPF/DMARC 占用资源稍大（2GB+ 内存推荐）"
    echo "开源地址: https://github.com/mailcow/mailcow-dockerized"
    echo "=============================="
    echo "1) 安装 Mailcow"
    echo "2) 更新 Mailcow"
    echo "3) 备份 Mailcow"
    echo "4) 恢复备份，安装科技lion的nginx，只能安装nginx不能添加网站⚠️ "

    echo "5) 自动复制证书"

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

        5) sync_certificates ;;


        9) uninstall_mailcow ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
}


# ------------------------------
# 安装函数
# ------------------------------
install_mailcow() {
    # —— 交互式输入 —— #
    while true; do
        read -rp "请输入 Mailcow 域名（如 mail.example.com，必填）: " MAILCOW_HOSTNAME
        if [ -n "$MAILCOW_HOSTNAME" ]; then break; fi
        echo "❌ 域名不能为空，请重新输入"
    done


    read -rp "请输入时区（默认 Asia/Shanghai）: " TIMEZONE
    TIMEZONE=${TIMEZONE:-Asia/Shanghai}

    read -rp "是否禁用 ClamAV（小内存 VPS 推荐 Y）[Y/n]: " DISABLE_CLAMAV
    DISABLE_CLAMAV=${DISABLE_CLAMAV:-Y}

    echo
    echo "➡ 域名: $MAILCOW_HOSTNAME"
    echo "➡ 时区: $TIMEZONE"
    echo "➡ 禁用 ClamAV: $DISABLE_CLAMAV"
    echo

    # 安装依赖
    apt update
    apt install -y ca-certificates curl gnupg lsb-release git jq

    # 安装 Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo "🐳 安装 Docker..."
        curl -fsSL https://get.docker.com | sh
    fi

    # 安装 docker-compose
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
    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"
    if [ ! -d "${MAILCOW_DIR}" ]; then
        git clone https://github.com/mailcow/mailcow-dockerized.git
    else
        echo "📁 Mailcow 目录已存在"
    fi
    cd "${MAILCOW_DIR}"

    # 先生成 mailcow.conf
    export MAILCOW_HOSTNAME TIMEZONE
    yes | bash generate_config.sh

    # 再修改 mailcow.conf
    sed -i "s|^MAILCOW_HOSTNAME=.*|MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}|" mailcow.conf
    sed -i "s|^SKIP_LETS_ENCRYPT=.*|SKIP_LETS_ENCRYPT=y|" mailcow.conf
    sed -i "s|^HTTP_BIND=.*|HTTP_BIND=0.0.0.0|" mailcow.conf
    sed -i "s|^HTTP_PORT=.*|HTTP_PORT=8880|" mailcow.conf
    sed -i "s|^HTTPS_BIND=.*|HTTPS_BIND=0.0.0.0|" mailcow.conf
    sed -i "s|^HTTPS_PORT=.*|HTTPS_PORT=2053|" mailcow.conf
    sed -i "s|^HTTP_REDIRECT=.*|HTTP_REDIRECT=n|" mailcow.conf
    if [[ "$DISABLE_CLAMAV" =~ ^[Yy]$ ]]; then
        sed -i 's/^SKIP_CLAMD=.*/SKIP_CLAMD=y/' mailcow.conf
    fi

    # 拉取镜像并启动 Mailcow
    docker compose pull
    docker compose up -d


# ------------------------------
# 生成 nginx -> Mailcow 证书同步脚本
# ------------------------------

ZSFZ2_SCRIPT="/home/docker/mailcow-dockerized/zhengshufuzhi.sh"

cat > "$ZSFZ2_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -e

########################
# 基础配置
########################
MAILCOW_DIR="/home/docker/mailcow-dockerized"
ENV_FILE="$MAILCOW_DIR/.mailcow_env"

# 读取域名配置
if [ ! -f "$ENV_FILE" ]; then
    echo "❌ 未找到域名配置文件: $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

if [ -z "$MAILCOW_HOSTNAME" ]; then
    echo "❌ MAILCOW_HOSTNAME 为空"
    exit 1
fi

########################
# 证书路径
########################
CRT_FILE="/home/web/certs/${MAILCOW_HOSTNAME}_cert.pem"
KEY_FILE="/home/web/certs/${MAILCOW_HOSTNAME}_key.pem"

if [ ! -f "$CRT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "❌ 证书或私钥不存在:"
    echo "   $CRT_FILE"
    echo "   $KEY_FILE"
    exit 1
fi

echo "✅ 找到证书文件，开始检查是否需要更新..."

########################
# MD5 对比
########################
TARGET_CERT="$MAILCOW_DIR/data/assets/ssl/cert.pem"

if [ -f "$TARGET_CERT" ]; then
    MD5_CURRENT=$(md5sum "$TARGET_CERT" | awk '{print $1}')
else
    MD5_CURRENT=""
fi

MD5_NEW=$(md5sum "$CRT_FILE" | awk '{print $1}')

########################
# 同步证书
########################
if [ "$MD5_CURRENT" != "$MD5_NEW" ]; then
    echo "🔄 检测到证书变化，开始同步..."

    cp "$CRT_FILE" "$MAILCOW_DIR/data/assets/ssl/cert.pem"
    cp "$KEY_FILE" "$MAILCOW_DIR/data/assets/ssl/key.pem"

    mkdir -p "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME"
    cp "$CRT_FILE" "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/cert.pem"
    cp "$KEY_FILE" "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/key.pem"

    echo "🔁 重启 Mailcow 服务容器..."
    docker restart \
        $(docker ps -qaf name=postfix-mailcow) \
        $(docker ps -qaf name=dovecot-mailcow) \
        $(docker ps -qaf name=nginx-mailcow)

    echo "✅ Mailcow 证书更新完成"
else
    echo "ℹ️ 证书未发生变化，无需更新"
fi
EOF



chmod +x "$ZSFZ2_SCRIPT"

# ------------------------------
# 配置 cron（每天2点执行，无日志，去重）
# ------------------------------
CRON_LINE="0 2 * * * $ZSFZ2_SCRIPT"

# 使用临时文件安全写入 cron
TMP_CRON=$(mktemp)

# 导出现有 crontab（如果为空，文件就是空）
crontab -l 2>/dev/null > "$TMP_CRON" || true

# 去重，如果不存在才追加
grep -Fq "$ZSFZ2_SCRIPT" "$TMP_CRON" || echo "$CRON_LINE" >> "$TMP_CRON"

# 写回 crontab
crontab "$TMP_CRON"

# 删除临时文件
rm -f "$TMP_CRON"


    # 清屏输出
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
    echo "✅ 安装完成！Mailcow + Caddy 已就绪"
    echo "https://${MAILCOW_HOSTNAME}/admin"
    echo "账号: admin"
    echo "密码: moohoo"
    echo "请尽快修改密码"
    echo "------------------------------------------------"


    read -rp "按回车继续..." _
}

# ------------------------------
# 更新函数
# ------------------------------
update_mailcow() {
    cd "${MAILCOW_DIR}"
    git pull
    docker compose pull
    docker compose up -d
    echo "✅ Mailcow 已更新"
    read -rp "按回车继续..." _
}




# ------------------------------
# 备份 Mailcow（官方 nginx，全量）
# ------------------------------
backup_mailcow() {
    echo "📦 开始完整备份 Mailcow（邮件 + 用户 + 配置）"

    TIMESTAMP=$(date +%F_%H%M%S)
    BACKUP_FILE="/home/mailwebnginxdabao-${TIMESTAMP}.tar.gz"

    read -rp "确认备份到 ${BACKUP_FILE} ? (Y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    TMP_DIR=$(mktemp -d)
    mkdir -p "$TMP_DIR/volumes"

    echo "🛑 停止 Mailcow 容器（确保数据一致）"
    cd /home/docker/mailcow-dockerized && docker compose stop

    # 备份主程序
    echo "📂 备份 Mailcow 程序文件"
    mkdir -p "$TMP_DIR/home"
    cp -a /home/docker/mailcow-dockerized "$TMP_DIR/home/"

    # 备份 Docker 卷（真实数据）
    for VOL in "${VOLUMES[@]}"; do
        SRC="/var/lib/docker/volumes/${VOL}/_data"
        if [ -d "$SRC" ]; then
            echo "🔹 备份卷 $VOL"
            tar czf "$TMP_DIR/volumes/${VOL}.tar.gz" -C "$SRC" .
        else
            echo "⚠️ 卷 $VOL 不存在，跳过"
        fi
    done

    echo "📦 打包最终备份"
    tar czf "$BACKUP_FILE" -C "$TMP_DIR" .

    rm -rf "$TMP_DIR"

    echo "🚀 启动 Mailcow"
    docker compose start

    echo "✅ 备份完成：$BACKUP_FILE"
    read -rp "按回车继续..." _
}


# ------------------------------
# 恢复 Mailcow（官方 nginx，全量）
# ------------------------------
restore_mailcow() {
    # 查找最新备份
    FILE=$(ls /home/mailwebnginxdabao-*.tar.gz 2>/dev/null | tail -n1)
    [ -z "$FILE" ] && echo "❌ 未找到备份文件" && return

    read -rp "⚠️ 确认恢复 ${FILE}？会覆盖所有邮件和用户 (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && return

    TMP_DIR=$(mktemp -d)

    echo "📦 解压备份"
    tar xzf "$FILE" -C "$TMP_DIR"

    echo "🛑 停止 Mailcow"
    cd /home/docker/mailcow-dockerized 2>/dev/null && docker compose down || true

    # 恢复程序文件
    echo "📂 恢复 Mailcow 程序"
    rm -rf /home/docker/mailcow-dockerized
    cp -a "$TMP_DIR/home/mailcow-dockerized" /home/docker/

    # 自动检测 Docker 卷
    VOLUMES=($(docker volume ls --format "{{.Name}}" | grep mailcow || true))

    # 恢复卷数据
    for VOL in "${VOLUMES[@]}"; do
        BACKUP_VOL="$TMP_DIR/volumes/${VOL}.tar.gz"
        TARGET="/var/lib/docker/volumes/${VOL}/_data"

        if [ -f "$BACKUP_VOL" ]; then
            echo "🔹 恢复卷 $VOL"
            mkdir -p "$TARGET"
            rm -rf "$TARGET"/*
            tar xzf "$BACKUP_VOL" -C "$TARGET"
        else
            echo "⚠️ 未找到 $VOL 备份，跳过"
        fi
    done

    rm -rf "$TMP_DIR"

    echo "🚀 启动 Mailcow"
    cd /home/docker/mailcow-dockerized && docker compose up -d

    # ====== 恢复后补环境 ======
    SYNC_SCRIPT="/home/docker/mailcow-dockerized/zhengshufuzhi.sh"
    CRON_LINE="0 2 * * * $SYNC_SCRIPT"

    if [ -f "$SYNC_SCRIPT" ]; then
        chmod +x "$SYNC_SCRIPT"
        echo "✅ 证书同步脚本已就绪"
    else
        echo "⚠️ 未找到证书同步脚本"
    fi

    if ! crontab -l 2>/dev/null | grep -Fq "$SYNC_SCRIPT"; then
        (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
        echo "⏱ 已添加证书同步 cron（02:00）"
    else
        echo "ℹ️ cron 已存在"
    fi

    echo "✅ 恢复完成（邮件 + 用户 + 配置 已恢复）"
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








# ------------------------------
# 主循环
# ------------------------------
while true; do
    show_menu
    read_choice
done
