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

cat > "$ZSFZ2_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e

MAILCOW_DIR="/home/docker/mailcow-dockerized"
MAILCOW_HOSTNAME="mail.zaiguge.dpdns.org"

# 真实证书路径
CRT_FILE="/home/web/certs/${MAILCOW_HOSTNAME}_cert.pem"
KEY_FILE="/home/web/certs/${MAILCOW_HOSTNAME}_key.pem"

if [ ! -f "$CRT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "❌ 证书或私钥不存在: $CRT_FILE 或 $KEY_FILE"
    exit 1
fi

echo "✅ 证书文件存在，开始复制..."

MD5_CURRENT=$(md5sum "$MAILCOW_DIR/data/assets/ssl/cert.pem" | awk '{print $1}')
MD5_NEW=$(md5sum "$CRT_FILE" | awk '{print $1}')

if [ "$MD5_CURRENT" != "$MD5_NEW" ]; then
    cp "$CRT_FILE" "$MAILCOW_DIR/data/assets/ssl/cert.pem"
    cp "$KEY_FILE" "$MAILCOW_DIR/data/assets/ssl/key.pem"

    mkdir -p "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME"
    cp "$CRT_FILE" "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/cert.pem"
    cp "$KEY_FILE" "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/key.pem"

    echo "🔄 重启 Mailcow 相关容器..."
    docker restart $(docker ps -qaf name=postfix-mailcow) \
                   $(docker ps -qaf name=dovecot-mailcow) \
                   $(docker ps -qaf name=nginx-mailcow)

    echo "✅ 证书更新完成"
else
    echo "ℹ️ 证书未变化，无需更新"
fi

EOF

chmod +x "$ZSFZ2_SCRIPT"

# ------------------------------
# 配置 cron（每两小时执行，无日志，去重）
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
# 备份函数（含 Caddy 配置，不含日志）
# ------------------------------
backup_mailcow() {
    echo "📦 开始备份 Mailcow + Caddy（不含日志）..."

    # 备份文件路径
    BACKUP_FILE="/home/mailrongqinginx-$(date +%F_%H%M%S).tar.gz"

    # 确认
    read -rp "确认备份到 ${BACKUP_FILE} ? (Y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消备份"; return; }

    # 打包备份（保持绝对路径）

    tar czf "$BACKUP_FILE" \
        -C / home/web \
        -C / home/docker/mailcow-dockerized \
        /var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_mysql-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_rspamd-vol-1/_data


    echo "✅ 备份完成: $BACKUP_FILE"
    read -rp "按回车继续..." _
}


# ------------------------------
# 恢复函数（含 Caddy 配置，不恢复日志）
# ------------------------------

restore_mailcow() {

    MAILCOW_DIR="/home/docker/mailcow-dockerized"

    # 自动选择 /home 下最新备份文件
    FILE=$(ls -t /home/mailrongqinginx-*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$FILE" ]; then
        echo "❌ 找不到备份文件 (/home/mailrongqinginnginx-*.tar.gz)"
        read -rp "按回车继续..." _
        return
    fi

    read -rp "⚠️ 确认恢复 ${FILE}？将覆盖当前 Mailcow + Caddy 配置 (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消恢复"; return; }

    echo "📁 准备目录..."
mkdir -p \
"${MAILCOW_DIR}"



    # 解除整个 mailcow-dockerized 目录下的不可变锁
    find "$MAILCOW_DIR" -type f -exec chattr -i {} \; 2>/dev/null


    echo "📦 解压恢复备份...解压覆盖"
    tar xzf "$FILE" -C /

    # ====== 关键校验（非常重要） ======
    if [ ! -f "${MAILCOW_DIR}/docker-compose.yml" ]; then
        echo "❌ docker-compose.yml 未成功恢复，终止"
        return
    fi

    if [ ! -f "${MAILCOW_DIR}/mailcow.conf" ]; then
        echo "❌ mailcow.conf 未成功恢复，终止"
        return
    fi

    echo "🔒 锁定 mailcow.conf（防止被更新覆盖）"
    chattr +i "${MAILCOW_DIR}/mailcow.conf" 2>/dev/null || true

    echo "🚀 启动 Mailcow..."
    cd "${MAILCOW_DIR}" || {
        echo "❌ 无法进入 ${MAILCOW_DIR}"
        return
    }
    docker compose up -d

    # ------------------------------
    # 安装每日 2 点执行的 cron（防重复）
    # ------------------------------
    CRON_LINE="0 2 * * * /home/docker/mailcow-dockerized/zhengshungfuzhi.sh"

    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null > "$TMP_CRON" || true
    grep -Fq "/home/docker/mailcow-dockerized/zhengshufuzhi.sh" "$TMP_CRON" \
        || echo "$CRON_LINE" >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm -f "$TMP_CRON"

    echo "✅ 恢复完成！Mailcow + 容器nginx自行配置科技lion 已启动"
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

    ZSFZ_SYNC="${MAILCOW_DIR}/zhengshufuzhi.sh"

    # 生成同步脚本（手动执行，无日志）
    cat > "$ZSFZ_SYNC" <<EOF
#!/usr/bin/env bash
set -e

MAILCOW_DIR="/home/docker/mailcow-dockerized"
MAILCOW_HOSTNAME="mail.zaiguge.dpdns.org"

# 真实证书路径
CRT_FILE="/home/web/certs/${MAILCOW_HOSTNAME}_cert.pem"
KEY_FILE="/home/web/certs/${MAILCOW_HOSTNAME}_key.pem"

if [ ! -f "$CRT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
    echo "❌ 证书或私钥不存在: $CRT_FILE 或 $KEY_FILE"
    exit 1
fi

echo "✅ 证书文件存在，开始复制..."

MD5_CURRENT=$(md5sum "$MAILCOW_DIR/data/assets/ssl/cert.pem" | awk '{print $1}')
MD5_NEW=$(md5sum "$CRT_FILE" | awk '{print $1}')

if [ "$MD5_CURRENT" != "$MD5_NEW" ]; then
    cp "$CRT_FILE" "$MAILCOW_DIR/data/assets/ssl/cert.pem"
    cp "$KEY_FILE" "$MAILCOW_DIR/data/assets/ssl/key.pem"

    mkdir -p "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME"
    cp "$CRT_FILE" "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/cert.pem"
    cp "$KEY_FILE" "$MAILCOW_DIR/data/assets/ssl/$MAILCOW_HOSTNAME/key.pem"

    echo "🔄 重启 Mailcow 相关容器..."
    docker restart $(docker ps -qaf name=postfix-mailcow) \
                   $(docker ps -qaf name=dovecot-mailcow) \
                   $(docker ps -qaf name=nginx-mailcow)

    echo "✅ 证书更新完成"
else
    echo "ℹ️ 证书未变化，无需更新"
fi

EOF

    chmod +x "$ZSFZ_SYNC"

    # 安装定时任务（每天凌晨 2 点执行，无日志）
    CRON_EXISTS=$(crontab -l 2>/dev/null | grep -F "$ZSFZ_SYNC" || true)
    if ! crontab -l 2>/dev/null | grep -Fq "$ZSFZ_SYNC"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * $ZSFZ_SYNC") | crontab -


        echo "✅ 定时任务已安装，每天凌晨 2 点自动执行（无日志）"
    else
        echo "✅ 定时任务已存在"
    fi

    echo "✅ 证书同步脚本已生成，手动执行: $ZSFZ_SYNC"
    read -rp "按回车继续..." _
}



# ------------------------------
# 主循环
# ------------------------------
while true; do
    show_menu
    read_choice
done

