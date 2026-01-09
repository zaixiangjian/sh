#!/usr/bin/env bash
set -e

# ------------------------------
# 用户配置区
# ------------------------------
INSTALL_DIR="/home/docker"
MAILCOW_DIR="${INSTALL_DIR}/mailcow-dockerized"
BACKUP_DIR="/home/caddy"
CADDYFILE_DIR="/etc/caddy"
CADDY_LOG_DIR="/var/log/caddy"
CADDY_SYNC_SCRIPT="/usr/local/bin/mailcow_caddy_sync.sh"

# ------------------------------
# 检查 root 用户
# ------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 用户运行"
    exit 1
fi

# ------------------------------
# 菜单函数
# ------------------------------
show_menu() {
    clear






# ------------------------------
# 查询并显示证书同步定时任务（不关心日志）
# ------------------------------
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
echo "=============================="
# Caddy 同步脚本
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshufuzhi.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ Caddy 证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ Caddy 证书同步定时任务不存在"
fi

# ZSFZ 同步脚本
ZSFZ_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshufuzhi_sync.sh" | head -n 1)
if [ -n "$ZSFZ_LINE" ]; then
    echo "✅ ZSFZ 证书同步定时任务已存在:"
    echo "   $ZSFZ_LINE"
else
    echo "⚠️ ZSFZ 证书同步定时任务不存在"
fi
echo "=============================="









    echo "=============================="
    echo " Mailcow + Caddy 管理脚本"
    echo "=============================="
    echo "安装完成进入目录"
    echo "/home/docker/mailcow-dockerized"
    echo "修改文件mailcow.conf"
    echo "=============================="
    echo "HTTP_REDIRECT=y        改为n使用 2 更新"
    echo "=============================="
    echo "或使用nano直接编辑"
    echo "nano /home/docker/mailcow-dockerized/mailcow.conf"

    echo "=============================="
    echo "查看证书是否生效"
    echo "cd /home/docker/mailcow-dockerized"
    echo "openssl x509 -in data/assets/ssl/cert.pem -noout -fingerprint -sha256"
    echo "=============================="
    echo "openssl x509 \
-in /home/docker/mailcow-dockerized/data/assets/ssl/cert.pem \
-noout -subject -issuer -dates"
    echo "Postfix 容器查询"
    echo "docker exec mailcowdockerized-postfix-mailcow-1 \
openssl x509 -in /etc/ssl/mail/cert.pem -noout -fingerprint -sha256"
    echo "=============================="
    echo "Dovecot 容器查询"
    echo "docker exec mailcowdockerized-dovecot-mailcow-1 \
openssl x509 -in /etc/ssl/mail/cert.pem -noout -fingerprint -sha256"
    echo "=============================="



    echo "1) 安装 Mailcow + Caddy"
    echo "2) 更新 Mailcow"
    echo "3) 备份 Mailcow"
    echo "4) 恢复 Mailcow"

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

    while true; do
        read -rp "请输入用于 TLS 的邮箱（如 admin@example.com，必填）: " EMAIL_FOR_TLS
        if [ -n "$EMAIL_FOR_TLS" ]; then break; fi
        echo "❌ 邮箱不能为空，请重新输入"
    done

    read -rp "请输入时区（默认 Asia/Shanghai）: " TIMEZONE
    TIMEZONE=${TIMEZONE:-Asia/Shanghai}

    read -rp "是否禁用 ClamAV（小内存 VPS 推荐 Y）[Y/n]: " DISABLE_CLAMAV
    DISABLE_CLAMAV=${DISABLE_CLAMAV:-Y}

    echo
    echo "➡ 域名: $MAILCOW_HOSTNAME"
    echo "➡ TLS 邮箱: $EMAIL_FOR_TLS"
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
    sed -i "s|^HTTP_BIND=.*|HTTP_BIND=127.0.0.1|" mailcow.conf
    sed -i "s|^HTTP_PORT=.*|HTTP_PORT=8880|" mailcow.conf
    sed -i "s|^HTTPS_BIND=.*|HTTPS_BIND=127.0.0.1|" mailcow.conf
    sed -i "s|^HTTPS_PORT=.*|HTTPS_PORT=2053|" mailcow.conf
    sed -i "s|^HTTP_REDIRECT=.*|HTTP_REDIRECT=n|" mailcow.conf
    if [[ "$DISABLE_CLAMAV" =~ ^[Yy]$ ]]; then
        sed -i 's/^SKIP_CLAMD=.*/SKIP_CLAMD=y/' mailcow.conf
    fi

    # 拉取镜像并启动 Mailcow
    docker compose pull
    docker compose up -d

    # ------------------------------
    # 安装 Caddy 并配置
    # ------------------------------
    echo "⚙️ 配置 Caddy..."
    if ! command -v caddy >/dev/null 2>&1; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update
        apt install -y caddy
    fi

    mkdir -p "${CADDYFILE_DIR}" "${CADDY_LOG_DIR}"
    chown -R caddy:caddy "${CADDY_LOG_DIR}"

    # 生成 Caddyfile
    cat > /etc/caddy/Caddyfile <<EOF
${MAILCOW_HOSTNAME} autodiscover.${MAILCOW_HOSTNAME} autoconfig.${MAILCOW_HOSTNAME} {
    reverse_proxy 127.0.0.1:8880
}


EOF

    systemctl enable caddy
    systemctl restart caddy

# ------------------------------
# 生成 Caddy -> Mailcow 证书同步脚本
# ------------------------------
ZSFZ2_SCRIPT="/home/docker/mailcow-dockerized/zhengshufuzhu.sh"

cat > "$ZSFZ2_SCRIPT" <<EOF
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

    docker restart \$(docker ps -qaf name=postfix-mailcow) \
                   \$(docker ps -qaf name=dovecot-mailcow) \
                   \$(docker ps -qaf name=nginx-mailcow)
fi
EOF

chmod +x "$ZSFZ2_SCRIPT"

# ------------------------------
# 配置 cron（每天凌晨 2 点执行，无日志）
# ------------------------------
CRON_LINE="0 2 * * * $ZSFZ2_SCRIPT"

crontab -l 2>/dev/null | grep -F "$ZSFZ2_SCRIPT" >/dev/null \
  || (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -

echo "✅ 安装完成！Mailcow + Caddy 已就绪"
echo "管理后台: https://${MAILCOW_HOSTNAME}/admin"
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
    BACKUP_FILE="/home/caddy-$(date +%F_%H%M%S).tar.gz"

    # 确认
    read -rp "确认备份到 ${BACKUP_FILE} ? (Y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消备份"; return; }

    # 打包备份（保持绝对路径）
    tar czf "$BACKUP_FILE" \
        -C "/" etc/caddy \
        -C "/" var/lib/caddy \
        -C "/" home/docker/mailcow-dockerized

    echo "✅ 备份完成: $BACKUP_FILE"
    read -rp "按回车继续..." _
}

# ------------------------------
# 恢复函数（含 Caddy 配置，不恢复日志）
# ------------------------------
restore_mailcow() {
    # 自动选择 /home 下最新备份文件
    FILE=$(ls -t /home/caddy-*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$FILE" ]; then
        echo "❌ 找不到备份文件 (/home 下)"
        read -rp "按回车继续..." _
        return
    fi

    read -rp "⚠️ 确认恢复 ${FILE}？将覆盖当前 Mailcow + Caddy 配置 (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消恢复"; return; }


    echo "📦 检查 Caddy 是否安装..."
    if ! command -v caddy >/dev/null 2>&1; then
        echo "⚠️ Caddy 未安装，正在自动安装..."
        export DEBIAN_FRONTEND=noninteractive
        apt update
        apt install -y -o Dpkg::Options::="--force-confold" caddy
    fi

    # 确保 caddy 用户存在
    if ! id -u caddy >/dev/null 2>&1; then
        echo "⚠️ 创建 caddy 用户和组..."
        groupadd -f caddy
        useradd -r -g caddy -d /var/lib/caddy -s /usr/sbin/nologin caddy
    fi

    echo "📦 开始恢复 Mailcow + Caddy 配置..."

    # 停止服务
    systemctl stop caddy 2>/dev/null || true
    [ -d "${MAILCOW_DIR}" ] && docker compose -f "${MAILCOW_DIR}/docker-compose.yml" down 2>/dev/null || true

    # 确保目录存在
    mkdir -p /etc/caddy /var/lib/caddy /home/docker/mailcow-dockerized

    # 恢复配置（保持绝对路径）
    tar xzf "$FILE" -C /

    # 修复权限
    chown -R caddy:caddy /etc/caddy /var/lib/caddy

    # 启动 Mailcow
    cd "${MAILCOW_DIR}" || { echo "❌ ${MAILCOW_DIR} 不存在"; return; }
    docker compose up -d

    # 启动 Caddy
    systemctl enable caddy
    systemctl restart caddy

    echo "✅ 恢复完成！Mailcow + Caddy 已启动"
    read -rp "按回车继续..." _
}


# ------------------------------
# 卸载函数
# ------------------------------
uninstall_mailcow() {
    read -rp "⚠️ 确认卸载 Mailcow？(y/yes): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消卸载"
        return
    fi
    cd "${MAILCOW_DIR}" || return
    docker compose down
    rm -rf "${MAILCOW_DIR}"
    echo "✅ Mailcow 已卸载"
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
