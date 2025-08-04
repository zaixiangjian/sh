#!/bin/bash

set -e

CONFIG_FILE="/etc/caddy/Caddyfile"

function install_caddy() {
    echo "🔄 安装 Caddy 中..."
    apt update
    apt install -y sudo curl gpg apt-transport-https debian-keyring debian-archive-keyring

    echo "📥 添加 GPG 密钥..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    echo "📦 添加软件源..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null

    echo "📦 安装 Caddy..."
    sudo apt update
    sudo apt install -y caddy

    echo "🧹 初始化空配置文件..."
    sudo bash -c "echo '' > $CONFIG_FILE"

    echo "✅ 安装完成！"
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

function list_config() {
    echo "=============================="
    echo "        🛠 Caddy 管理脚本"
    echo "📄 当前配置内容："
    echo "------------------------------"
    if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE"
    else
        echo "⚠️  当前还没有任何配置。"
    fi
    echo "------------------------------"
}

function delete_config() {
    if ! [ -f "$CONFIG_FILE" ]; then
        echo "❌ 找不到配置文件。"
        return
    fi

    mapfile -t DOMAINS < <(grep -E '^[^ #].*{$' "$CONFIG_FILE" | sed 's/ *{//')

    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo "⚠️  没有找到可删除的域名配置。"
        return
    fi

    echo "请选择要删除的域名："
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1)). ${DOMAINS[$i]}"
    done
    read -p "请输入序号: " SELECTED

    INDEX=$((SELECTED - 1))
    if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#DOMAINS[@]}" ]; then
        DOMAIN_TO_DELETE="${DOMAINS[$INDEX]}"
        echo "🗑 正在删除：$DOMAIN_TO_DELETE"

        sudo sed -i "/^$DOMAIN_TO_DELETE {/,/^}/d" "$CONFIG_FILE"
        format_and_reload
    else
        echo "❌ 无效的选择。"
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
    echo "3. 卸载 Caddy"
    echo "4. 重启 Caddy"
    echo "5. 停止 Caddy"
    echo "6. 添加 TLS Skip Verify 反向代理"
    echo "7. 删除指定域名配置"
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) install_caddy ;;
        2) add_domain ;;
        3) uninstall_caddy ;;
        4) restart_caddy ;;
        5) stop_caddy ;;
        6) add_tls_skip_verify ;;
        7) delete_config ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项，请重试" ;;
    esac
}

while true; do
    menu
done
