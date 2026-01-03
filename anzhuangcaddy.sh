#!/bin/bash

set -e

CONFIG_FILE="/etc/caddy/Caddyfile"

function install_caddy() {
    echo "🔄 安装 Caddy（官方二进制，兼容 Debian trixie）中..."

    apt update
    apt install -y sudo curl ca-certificates

    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64) CADDY_ARCH="amd64" ;;
        arm64) CADDY_ARCH="arm64" ;;
        *)
            echo "❌ 不支持的架构: $ARCH"
            exit 1
            ;;
    esac

    echo "📥 下载 Caddy 二进制 (${CADDY_ARCH})..."
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" \
        -o /usr/bin/caddy

    chmod +x /usr/bin/caddy

    echo "👤 创建 caddy 用户..."
    id -u caddy &>/dev/null || useradd --system --gid nogroup \
        --home /var/lib/caddy --shell /usr/sbin/nologin caddy

    echo "📂 创建目录..."
    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:nogroup /var/lib/caddy /var/log/caddy

    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

    echo "⚙️ 安装 systemd 服务..."
    cat <<'EOF' > /etc/systemd/system/caddy.service
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

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable --now caddy

    echo "✅ Caddy 安装完成"
    caddy version
}

function add_domain() {
    read -p "请输入你的域名（例如 www.123.com）: " DOMAIN
    read -p "请输入反向代理端口（例如 8008）: " PORT

    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF

    format_and_reload
}

function add_tls_skip_verify() {
    read -p "请输入你的域名（例如 www.123.com）: " DOMAIN
    read -p "请输入反向代理端口（例如 8443）: " PORT

    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

$DOMAIN {
    reverse_proxy https://127.0.0.1:$PORT {
        transport http {
            tls_insecure_skip_verify
        }
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF

    format_and_reload
}

function m3u8yunxing() {
    read -p "请输入你的域名（例如 www.14.com）: " DOMAIN

    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

$DOMAIN {
    root * /home/m3u8-app
    file_server
    header Access-Control-Allow-Origin *
}
EOF

    format_and_reload
}


function list_config() {
    echo "=============================="
    echo "        🛠 Caddy 管理脚本"
    echo "📄 当前配置内容："
    echo "------------------------------"
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "⚠️  当前还没有任何配置。"
        echo "------------------------------"
        return
    fi

    awk '
    BEGIN { count=0; block=""; inside=0 }
    /^[^# \t].*{$/ {
        if (inside == 0) {
            block=$0"\n"
            inside=1
        } else {
            block=block $0"\n"
        }
        next
    }
    inside == 1 {
        block=block $0"\n"
        if ($0 ~ /^}/) {
            count++
            printf "%d. %s\n", count, block
            block=""; inside=0
        }
    }
    ' "$CONFIG_FILE"
    echo "------------------------------"
}

function delete_config() {
    if ! [ -f "$CONFIG_FILE" ]; then
        echo "❌ 找不到配置文件。"
        return
    fi

    # 先提取所有配置块到数组
    mapfile -t BLOCKS < <(awk '
        BEGIN { block=""; inside=0 }
        /^[^# \t].*{$/ {
            block=$0"\n"
            inside=1
            next
        }
        inside==1 {
            block=block $0 "\n"
            if ($0 ~ /^}/) {
                print block
                block=""
                inside=0
            }
        }
    ' "$CONFIG_FILE")

    if [ ${#BLOCKS[@]} -eq 0 ]; then
        echo "⚠️  没有找到可删除的配置块。"
        return
    fi

    echo "请选择要删除的域名："
    for i in "${!BLOCKS[@]}"; do
        # 提取域名行，去掉尾部{及空格
        DOMAIN_LINE=$(echo "${BLOCKS[$i]}" | head -n 1 | sed 's/{.*//;s/ *$//')
        echo "$((i+1)). $DOMAIN_LINE"
    done

    read -p "请输入序号: " SELECTED
    INDEX=$((SELECTED - 1))

    if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#BLOCKS[@]}" ]; then
        DOMAIN_TO_DELETE=$(echo "${BLOCKS[$INDEX]}" | head -n 1 | sed 's/{.*//;s/ *$//')
        echo "🗑 正在删除配置域名：$DOMAIN_TO_DELETE"

        # 删除匹配域名开始的配置块，直到 } 行结束跳过
        sudo awk -v domain="$DOMAIN_TO_DELETE" '
        BEGIN { skip=0 }
        {
            if (skip==0) {
                if ($0 ~ domain) {
                    skip=1
                    next
                }
                print
            } else {
                if ($0 ~ /^}/) {
                    skip=0
                    next
                }
            }
        }
        ' "$CONFIG_FILE" > /tmp/caddy_tmp && sudo mv /tmp/caddy_tmp "$CONFIG_FILE"

        format_and_reload
    else
        echo "❌ 无效的选择。"
    fi
}









backup_caddy() {
    echo -e "${GREEN}▶️ 开始打包 Caddy 到 $BACKUP_FILE ...${RESET}"
    cd / || die "无法切换到根目录"
    tar -czvf "$BACKUP_FILE" etc/caddy var/lib/caddy/.local/share/caddy etc/systemd/system/caddy.service usr/bin/caddy
    echo -e "${GREEN}✅ 打包完成${RESET}"
}

restore_caddy() {
    [ -f "$BACKUP_FILE" ] || die "未找到备份文件 $BACKUP_FILE"
    file "$BACKUP_FILE" | grep -q gzip || die "备份文件不是 gzip 格式"

    echo -e "${GREEN}▶️ 开始恢复 Caddy...${RESET}"
    systemctl stop caddy 2>/dev/null

    cd / || die "无法切换到根目录"
    tar -xzvf "$BACKUP_FILE" || die "解压失败"

    ensure_user
    ensure_service

    chown -R caddy:nogroup /var/lib/caddy
    chmod -R 700 /var/lib/caddy

    # 验证关键文件
    [ -f /etc/caddy/Caddyfile ] || die "恢复失败：/etc/caddy/Caddyfile 不存在"
    [ -d /var/lib/caddy/.local/share/caddy ] || die "恢复失败：Caddy 数据目录不存在"

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable caddy
    systemctl start caddy

    echo -e "${GREEN}✅ 恢复完成${RESET}"
}

update_caddy() {
    echo "🔄 更新 Caddy..."
    systemctl stop caddy
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
    [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="arm64"
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$ARCH&idempotency=$(date +%s)" -o /usr/bin/caddy
    chmod +x /usr/bin/caddy
    systemctl daemon-reload
    systemctl start caddy
    echo "✅ 更新完成"
}

show_version() {
    if [ -x "$(command -v caddy)" ]; then
        caddy version
    else
        echo "Caddy 未安装"
    fi
}





















function uninstall_caddy() {
    echo "⚠️ 正在卸载 Caddy..."
    sudo systemctl stop caddy
    sudo apt remove --purge -y caddy
    sudo rm -f "$CONFIG_FILE"
    echo "✅ Caddy 已卸载"
}

function restart_caddy() {
    echo "🔁 重启 Caddy..."
    sudo systemctl restart caddy
    echo "✅ Caddy 已重启"
}

function stop_caddy() {
    echo "🛑 停止 Caddy..."
    sudo systemctl stop caddy
    echo "✅ Caddy 已停止"
}

function format_and_reload() {
    echo "🧹 格式化配置文件..."
    sudo caddy fmt --overwrite "$CONFIG_FILE"

    echo "🔁 重载配置..."
    if ! sudo caddy reload --config "$CONFIG_FILE" --adapter caddyfile; then
        echo "⚠️ 重载失败，尝试重启服务..."
        sudo systemctl restart caddy
    fi

    echo "✅ 配置已生效。"
}

function menu() {
    list_config
    echo "=============================="
    echo "1. 安装 Caddy"
    echo "2. 添加普通反向代理"
    echo "3. 重启 Caddy"
    echo "4. 停止 Caddy"
    echo "5. 添加 TLS Skip Verify 反向代理"
    echo "6. 删除指定域名配置"



    echo "=============================="
    echo "7. 打包 Caddy"
    echo "8. 解压恢复"
    echo "9. 更新 Caddy"
    echo "10. 查看当前版本"
    echo "=============================="

    echo "88. 添加M3U8反代配置"
    echo "99. 卸载 Caddy"
    echo "证书路径是"
    echo "/var/lib/caddy/.local/share/caddy/certificates/"
    
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) install_caddy ;;
        2) add_domain ;;
        3) restart_caddy ;;
        4) stop_caddy ;;
        5) add_tls_skip_verify ;;
        6) delete_config ;;


        7) backup_caddy ;;
        8) restore_caddy ;;
        9) update_caddy ;;
        10) show_version ;;



        88) m3u8yunxing ;;
        99) uninstall_caddy ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项，请重试" ;;
    esac
}

while true; do
    menu
done
