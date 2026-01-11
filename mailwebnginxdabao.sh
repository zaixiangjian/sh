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


# 科技lion 同步脚本
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshunginx.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 容器 Nginx 证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ Nginx 证书同步定时任务不存在"
fi


CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    echo "=============================="
# Caddy 同步脚本
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshucaddy.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 容器 Caddy 证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ Caddy 证书同步定时任务不存在"
fi





CURRENT_CRON=$(crontab -l 2>/dev/null || true)
    echo "=============================="
# 其他证书 同步脚本
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshuqita.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 容器 其他 证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ 其他 证书同步定时任务不存在"
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

    echo "5) 自动复制证书Caddy"

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
    sed -i "s|^ENABLE_IPV6=.*|ENABLE_IPV6=false|" mailcow.conf
    if [[ "$DISABLE_CLAMAV" =~ ^[Yy]$ ]]; then
        sed -i 's/^SKIP_CLAMD=.*/SKIP_CLAMD=y/' mailcow.conf
    fi

    # 拉取镜像并启动 Mailcow
    docker compose pull
    docker compose up -d














# ------------------------------
# 添加 cron 定时任务函数
# ------------------------------
add_cron_job() {
    local SCRIPT_PATH="$1"
    local CRON_TIME="$2"

    # 检查脚本是否存在
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "❌ 脚本不存在: $SCRIPT_PATH"
        return 1
    fi

    # 临时文件
    local TMP_CRON
    TMP_CRON=$(mktemp)

    # 获取现有 cron 任务
    crontab -l 2>/dev/null > "$TMP_CRON" || true

    # 防止重复添加
    if grep -Fxq "$CRON_TIME $SCRIPT_PATH" "$TMP_CRON"; then
        echo "ℹ️ Cron 已存在: $SCRIPT_PATH"
    else
        echo "$CRON_TIME $SCRIPT_PATH" >> "$TMP_CRON"
        crontab "$TMP_CRON"
        echo "✅ Cron 添加成功: $SCRIPT_PATH"
    fi

    rm -f "$TMP_CRON"
}

# ------------------------------
# 生成 nginx -> Mailcow 证书同步脚本
# ------------------------------
ZSFZ2_NGINX="${MAILCOW_DIR}/zhengshunginx.sh"
cat > "$ZSFZ2_NGINX" <<EOF
#!/usr/bin/env bash
set -e

########################
# 固定配置（安装时写入）
########################
MAILCOW_DIR="/home/docker/mailcow-dockerized"
MAILCOW_HOSTNAME="${MAILCOW_HOSTNAME}"

########################
# 证书路径
########################
CRT_FILE="/home/web/certs/\${MAILCOW_HOSTNAME}_cert.pem"
KEY_FILE="/home/web/certs/\${MAILCOW_HOSTNAME}_key.pem"

if [ ! -f "\$CRT_FILE" ] || [ ! -f "\$KEY_FILE" ]; then
    echo "❌ 证书不存在: \$CRT_FILE"
    exit 1
fi

########################
# MD5 对比
########################
TARGET_CERT="\$MAILCOW_DIR/data/assets/ssl/cert.pem"
MD5_CURRENT=\$( [ -f "\$TARGET_CERT" ] && md5sum "\$TARGET_CERT" | awk '{print \$1}' )
MD5_NEW=\$(md5sum "\$CRT_FILE" | awk '{print \$1}')

########################
# 同步
########################
if [ "\$MD5_CURRENT" != "\$MD5_NEW" ]; then
    echo "🔄 同步 Mailcow 证书..."

    cp "\$CRT_FILE" "\$MAILCOW_DIR/data/assets/ssl/cert.pem"
    cp "\$KEY_FILE" "\$MAILCOW_DIR/data/assets/ssl/key.pem"

    mkdir -p "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME"
    cp "\$CRT_FILE" "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME/cert.pem"
    cp "\$KEY_FILE" "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME/key.pem"


echo "🔄 重启 Mailcow 容器..."
docker restart mailcowdockerized-postfix-mailcow-1 \
               mailcowdockerized-dovecot-mailcow-1 \
               mailcowdockerized-nginx-mailcow-1

    echo "✅ Mailcow 证书更新完成"
else
    echo "ℹ️ 证书未发生变化，无需更新"
fi

EOF
chmod +x "$ZSFZ2_NGINX"

# ------------------------------
# 生成 Caddy -> Mailcow 证书同步脚本
# ------------------------------
ZSFZ2_CADDY="${MAILCOW_DIR}/zhengshucaddy.sh"
cat > "$ZSFZ2_CADDY" <<EOF
#!/usr/bin/env bash
set -e

MAILCOW_DIR="${MAILCOW_DIR}"
MAILCOW_HOSTNAME="${MAILCOW_HOSTNAME}"
CADDY_CERTS_DIR="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/\$MAILCOW_HOSTNAME"

CRT_FILE="\$CADDY_CERTS_DIR/\$MAILCOW_HOSTNAME.crt"
KEY_FILE="\$CADDY_CERTS_DIR/\$MAILCOW_HOSTNAME.key"

[ -f "\$CRT_FILE" ] || exit 0
[ -f "\$KEY_FILE" ] || exit 0

MD5_CURRENT=\$(md5sum "\$MAILCOW_DIR/data/assets/ssl/cert.pem" 2>/dev/null | awk '{print \$1}')
MD5_NEW=\$(md5sum "\$CRT_FILE" | awk '{print \$1}')

if [ "\$MD5_CURRENT" != "\$MD5_NEW" ]; then
    cp "\$CRT_FILE" "\$MAILCOW_DIR/data/assets/ssl/cert.pem"
    cp "\$KEY_FILE" "\$MAILCOW_DIR/data/assets/ssl/key.pem"

    mkdir -p "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME"
    cp "\$CRT_FILE" "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME/cert.pem"
    cp "\$KEY_FILE" "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME/key.pem"

echo "🔄 重启 Mailcow 容器..."
docker restart mailcowdockerized-postfix-mailcow-1 \
               mailcowdockerized-dovecot-mailcow-1 \
               mailcowdockerized-nginx-mailcow-1


    echo "✅ 证书同步完成"
else
    echo "✅ 证书未变化，无需同步"


fi
EOF
chmod +x "$ZSFZ2_CADDY"

# ------------------------------
# 添加定时任务（自动使用 MAILCOW_HOSTNAME 脚本）
# ------------------------------
add_cron_job "$ZSFZ2_NGINX" "0 2 * * *"   # nginx 每天 2 点同步
add_cron_job "$ZSFZ2_CADDY" "0 3 * * *"   # caddy 每天 3 点同步























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
    echo "📦 开始完整备份 Mailcow（程序 + 配置 + 邮箱数据 + 数据库）"

    TIMESTAMP=$(date +%F_%H%M%S)
    BACKUP_FILE="/home/mailwebnginxdabao-${TIMESTAMP}.tar.gz"

    read -rp "确认备份到 ${BACKUP_FILE} ? (Y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return

    TMP_DIR=$(mktemp -d)

    # ------------------------------
    # 停止 Mailcow 容器，保证数据一致
    # ------------------------------
    echo "🛑 停止 Mailcow 容器"
    cd /home/docker/mailcow-dockerized
    docker compose down

    # ------------------------------
    # 备份程序文件
    # ------------------------------
    echo "📂 备份 Mailcow 程序文件和配置"
    mkdir -p "$TMP_DIR/home"
    cp -a /home/docker/mailcow-dockerized "$TMP_DIR/home/"

    # ------------------------------
    # 备份 Docker 卷（邮件、数据库、配置）
    # ------------------------------
    echo "🔹 备份 Docker 卷数据"
    VOLUMES=($(docker volume ls --format "{{.Name}}" | grep mailcow))
    mkdir -p "$TMP_DIR/volumes"

    for VOL in "${VOLUMES[@]}"; do
        SRC="/var/lib/docker/volumes/${VOL}/_data"
        if [ -d "$SRC" ]; then
            echo "  ➤ 备份卷 $VOL"
            tar czf "$TMP_DIR/volumes/${VOL}.tar.gz" -C "$SRC" .
        else
            echo "  ⚠️ 卷 $VOL 不存在，跳过"
        fi
    done

    # ------------------------------
    # 打包最终备份
    # ------------------------------
    echo "📦 打包备份文件 $BACKUP_FILE"
    tar czf "$BACKUP_FILE" -C "$TMP_DIR" .

    # 清理临时目录
    rm -rf "$TMP_DIR"

    # 启动 Mailcow
    echo "🚀 启动 Mailcow"
    cd /home/docker/mailcow-dockerized
    docker compose up -d

    echo "✅ 备份完成：$BACKUP_FILE"
    read -rp "按回车继续..." _
}




# ------------------------------
# 恢复 Mailcow（保留备份原始路径，自动检测）
# ------------------------------
restore_mailcow() {
    # 查找最新备份文件
    FILE=$(ls /home/mailwebnginxdabao-*.tar.gz 2>/dev/null | tail -n1)
    [ -z "$FILE" ] && echo "❌ 未找到备份文件" && return

    echo "📦 找到备份文件: $FILE"

    read -rp "⚠️ 确认恢复 ${FILE}？会覆盖所有邮件和用户 (yes/no): " confirm
    [[ "$confirm" != "yes" ]] && echo "取消恢复" && return



    # ------------------------------
    # 安装 Docker（如果未安装）
    # ------------------------------
    if ! command -v docker >/dev/null 2>&1; then
        echo "⚠️ Docker 未安装，正在安装..."
        apt update
        apt install -y ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
    fi




    TMP_DIR=$(mktemp -d)
    echo "📦 解压备份到临时目录 $TMP_DIR"
    tar xzf "$FILE" -C "$TMP_DIR"

    # ------------------------------
    # 停止 Mailcow
    # ------------------------------
    echo "🛑 停止 Mailcow"
    if [ -d "/home/docker/mailcow-dockerized" ]; then
        cd /home/docker/mailcow-dockerized && docker compose down || true
    fi

    # ------------------------------
    # 恢复程序文件
    # ------------------------------
    if [ -d "$TMP_DIR/home/mailcow-dockerized" ]; then
        echo "📂 恢复 Mailcow 程序文件"
        rm -rf /home/docker/mailcow-dockerized
        mkdir -p /home/docker
        cp -a "$TMP_DIR/home/mailcow-dockerized" /home/docker/
    else
        echo "❌ 未找到程序文件"
        rm -rf "$TMP_DIR"
        return
    fi

    # ------------------------------
    # 恢复卷数据
    # ------------------------------
    echo "🔹 恢复 Docker 卷数据"
    for VOL_BACKUP in "$TMP_DIR"/volumes/*.tar.gz; do
        VOL_NAME=$(basename "$VOL_BACKUP" .tar.gz)
        echo "  ➤ 恢复卷 $VOL_NAME"

        # 如果卷不存在，先创建
        if ! docker volume inspect "$VOL_NAME" >/dev/null 2>&1; then
            docker volume create "$VOL_NAME"
        fi

        TARGET="/var/lib/docker/volumes/${VOL_NAME}/_data"
        mkdir -p "$TARGET"
        rm -rf "$TARGET"/*
        tar xzf "$VOL_BACKUP" -C "$TARGET"
    done

    # 清理临时目录
    rm -rf "$TMP_DIR"

    # ------------------------------
    # 启动 Mailcow
    # ------------------------------
    echo "🚀 启动 Mailcow"
    cd /home/docker/mailcow-dockerized
    docker compose up -d




    # ------------------------------
    # 启动 Mailcow
    # ------------------------------
    echo "🚀 启动 Mailcow"
    cd /home/docker/mailcow-dockerized
    docker compose up -d

    # ------------------------------
    # 函数：添加定时任务（防重复）
    # ------------------------------
    add_cron_job() {
        local SCRIPT_PATH="$1"
        local CRON_TIME="$2"
        CRON_LINE="$CRON_TIME $SCRIPT_PATH"
        TMP_CRON=$(mktemp)
        crontab -l 2>/dev/null > "$TMP_CRON" || true
        grep -Fq "$SCRIPT_PATH" "$TMP_CRON" || echo "$CRON_LINE" >> "$TMP_CRON"
        crontab "$TMP_CRON"
        rm -f "$TMP_CRON"
    }

    # nginx 证书同步脚本，每日 2 点
    add_cron_job "/home/docker/mailcow-dockerized/zhengshunginx.sh" "0 2 * * *"

    # caddy 证书同步脚本，每日 3 点
    add_cron_job "/home/docker/mailcow-dockerized/zhengshucaddy.sh" "0 3 * * *"









    echo "✅ 恢复完成！Mailcow 已启动"
    read -rp "按回车继续..." _
}





# ------------------------------
# 证书同步函数（菜单选项 5）
# ------------------------------
sync_certificates() {
    read -rp "请输入要同步证书的 Mailcow 域名（如 mail.example.com）: " ZSFZ_DOMAIN
    if [ -z "$ZSFZ_DOMAIN" ]; then
        echo "❌ 域名不能为空"
        return
    fi

    ZSFZ_SYNC="${MAILCOW_DIR}/zhengshuqita.sh"

    # 生成同步脚本（手动执行，无日志）
    cat > "$ZSFZ_SYNC" <<EOF
#!/usr/bin/env bash
# 自动复制 Mailcow SSL 证书（手动执行）
set -e

MAILCOW_DIR="${MAILCOW_DIR}"
MAILCOW_HOSTNAME="${ZSFZ_DOMAIN}"
CADDY_CERTS_BASE="/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory"

CERT_DIR=\$(find "\$CADDY_CERTS_BASE" -type d -name "\$MAILCOW_HOSTNAME" | head -n1)
if [ ! -d "\$CERT_DIR" ]; then exit 1; fi

CRT_FILE="\$CERT_DIR/\$MAILCOW_HOSTNAME.crt"
KEY_FILE="\$CERT_DIR/\$MAILCOW_HOSTNAME.key"

if [ ! -f "\$CRT_FILE" ] || [ ! -f "\$KEY_FILE" ]; then exit 1; fi

mkdir -p "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME"

MD5_CURRENT_CERT=\$(md5sum "\$MAILCOW_DIR/data/assets/ssl/cert.pem" 2>/dev/null | awk '{print \$1}' || echo "")
MD5_NEW_CERT=\$(md5sum "\$CRT_FILE" | awk '{print \$1}')

if [ "\$MD5_CURRENT_CERT" != "\$MD5_NEW_CERT" ]; then
    cp "\$CRT_FILE" "\$MAILCOW_DIR/data/assets/ssl/cert.pem"
    cp "\$KEY_FILE" "\$MAILCOW_DIR/data/assets/ssl/key.pem"
    cp "\$CRT_FILE" "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME/cert.pem"
    cp "\$KEY_FILE" "\$MAILCOW_DIR/data/assets/ssl/\$MAILCOW_HOSTNAME/key.pem"

    docker restart \$(docker ps -qaf name=postfix-mailcow) \\
                   \$(docker ps -qaf name=dovecot-mailcow) \\
                   \$(docker ps -qaf name=nginx-mailcow)
fi
EOF

    chmod +x "$ZSFZ_SYNC"

    # 安装定时任务（每天凌晨 2 点执行，无日志）
    CRON_EXISTS=$(crontab -l 2>/dev/null | grep -F "$ZSFZ_SYNC" || true)
    if ! crontab -l 2>/dev/null | grep -Fq "$ZSFZ_SYNC"; then
        (crontab -l 2>/dev/null; echo "0 4 * * * $ZSFZ_SYNC") | crontab -


        echo "✅ 定时任务已安装，每天凌晨 2 点自动执行（无日志）"
    else
        echo "✅ 定时任务已存在"
    fi

    echo "✅ 证书同步脚本已生成，手动执行: $ZSFZ_SYNC"
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
