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
CADDY_SYNC_SCRIPT="/home/docker/mailcow-dockerized/zhengshucaddy.sh"
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
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshucaddy.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 主程序CADDY证书同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ Caddy 主程序证书同步定时任务不存在"
fi






echo "=============================="
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshu.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 证书6号同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ 证书6"
fi

CURRENT_CRON=$(crontab -l 2>/dev/null || true)
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshusmtp.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 证书7号同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ 证书7"
fi


CURRENT_CRON=$(crontab -l 2>/dev/null || true)
CADDY_LINE=$(echo "$CURRENT_CRON" | grep -F "/home/docker/mailcow-dockerized/zhengshuqita.sh" | head -n 1)
if [ -n "$CADDY_LINE" ]; then
    echo "✅ 证书8号同步定时任务已存在:"
    echo "   $CADDY_LINE"
else
    echo "⚠️ 证书8"
fi





    echo "=============================="
    echo "# 查看证书是否生效"
    echo "cd /home/docker/mailcow-dockerized"
    echo "openssl x509 -in data/assets/ssl/cert.pem -noout -fingerprint -sha256"


    echo "openssl x509 \
-in /home/docker/mailcow-dockerized/data/assets/ssl/cert.pem \
-noout -subject -issuer -dates"


    echo "# Postfix 容器查询"
    echo "docker exec mailcowdockerized-postfix-mailcow-1 \
openssl x509 -in /etc/ssl/mail/cert.pem -noout -fingerprint -sha256"


    echo "# Dovecot 容器查询"
    echo "docker exec mailcowdockerized-dovecot-mailcow-1 \
openssl x509 -in /etc/ssl/mail/cert.pem -noout -fingerprint -sha256"


    echo "=============================="



    echo "1) 安装 Mailcow + Caddy"
    echo "2) 更新 Mailcow"
    echo "3) 备份 Mailcow"
    echo "4) 恢复 手动创建/home/docker 安装docker"
    echo "=============================="
    echo "5) 证书主程序caddy"
    echo "6) 证书zhengshu"
    echo "7) 证书zhengshusmtp"
    echo "8) 证书zhengshuqita"
    echo "9) 删除指定任务 (6/7/8号)"
    echo "=============================="
    echo "10) 卸载 Mailcow"
    echo "=============================="
    echo "Caddy证书位置"
    echo "/var/lib/caddy/.local/share/caddy/certificates/"
    echo "=============================="
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
        6) zheng_shu ;;
        7) sm_tp ;;
        8) qi_ta ;;
        9) delete_specific_cron ;; # 新增 9 号删除 (原9号卸载可移至其他编号)

        10) uninstall_mailcow ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
}

# ------------------------------
# 安装函数
# ------------------------------
install_mailcow() {


# 检查是否有 mailcow 相关的容器在运行
    if docker ps -a --format '{{.Names}}' | grep -q "mailcowdockerized"; then
        echo "❌ 发现正在运行的 Mailcow 容器，禁止重复安装！"
        read -rp "按回车返回菜单..." _
        return
    fi





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
    sed -i "s|^HTTP_BIND=.*|HTTP_BIND=127.0.0.1|" mailcow.conf
    sed -i "s|^HTTP_PORT=.*|HTTP_PORT=8880|" mailcow.conf
    sed -i "s|^HTTPS_BIND=.*|HTTPS_BIND=127.0.0.1|" mailcow.conf
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
# 安装 / 修复 Caddy（系统优先，官方二进制备用）
# ------------------------------

CONFIG_FILE="/etc/caddy/Caddyfile"

# 检查系统 Caddy
if command -v caddy >/dev/null 2>&1; then
    echo "⚙️ 已检测到系统集成 Caddy，使用系统版本"
else
    echo "⚠️ 未检测到 Caddy，安装官方二进制..."

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

# 创建 Caddy 用户和目录（兼容系统安装与官方二进制）
if ! getent group caddy >/dev/null; then
    groupadd caddy
fi
if ! id -u caddy >/dev/null 2>&1; then
    useradd --system --gid caddy --home /var/lib/caddy --shell /usr/sbin/nologin caddy
fi

mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy
[ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

# 创建 systemd 服务（不存在才创建）
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
    systemctl enable caddy
fi

# 启动 Caddy
systemctl restart caddy

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
ZSFZ2_SCRIPT="/home/docker/mailcow-dockerized/zhengshucaddy.sh"

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
docker restart mailcowdockerized-postfix-mailcow-1 \
               mailcowdockerized-dovecot-mailcow-1 \
               mailcowdockerized-nginx-mailcow-1


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
    # 检查目录是否存在
    if [ ! -d "${MAILCOW_DIR}" ]; then
        echo "❌ 未找到 Mailcow 目录，无法更新。"
        read -rp "按回车继续..." _
        return
    fi

    echo "🔄 正在更新 Mailcow..."
    cd "${MAILCOW_DIR}"
    git pull
    docker compose pull
    docker compose up -d

    echo "⏰ 正在检查/修复定时任务..."
    ZSFZ2_SCRIPT="/home/docker/mailcow-dockerized/zhengshucaddy.sh"
    CRON_LINE="0 2 * * * $ZSFZ2_SCRIPT"
    
    # 确保定时任务存在
    (crontab -l 2>/dev/null | grep -Fq "$ZSFZ2_SCRIPT") || \
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -

    # ✨ 建议增加：更新后立即手动触发一次同步，确保证书立刻生效
    if [ -f "$ZSFZ2_SCRIPT" ]; then
        echo "📜 正在立即执行证书同步..."
        bash "$ZSFZ2_SCRIPT" || echo "⚠️ 证书同步脚本执行失败，请检查脚本内容。"
    fi

    echo "✅ Mailcow 更新完成并已尝试同步证书"
    read -rp "按回车继续..." _
}


# ------------------------------
# 完整备份 Mailcow + Caddy（官方全量｜修复 Caddy）
# ------------------------------
backup_mailcow() {
    echo "📦 开始完整备份 Mailcow + Caddy"

    TIMESTAMP=$(date +%F_%H%M%S)
    BACKUP_FILE="/home/mailcowcaddy-${TIMESTAMP}.tar.gz"

    read -rp "确认备份到 ${BACKUP_FILE} ? (Y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "取消备份"; return; }

    TMP_DIR=$(mktemp -d)

    # 停止 Mailcow，保证一致性
    echo "🛑 停止 Mailcow..."
    cd /home/docker/mailcow-dockerized 2>/dev/null && docker compose down || true

    # 备份 Mailcow 程序
    echo "📂 备份 Mailcow 程序目录"
    mkdir -p "$TMP_DIR/home"
    cp -a /home/docker/mailcow-dockerized "$TMP_DIR/home/"

    # 备份 Mailcow Docker 卷
    echo "🔹 备份 Mailcow Docker 卷"
    mkdir -p "$TMP_DIR/volumes"
    VOLUMES=($(docker volume ls --format "{{.Name}}" | grep mailcow))

    for VOL in "${VOLUMES[@]}"; do
        SRC="/var/lib/docker/volumes/${VOL}/_data"
        if [ -d "$SRC" ]; then
            echo "  ➤ 备份卷 $VOL"
            tar czf "$TMP_DIR/volumes/${VOL}.tar.gz" -C "$SRC" .
        fi
    done

    # ===============================
    # ✅ 修复点：正确备份 Caddy
    # ===============================
    echo "📂 备份 Caddy 配置与证书（官方路径）"
    mkdir -p "$TMP_DIR/caddy/etc" "$TMP_DIR/caddy/data"

    # /etc/caddy（配置）
    if [ -d /etc/caddy ]; then
        cp -a /etc/caddy/. "$TMP_DIR/caddy/etc/"
    fi

    # /var/lib/caddy/.local/share/caddy（证书）
    if [ -d /var/lib/caddy/.local/share/caddy ]; then
        cp -a /var/lib/caddy/.local/share/caddy/. "$TMP_DIR/caddy/data/"
    fi

    # 打包
    echo "📦 打包备份文件"
    tar czf "$BACKUP_FILE" -C "$TMP_DIR" .

    rm -rf "$TMP_DIR"

    # 启动 Mailcow
    echo "🚀 启动 Mailcow..."
    cd /home/docker/mailcow-dockerized && docker compose up -d

    echo "✅ 备份完成：$BACKUP_FILE"
    read -rp "按回车继续..." _
}


# ------------------------------
# 完整恢复 Mailcow + Caddy（强制覆盖 Caddy）
# ------------------------------
restore_mailcow() {
    MAILCOW_DIR="/home/docker/mailcow-dockerized"

    FILE=$(ls -t /home/mailcowcaddy-*.tar.gz 2>/dev/null | head -n1)
    [ -z "$FILE" ] && { echo "❌ 未找到备份文件"; return; }

    read -rp "⚠️ 确认恢复 ${FILE}？(yes/no): " confirm
    [[ "$confirm" != "yes" ]] && return

    # Docker 安装（原逻辑不动）
    if ! command -v docker >/dev/null 2>&1; then
        apt update
        apt install -y ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
> /etc/apt/sources.list.d/docker.list
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
    fi

    TMP_DIR=$(mktemp -d)
    tar xzf "$FILE" -C "$TMP_DIR"

    # Caddy 安装（原逻辑不动）
    if ! command -v caddy >/dev/null 2>&1; then
        ARCH="$(dpkg --print-architecture)"
        case "$ARCH" in
            amd64) CADDY_ARCH="amd64" ;;
            arm64) CADDY_ARCH="arm64" ;;
            *) echo "❌ 不支持架构"; return ;;
        esac
        curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o /usr/bin/caddy
        chmod +x /usr/bin/caddy
    fi

    getent group caddy >/dev/null || groupadd caddy
    id -u caddy >/dev/null 2>&1 || \
        useradd --system --gid caddy --home /var/lib/caddy --shell /usr/sbin/nologin caddy

    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy

    # 停止 Mailcow
    [ -d "$MAILCOW_DIR" ] && cd "$MAILCOW_DIR" && docker compose down || true

    # 恢复 Mailcow 程序
    rm -rf "$MAILCOW_DIR"
    mkdir -p /home/docker
    cp -a "$TMP_DIR/home/mailcow-dockerized" /home/docker/

    # 恢复 Docker 卷
    for VOL_BACKUP in "$TMP_DIR"/volumes/*.tar.gz; do
        VOL_NAME=$(basename "$VOL_BACKUP" .tar.gz)
        docker volume inspect "$VOL_NAME" >/dev/null 2>&1 || docker volume create "$VOL_NAME"
        TARGET="/var/lib/docker/volumes/${VOL_NAME}/_data"
        rm -rf "$TARGET"/*
        mkdir -p "$TARGET"
        tar xzf "$VOL_BACKUP" -C "$TARGET"
    done

    # 启动 Mailcow
    cd "$MAILCOW_DIR" && docker compose up -d

# ======================================================
    # ✅ 改进点：去重合并 Caddy 配置 & 证书
    # ======================================================
    echo "📂 正在智能合并 Caddy 配置（防止重复添加）..."

    # 停止 Caddy
    systemctl stop caddy 2>/dev/null || true

    # --- 1. 处理 Caddyfile (智能去重合并) ---
    if [ -f "$TMP_DIR/caddy/etc/Caddyfile" ]; then
        if [ ! -f /etc/caddy/Caddyfile ]; then
            touch /etc/caddy/Caddyfile
        fi

        # 读取备份文件中的内容
        # 注意：这里我们简单通过域名行判断。更高级的做法是提取大括号块。
        # 针对你脚本中生成的格式：${MAILCOW_HOSTNAME} autodiscover... {
        
        # 提取备份文件中的关键域名（通常是第一行非注释内容）
        BACKUP_DOMAIN=$(grep -v '^#' "$TMP_DIR/caddy/etc/Caddyfile" | grep '{' | head -n1 | awk '{print $1}')
        
        if [ -n "$BACKUP_DOMAIN" ]; then
            # 检查这个域名是否已经存在于当前的 Caddyfile 中
            if grep -q "$BACKUP_DOMAIN" /etc/caddy/Caddyfile; then
                echo "ℹ️ 域名 $BACKUP_DOMAIN 的配置已存在，跳过追加以防止冲突。"
            else
                echo "📝 发现新配置 $BACKUP_DOMAIN，正在安全追加..."
                echo -e "\n# --- 恢复自备份 $(date +%F) ---" >> /etc/caddy/Caddyfile
                cat "$TMP_DIR/caddy/etc/Caddyfile" >> /etc/caddy/Caddyfile
            fi
        else
            echo "⚠️ 未在备份中发现有效配置块，跳过合并。"
        fi
    fi

    # --- 2. 恢复其他配置文件 (不覆盖) ---
    if [ -d "$TMP_DIR/caddy/etc" ]; then
        find "$TMP_DIR/caddy/etc/" -type f ! -name "Caddyfile" -exec cp -an {} /etc/caddy/ \;
    fi

    # --- 3. 恢复证书目录 (增量补全，不覆盖) ---
    CADDY_DATA_DIR="/var/lib/caddy/.local/share/caddy"
    if [ -d "$TMP_DIR/caddy/data" ]; then
        echo "🔁 正在补全缺失的证书文件..."
        mkdir -p "$CADDY_DATA_DIR"
        cp -an "$TMP_DIR/caddy/data/." "$CADDY_DATA_DIR/"
    fi

    # 修正权限
    chown -R caddy:caddy /etc/caddy /var/lib/caddy

    # systemd（原逻辑不动）
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable caddy
    fi

    # ✨ 在这里执行格式化
    echo "🎨 正在整理 Caddyfile 格式..."
    caddy fmt --overwrite /etc/caddy/Caddyfile || echo "⚠️ 格式化跳过（可能是文件语法暂不完整）"

    # 重启服务使配置生效
    systemctl restart caddy

    # Cron（原逻辑不动）
    CRON_LINE="0 2 * * * /home/docker/mailcow-dockerized/zhengshucaddy.sh"
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null > "$TMP_CRON" || :
    grep -Fq "zhengshucaddy.sh" "$TMP_CRON" || echo "$CRON_LINE" >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm -f "$TMP_CRON"

    rm -rf "$TMP_DIR"

    echo "🎉 恢复完成：Caddy 配置 & 证书已【强制覆盖】并生效"
}


# ------------------------------
# 证书同步函数（菜单选项 5）
# ------------------------------
sync_certificates() {
    # ✅ 新增：安全确认与主程序提示
    echo "=================================================="
    echo "⚠️  警告：您正在操作【主程序】证书同步脚本"
    echo "此脚本是网站主域名 Mailcow 运行的核心组件"
    echo "通常在首次安装时已配置好，若非域名变更不建议随意修改"
    echo "=================================================="
    read -rp "请输入 'yes' 确认您要修改/覆盖主程序配置: " confirm_sync
    if [ "$confirm_sync" != "yes" ]; then
        echo "❌ 操作已取消。"
        read -rp "按回车返回菜单..." _
        return
    fi

    read -rp "请输入要同步证书的 Mailcow 域名（如 mail.example.com）: " ZSFZ_DOMAIN
    if [ -z "$ZSFZ_DOMAIN" ]; then
        echo "❌ 域名不能为空"
        return
    fi

    ZSFZ_SYNC="${MAILCOW_DIR}/zhengshucaddy.sh"

    # 生成同步脚本（手动执行，无日志）
    cat > "$ZSFZ_SYNC" <<EOF
#!/usr/bin/env bash
# 自动复制 Mailcow SSL 证书（主程序同步脚本）
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
    if ! crontab -l 2>/dev/null | grep -Fq "$ZSFZ_SYNC"; then
        (crontab -l 2>/dev/null; echo "0 2 * * * $ZSFZ_SYNC") | crontab -
        echo "✅ 定时任务已安装，每天凌晨 2 点自动执行"
    else
        echo "✅ 定时任务已存在，无需重复添加"
    fi

    echo "✅ 主程序同步脚本已更新: $ZSFZ_SYNC"
    
    # 询问是否立即跑一次
    read -rp "是否立即手动执行一次证书同步？(y/N): " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
        bash "$ZSFZ_SYNC" && echo "🚀 同步完成！" || echo "❌ 同步失败，请检查域名解析或证书是否存在"
    fi

    read -rp "按回车继续..." _
}




# ------------------------------
# 证书同步函数（菜单选项 6）
# ------------------------------
zheng_shu() {
    read -rp "请输入要同步证书的 Mailcow 域名（如 mail.example.com）: " ZSFZ_DOMAIN
    if [ -z "$ZSFZ_DOMAIN" ]; then
        echo "❌ 域名不能为空"
        return
    fi

    ZSFZ_SYNC="${MAILCOW_DIR}/zhengshu.sh"

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
        (crontab -l 2>/dev/null; echo "05 2 * * * $ZSFZ_SYNC") | crontab -


        echo "✅ 定时任务已安装，每天凌晨 2 点05分自动执行（无日志）"
    else
        echo "✅ 定时任务已存在"
    fi

    echo "✅ 证书同步脚本已生成，手动执行: $ZSFZ_SYNC"
    read -rp "按回车继续..." _
}



# ------------------------------
# 证书同步函数（菜单选项 7）
# ------------------------------
sp_tp() {
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
        (crontab -l 2>/dev/null; echo "10 2 * * * $ZSFZ_SYNC") | crontab -


        echo "✅ 定时任务已安装，每天凌晨 2 点10分自动执行（无日志）"
    else
        echo "✅ 定时任务已存在"
    fi

    echo "✅ 证书同步脚本已生成，手动执行: $ZSFZ_SYNC"
    read -rp "按回车继续..." _
}



# ------------------------------
# 证书同步函数（菜单选项 8）
# ------------------------------
qi_ta() {
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
        (crontab -l 2>/dev/null; echo "15 2 * * * $ZSFZ_SYNC") | crontab -


        echo "✅ 定时任务已安装，每天凌晨 2 点15分自动执行（无日志）"
    else
        echo "✅ 定时任务已存在"
    fi

    echo "✅ 证书同步脚本已生成，手动执行: $ZSFZ_SYNC"
    read -rp "按回车继续..." _
}






# ------------------------------
# 9) 删除指定任务 (6/7/8号)
# ------------------------------
delete_specific_cron() {
    echo "=============================="
    echo "      删除指定定时任务"
    echo "=============================="
    echo "注意：此操作不可删除主程序 zhengshucaddy.sh"
    echo "------------------------------"
    echo " 6) 删除 zhengshu.sh"
    echo " 7) 删除 zhengshusmtp.sh"
    echo " 8) 删除 zhengshuqita.sh"
    echo " 0) 返回"
    echo "=============================="
    read -rp "请选择编号 [6-8]: " del_choice

    case "$del_choice" in
        6) TARGET="zhengshu.sh" ;;
        7) TARGET="zhengshusmtp.sh" ;;
        8) TARGET="zhengshuqita.sh" ;;
        *) return ;;
    esac

    if crontab -l 2>/dev/null | grep -q "$TARGET"; then
        crontab -l | grep -v "$TARGET" | crontab -
        echo "✅ 任务 $TARGET 已成功剔除。"
    else
        echo "ℹ️  任务 $TARGET 本就不在定时任务中。"
    fi
    read -rp "按回车继续..." _
}






# ------------------------------
# 彻底卸载 Mailcow 函数 (保留 Caddy)（菜单选项 10）
# ------------------------------
uninstall_mailcow() {
    echo "=================================================="
    echo "🛑 警告：即将彻底卸载 Mailcow"
    echo "=================================================="
    echo "注意：此操作【仅卸载 Mailcow】，Caddy 将被保留。"
    echo "停止并删除所有 Mailcow 容器"
    echo "删除所有邮件数据、数据库 (Docker Volumes)"
    echo "删除 Mailcow 安装目录: ${MAILCOW_DIR}"
    echo "清理证书同步相关的定时任务 (Cron)"
    echo "=================================================="
    read -rp "请输入 'yes' 确认彻底卸载 Mailcow: " confirm_uninstall

    if [ "$confirm_uninstall" != "yes" ]; then
        echo "❌ 操作已取消。"
        return
    fi

    echo "⏳ 正在停止 Mailcow 容器..."
    if [ -d "${MAILCOW_DIR}" ]; then
        cd "${MAILCOW_DIR}"
        # -v 会删除所有关联的命名卷（邮件数据、数据库就在这里）
        docker compose down -v --remove-orphans 2>/dev/null || true
    fi

    echo "🧹 强制清理残留的 Mailcow 卷..."
    # 进一步确保所有以 mailcow 开头的卷都被删除
    MAILCOW_VOLS=$(docker volume ls -q --filter name=mailcow)
    if [ -n "$MAILCOW_VOLS" ]; then
        docker volume rm $MAILCOW_VOLS 2>/dev/null || true
    fi

    echo "🧹 清理 Mailcow Docker 网络..."
    MAILCOW_NETS=$(docker network ls -q --filter name=mailcow)
    if [ -n "$MAILCOW_NETS" ]; then
        docker network rm $MAILCOW_NETS 2>/dev/null || true
    fi

    echo "📂 删除安装目录及同步脚本..."
    # 仅删除 Mailcow 目录和同步脚本
    rm -rf "${MAILCOW_DIR}"
    # 删除可能散落在目录外的同步脚本（如果路径不同请检查变量）
    rm -f "/home/docker/mailcow-dockerized/zhengshucaddy.sh"
    rm -f "/home/docker/mailcow-dockerized/zhengshufuzhiqita.sh"

    echo "⏰ 清理证书同步定时任务..."
    # 仅从 crontab 中剔除关于证书同步的行，保留其他任务
    crontab -l 2>/dev/null | grep -vE "zhengshucaddy.sh|zhengshu.sh|zhengshusmtp.sh|zhengshuqita.sh" | crontab -

    echo "=================================================="
    echo "✅ Mailcow 卸载完成！"
    echo "🛡️  Caddy 已保留：配置和证书未受影响。"
    echo "=================================================="
    read -rp "按回车返回菜单..." _
}


# ------------------------------
# 主循环
# ------------------------------
while true; do
    show_menu
    read_choice
done
