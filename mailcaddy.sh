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
CADDY_SYNC_SCRIPT="/home/docker/mailcow-dockerized/zhengshufuzhi.sh"
CONFIG_FILE="/etc/caddy/Caddyfile"



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



CURRENT_CRON=$(crontab -l 2>/dev/null || true)
echo "=============================="
# Caddy 同步脚本
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshufuzhiqita.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ Caddy 证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ Caddy 证书同步定时任务不存在"
fi









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
    echo "4) 恢复 手动创建/home/docker 安装docker"

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
CONFIG_FILE="/etc/caddy/Caddyfile"

# 安装官方二进制 Caddy
if ! command -v caddy >/dev/null 2>&1; then
    apt update
    apt install -y curl ca-certificates sudo

    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64) CADDY_ARCH="amd64" ;;
        arm64) CADDY_ARCH="arm64" ;;
        *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac

    echo "📥 下载 Caddy 二进制 (${CADDY_ARCH})..."
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o /usr/bin/caddy
    chmod +x /usr/bin/caddy
fi

# 创建 caddy 用户和目录
id -u caddy &>/dev/null || useradd --system --gid nogroup --home /var/lib/caddy --shell /usr/sbin/nologin caddy
mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
chown -R caddy:nogroup /var/lib/caddy /var/log/caddy
[ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

# 创建 systemd 文件
cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy
After=network.target

[Service]
User=caddy
Group=nogroup
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

# 重载 systemd 配置
systemctl daemon-reload

# 启用并启动 Caddy
systemctl enable caddy
systemctl start caddy

# 检查状态
systemctl status caddy --no-pager
# 生成 Caddyfile
cat > "$CONFIG_FILE" <<EOF
${MAILCOW_HOSTNAME} autodiscover.${MAILCOW_HOSTNAME} autoconfig.${MAILCOW_HOSTNAME} {
    reverse_proxy 127.0.0.1:8880
}
EOF

# 重启 Caddy
systemctl restart caddy
echo "✅ Caddy 已安装并启动（官方二进制）"

# ------------------------------
# 生成 Caddy -> Mailcow 证书同步脚本
# ------------------------------
ZSFZ2_SCRIPT="/home/docker/mailcow-dockerized/zhengshufuzhi.sh"

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

echo "🔄 重启 Mailcow 容器..."
docker restart postfix-mailcow dovecot-mailcow nginx-mailcow


    echo "✅ 证书同步完成"
else
    echo "✅ 证书未变化，无需同步"


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
# 备份函数（Mailcow + Caddy，完整）
# ------------------------------
backup_mailcow() {
    echo "📦 开始备份 Mailcow + Caddy（完整，不含日志）..."

    BACKUP_FILE="/home/mailcaddy-$(date +%F_%H%M%S).tar.gz"

    read -rp "确认备份到 ${BACKUP_FILE} ? (Y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消备份"; return; }

    echo "🛑 备份前停止 Mailcow（确保数据一致）..."
    cd /home/docker/mailcow-dockerized 2>/dev/null && docker compose down || true

    # 所有卷路径
    VOLUMES=(
        /var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_mysql-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_rspamd-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_postfix-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_dovecot-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_redis-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_crypt-vol-1/_data
        /var/lib/docker/volumes/mailcowdockerized_clamd-vol-1/_data
    )

    # 打包命令：忽略不存在的卷和 socket 文件
    tar czpf "$BACKUP_FILE" --ignore-failed-read \
        /etc/caddy \
        /var/lib/caddy \
        /home/docker/mailcow-dockerized \
        "${VOLUMES[@]}"

    echo "🚀 重新启动 Mailcow..."
    cd /home/docker/mailcow-dockerized && docker compose up -d

    echo "✅ 备份完成: $BACKUP_FILE"
    read -rp "按回车继续..." _
}














# ------------------------------
# 恢复 Mailcow + Caddy（优化版）
# ------------------------------
restore_mailcow() {
    MAILCOW_DIR="/home/docker/mailcow-dockerized"
    CONFIG_FILE="/etc/caddy/Caddyfile"

    # 自动选择最新备份
    FILE=$(ls -t /home/mailcaddy-*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$FILE" ]; then
        echo "❌ 找不到备份文件 (/home/mailcaddy-*.tar.gz)"
        read -rp "按回车继续..." _
        return
    fi

    read -rp "⚠️ 确认恢复 ${FILE}？将覆盖当前 Mailcow + Caddy 配置 (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消恢复"; return; }

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

    # ------------------------------
    # 安装官方二进制 Caddy（如果未安装）
    # ------------------------------
    if ! command -v caddy >/dev/null 2>&1; then
        echo "⚠️ Caddy 未安装，正在安装..."
        apt update
        apt install -y curl ca-certificates sudo

        ARCH="$(dpkg --print-architecture)"
        case "$ARCH" in
            amd64) CADDY_ARCH="amd64" ;;
            arm64) CADDY_ARCH="arm64" ;;
            *) echo "❌ 不支持的架构: $ARCH"; return ;;
        esac

        curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o /usr/bin/caddy
        chmod +x /usr/bin/caddy
    fi

    # ------------------------------
    # 创建 Caddy 用户和组
    # ------------------------------
    if ! getent group caddy >/dev/null; then
        groupadd caddy
    fi
    if ! id -u caddy >/dev/null 2>&1; then
        useradd --system --gid caddy --home /var/lib/caddy --shell /usr/sbin/nologin caddy
    fi

    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

    # ------------------------------
    # 创建 systemd 服务
    # ------------------------------
    if [ ! -f /etc/systemd/system/caddy.service ]; then
        cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy
After=network.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now caddy
    fi

    # ------------------------------
    # 停止 Mailcow
    # ------------------------------
    echo "🛑 停止 Mailcow..."
    [ -f "${MAILCOW_DIR}/docker-compose.yml" ] && cd "${MAILCOW_DIR}" && docker compose down || true

    # ------------------------------
    # 创建必要目录
    # ------------------------------
    mkdir -p \
        /etc/caddy \
        /var/lib/caddy \
        "${MAILCOW_DIR}" \
        /var/lib/docker/volumes/mailcowdockerized_vmail-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_mysql-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_rspamd-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_postfix-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_dovecot-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_redis-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_crypt-vol-1/_data \
        /var/lib/docker/volumes/mailcowdockerized_clamd-vol-1/_data

    # ------------------------------
    # 解压恢复备份（忽略不存在的文件/卷）
    # ------------------------------
    echo "📦 解压恢复备份..."
    tar xzpf "$FILE" -C / --warning=no-file-ignored || true

    # ------------------------------
    # 修复 Docker volumes 权限
    # ------------------------------
    echo "🔧 修复 Docker volumes 权限..."
    for VOL in vmail mysql rspamd postfix dovecot redis crypt clamd; do
        DIR="/var/lib/docker/volumes/mailcowdockerized_${VOL}-vol-1/_data"
        [ -d "$DIR" ] || continue
        case "$VOL" in
            mysql) chown -R 999:999 "$DIR" ;;
            vmail) chown -R 5000:5000 "$DIR" ;;
            *) chown -R root:root "$DIR" ;;
        esac
    done

    # ------------------------------
    # 修复 Caddy 权限
    # ------------------------------
    chown -R caddy:caddy /etc/caddy /var/lib/caddy

    # ------------------------------
    # 启动 Mailcow
    # ------------------------------
    echo "🚀 启动 Mailcow..."
    cd "${MAILCOW_DIR}" || return
    docker compose up -d

    # ------------------------------
    # 启动 Caddy
    # ------------------------------
    echo "🚀 启动 Caddy..."
    systemctl enable caddy
    systemctl restart caddy



    # ------------------------------
    # 安装每日 2 点执行的 cron（防重复）
    # ------------------------------
    CRON_LINE="0 2 * * * /home/docker/mailcow-dockerized/zhengshufuzhi.sh"

    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null > "$TMP_CRON" || true
    grep -Fq "/home/docker/mailcow-dockerized/zhengshufuzhi.sh" "$TMP_CRON" \
        || echo "$CRON_LINE" >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm -f "$TMP_CRON"

    echo "✅ 恢复完成！Mailcow + Caddy 已启动"
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

    ZSFZ_SYNC="${MAILCOW_DIR}/zhengshufuzhiqita.sh"

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
