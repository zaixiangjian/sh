#!/bin/bash
set -e

CONFIG_FILE="/etc/caddy/Caddyfile"
CADDY_BIN="/usr/local/bin/caddy"
XCADDY_BIN="/usr/local/bin/xcaddy"
GO_VERSION="1.21.1"  # 可根据需要修改为最新稳定版
CF_API_TOKEN_PLACEHOLDER="你的Cloudflare_API_Token"

# 安装 Go
install_go() {
    if command -v go >/dev/null 2>&1; then
        echo "✅ 已安装 Go: $(go version)"
        return
    fi

    echo "🔄 安装 Go..."
    wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -O /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo "export PATH=\$PATH:/usr/local/go/bin" >> ~/.bashrc
    go version
}

# 安装 xcaddy
install_xcaddy() {
    if command -v xcaddy >/dev/null 2>&1; then
        echo "✅ 已安装 xcaddy: $(xcaddy version)"
        return
    fi

    echo "🔄 安装 xcaddy..."
    wget https://github.com/caddyserver/xcaddy/releases/download/v0.4.5/xcaddy_0.4.5_linux_amd64.tar.gz -O /tmp/xcaddy.tar.gz
    tar -xzf /tmp/xcaddy.tar.gz -C /tmp/
    mv /tmp/xcaddy $XCADDY_BIN
    chmod +x $XCADDY_BIN
    echo "✅ xcaddy 安装完成: $($XCADDY_BIN version)"
}

# 编译 Caddy 带 Cloudflare DNS 插件
build_caddy() {
    echo "🔨 编译 Caddy 带 Cloudflare DNS 插件..."
    $XCADDY_BIN build --with github.com/caddy-dns/cloudflare --output $CADDY_BIN
    chmod +x $CADDY_BIN
    echo "✅ Caddy 编译完成: $($CADDY_BIN version)"
}

# 初始化 Caddy 配置和 systemd
init_caddy() {
    echo "🧹 初始化 Caddy 配置..."
    mkdir -p /etc/caddy
    touch $CONFIG_FILE

    echo "🔧 创建 systemd 服务..."
    cat <<EOF >/etc/systemd/system/caddy.service
[Unit]
Description=Caddy DNS-01 Service
After=network.target

[Service]
Environment=CF_API_TOKEN=$CF_API_TOKEN_PLACEHOLDER
ExecStart=$CADDY_BIN run --config $CONFIG_FILE --adapter caddyfile
Restart=always
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy
    echo "✅ 初始化完成，Caddy 可后台启动"
}

# 添加普通反向代理
add_domain() {
    read -p "请输入域名（例如 www.123.com）: " DOMAIN
    read -p "请输入反向代理端口（例如 8006）: " PORT

    cat <<EOF >> "$CONFIG_FILE"

$DOMAIN {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy 127.0.0.1:$PORT {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF
    reload_caddy
}

# 添加 TLS Skip Verify 反向代理
add_tls_skip_verify() {
    read -p "请输入域名（例如 www.123.com）: " DOMAIN
    read -p "请输入反向代理端口（例如 8443）: " PORT

    cat <<EOF >> "$CONFIG_FILE"

$DOMAIN {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    reverse_proxy https://127.0.0.1:$PORT {
        transport http {
            tls_insecure_skip_verify
        }
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF
    reload_caddy
}

# 删除指定域名配置
delete_config() {
    if ! [ -f "$CONFIG_FILE" ]; then
        echo "❌ 配置文件不存在"
        return
    fi

    mapfile -t BLOCKS < <(awk '
        BEGIN { block=""; inside=0 }
        /^[^# \t].*{$/ { block=$0"\n"; inside=1; next }
        inside==1 { block=block $0 "\n"; if ($0 ~ /^}/) { print block; block=""; inside=0 } }
    ' "$CONFIG_FILE")

    if [ ${#BLOCKS[@]} -eq 0 ]; then
        echo "⚠️ 没有配置可删除"
        return
    fi

    echo "请选择要删除的域名："
    for i in "${!BLOCKS[@]}"; do
        DOMAIN_LINE=$(echo "${BLOCKS[$i]}" | head -n 1 | sed 's/{.*//;s/ *$//')
        echo "$((i+1)). $DOMAIN_LINE"
    done

    read -p "请输入序号: " SELECTED
    INDEX=$((SELECTED - 1))

    if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#BLOCKS[@]}" ]; then
        DOMAIN_TO_DELETE=$(echo "${BLOCKS[$INDEX]}" | head -n 1 | sed 's/{.*//;s/ *$//')
        echo "🗑 删除 $DOMAIN_TO_DELETE"

        awk -v domain="$DOMAIN_TO_DELETE" '
        BEGIN { skip=0 }
        {
            if (skip==0) {
                if ($0 ~ domain) { skip=1; next }
                print
            } else {
                if ($0 ~ /^}/) { skip=0; next }
            }
        }
        ' "$CONFIG_FILE" > /tmp/caddy_tmp && mv /tmp/caddy_tmp "$CONFIG_FILE"

        reload_caddy
    else
        echo "❌ 无效选择"
    fi
}

# 卸载 Caddy
uninstall_caddy() {
    echo "⚠️ 卸载 Caddy..."
    systemctl stop caddy
    systemctl disable caddy
    rm -f $CONFIG_FILE $CADDY_BIN $XCADDY_BIN
    rm -f /etc/systemd/system/caddy.service
    systemctl daemon-reload
    echo "✅ 已卸载 Caddy"
}

# 重启 Caddy
restart_caddy() {
    echo "🔁 重启 Caddy..."
    systemctl restart caddy
    echo "✅ 重启完成"
}

# 停止 Caddy
stop_caddy() {
    echo "🛑 停止 Caddy..."
    systemctl stop caddy
    echo "✅ 已停止"
}

# 格式化并重载 Caddy
reload_caddy() {
    $CADDY_BIN fmt --overwrite "$CONFIG_FILE"
    if ! $CADDY_BIN reload --config "$CONFIG_FILE" --adapter caddyfile; then
        echo "⚠️ 重载失败，尝试重启服务..."
        systemctl restart caddy
    fi
    echo "✅ 配置生效"
}

# 列出配置
list_config() {
    echo "=============================="
    echo "        🛠 Caddy 管理脚本"
    echo "📄 当前配置内容："
    echo "------------------------------"
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "⚠️ 当前没有配置"
        echo "------------------------------"
        return
    fi
    awk '
    BEGIN { count=0; block=""; inside=0 }
    /^[^# \t].*{$/ { block=$0"\n"; inside=1; next }
    inside==1 { block=block $0"\n"; if ($0 ~ /^}/) { count++; printf "%d. %s\n", count, block; block=""; inside=0 } }
    ' "$CONFIG_FILE"
    echo "------------------------------"
}

# 设置 CF_API_TOKEN
set_cf_token() {
    read -p "请输入你的 Cloudflare API Token: " TOKEN
    export CF_API_TOKEN="$TOKEN"
    echo "✅ 当前 shell 已设置 CF_API_TOKEN"

    # 同步到 systemd 服务
    if [ -f /etc/systemd/system/caddy.service ]; then
        sudo sed -i "s|Environment=CF_API_TOKEN=.*|Environment=CF_API_TOKEN=$TOKEN|" /etc/systemd/system/caddy.service
        sudo systemctl daemon-reload
        echo "✅ systemd 服务的 CF_API_TOKEN 已更新"
    fi
}

# 主菜单
menu() {
    list_config
    echo "=============================="
    echo "1. 安装 Caddy (带 Cloudflare DNS)"
    echo "2. 添加普通反向代理"
    echo "3. 添加 TLS Skip Verify 反向代理"
    echo "4. 删除指定域名配置"
    echo "5. 重启 Caddy"
    echo "6. 停止 Caddy"
    echo "7. 卸载 Caddy"
    echo "8. 设置 Cloudflare API Token"
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) install_go; install_xcaddy; build_caddy; init_caddy ;;
        2) add_domain ;;
        3) add_tls_skip_verify ;;
        4) delete_config ;;
        5) restart_caddy ;;
        6) stop_caddy ;;
        7) uninstall_caddy ;;
        8) set_cf_token ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项，请重试" ;;
    esac
}

while true; do
    menu
done
