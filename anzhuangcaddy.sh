#!/bin/bash

# ======================================================
# 基础配置
# ======================================================
CONFIG_FILE="/etc/caddy/Caddyfile"
BACKUP_DIR="/home/caddy"
BACKUP_FILE="$BACKUP_DIR/caddy_backup.tar.gz"
CADDY_DATA_DIR="/var/lib/caddy/.local/share/caddy"
CADDY_BIN="/usr/bin/caddy"

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

# ======================================================
# 核心功能函数
# ======================================================

# 1. 安装 Caddy
install_caddy() {
    echo -e "${GREEN}🔄 正在检查并安装/修复 Caddy...${RESET}"
    if command -v caddy >/dev/null 2>&1; then
        if ! caddy version >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️ 检测到 Caddy 已损坏，准备强制修复...${RESET}"
            rm -f /usr/bin/caddy
        fi
    fi
    apt update && apt install -y sudo curl ca-certificates gnupg lsb-release
    if ! command -v caddy >/dev/null 2>&1; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update && apt install -y caddy
    fi
    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy
    systemctl enable caddy && systemctl restart caddy
    echo -e "${GREEN}✨ Caddy 就绪：$(caddy version)${RESET}"
}

# 2. 添加普通反向代理
add_domain() {
    read -rp "请输入你的域名: " DOMAIN
    read -rp "请输入反向代理端口: " PORT
    read -rp "请输入该网站的备注（必填）: " COMMENT
    if grep -q "$DOMAIN" "$CONFIG_FILE"; then
        echo "⚠️ 域名已存在" ; sleep 2 ; return
    fi
    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

# TAG: $COMMENT
$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF
    format_and_reload
}

# 3, 4, 5 基础控制
reload_caddy() { systemctl reload caddy ; }
restart_caddy() { systemctl restart caddy ; }
stop_caddy() { systemctl stop caddy ; }

# 6. 添加 TLS Skip Verify 反向代理（已修正为多行格式）
add_tls_skip_verify() {
    read -p "请输入你的域名: " DOMAIN
    read -p "请输入端口: " PORT
    read -p "请输入该网站的备注（必填）: " COMMENT
    
    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

# TAG: $COMMENT
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
    echo "✅ TLS Skip Verify 配置已添加！"
    sleep 2
}

# 7. Mailcow 配置
add_mailcow_config() {
    read -p "请输入你的主域名: " DOMAIN
    read -p "请输入反向代理端口: " PORT
    read -p "请输入该网站的备注: " COMMENT
    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

# TAG: $COMMENT
$DOMAIN, autodiscover.$DOMAIN, autoconfig.$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
}
EOF
    format_and_reload
    echo "✅ Mailcow 配置已添加！"
    sleep 2
}

# 8. 删除指定域名配置 (样式完全按照您的要求)
delete_config() {
    if [ ! -s "$CONFIG_FILE" ]; then echo "❌ 配置文件为空" ; return ; fi

    echo "=============================="
    echo "      🗑 删除配置管理"
    echo "=============================="
    
    mapfile -t INDEX_LIST < <(awk '/^# TAG: / { tag = substr($0, 8); next } /^[^# \t].*{$/ { printf "[%s] %s\n", (tag==""?"无备注":tag), $1; tag="" }' "$CONFIG_FILE")
    
    if [ ${#INDEX_LIST[@]} -eq 0 ]; then echo "⚠️ 未发现配置" ; return ; fi

    for i in "${!INDEX_LIST[@]}"; do
        echo "$((i+1)). ${INDEX_LIST[$i]}"
    done
    echo "=============================="
    echo "详细信息"
    echo "=============================="
    list_config_internal
    echo "=============================="

    read -p "请输入要删除的序号: " SELECTED
    if [[ ! "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -lt 1 ] || [ "$SELECTED" -gt "${#INDEX_LIST[@]}" ]; then
        echo "❌ 无效选择" ; return
    fi

    TARGET_INFO="${INDEX_LIST[$((SELECTED-1))]}"
    TARGET_DOMAIN=$(echo "$TARGET_INFO" | awk '{print $2}')
    TARGET_TAG=$(echo "$TARGET_INFO" | cut -d']' -f1 | sed 's/\[//')

    read -p "确定要删除 $TARGET_DOMAIN 吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        sed -i "/# TAG: $TARGET_TAG/,/^}/d" "$CONFIG_FILE"
        echo "🗑 已删除 $TARGET_DOMAIN 及其备注。"
        format_and_reload
    fi
}

# 11. 备份 Caddy
backup_caddy() {
    echo -e "${GREEN}▶️ 开始备份 Caddy...${RESET}"
    mkdir -p "$BACKUP_DIR"
    tar -czvf "$BACKUP_FILE" -C / etc/caddy var/lib/caddy etc/systemd/system/caddy.service usr/bin/caddy
    echo -e "${GREEN}✅ 备份完成：$BACKUP_FILE${RESET}"
}

# 12. 恢复 Caddy (确保备注 Comment 也能恢复)
restore_caddy_smart() {
    if [ ! -f "$BACKUP_FILE" ]; then echo "❌ 无备份文件" ; return ; fi
    TMP_DIR=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"
    RECOVER_CADDYFILE=$(find "$TMP_DIR" -name "Caddyfile" -type f | head -n 1)
    
    if [ -n "$RECOVER_CADDYFILE" ]; then
        BACKUP_DOMAINS=$(grep '{' "$RECOVER_CADDYFILE" | grep -v '^[[:space:]]' | grep -v '^#' | sed 's/{//g')
        while read -r DOMAIN_LINE; do
            FIRST_DOMAIN=$(echo "$DOMAIN_LINE" | awk '{print $1}' | sed 's/,//g')
            [ -z "$FIRST_DOMAIN" ] && continue
            if ! grep -q "$FIRST_DOMAIN" "$CONFIG_FILE"; then
                echo -e "\n# --- 恢复自备份 $(date +%F) ---" >> "$CONFIG_FILE"
                # 关键修复：恢复时同时抓取上一行的 # TAG: 备注
                awk -v domain="$FIRST_DOMAIN" '/^# TAG: / { tag=$0 } $0 ~ domain && $0 ~ "{" { if(tag!="") print tag; found=1 } found { print $0 } found && /^}/ { exit }' "$RECOVER_CADDYFILE" >> "$CONFIG_FILE"
            fi
        done <<< "$BACKUP_DOMAINS"
    fi
    cp -an "$TMP_DIR/var/lib/caddy/." "/var/lib/caddy/" 2>/dev/null
    chown -R caddy:caddy /etc/caddy /var/lib/caddy
    format_and_reload
    rm -rf "$TMP_DIR"
}

# 内部详细列表格式化输出
list_config_internal() {
    awk '
    BEGIN { tag = ""; block = ""; inside = 0 }
    /^# TAG: / { tag = substr($0, 8); next }
    /^[^# \t].*{$/ { inside = 1; block = $0; next }
    inside == 1 {
        block = block "\n" $0
        if ($0 ~ /^}/) {
            printf "[\033[36m%s\033[0m] %s\n\n", (tag==""?"无备注":tag), block
            tag = ""; block = ""; inside = 0
        }
    }' "$CONFIG_FILE"
}

# 菜单详细展示
list_config() {
    echo "=============================="
    echo "      🛠 Caddy 管理脚本"
    echo "📄 当前配置内容："
    echo "=============================="
    if [ ! -s "$CONFIG_FILE" ]; then echo "⚠️ 无配置。" ; return ; fi
    list_config_internal
}

# 其他维护功能
show_version() { caddy version ; }
view_logs() { journalctl -u caddy -f ; }
status_caddy() { systemctl status caddy ; }
uninstall_caddy() { 
    read -p "确定卸载？(y/n): " c
    [[ "$c" == "y" ]] && apt remove --purge -y caddy && rm -rf /etc/caddy /var/lib/caddy
}
update_caddy() { apt update && apt install --only-upgrade -y caddy && systemctl restart caddy ; }

# 核心格式化与校验函数
format_and_reload() {
    caddy fmt --overwrite "$CONFIG_FILE" 2>/dev/null
    if caddy validate --config "$CONFIG_FILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl restart caddy
        echo "✅ 配置已生效"
    else
        echo "❌ 配置有误，请手动检查 Caddyfile"
    fi
}

# ======================================================
# 主菜单
# ======================================================
menu() {
    clear
    list_config
    echo "1. 安装 Caddy"
    echo "2. 添加普通反向代理"
    echo "3. 重载配置"
    echo "4. 重启 Caddy"
    echo "5. 停止 Caddy"
    echo "=============================="
    echo "6. 添加 TLS Skip Verify 反向代理"
    echo "7. 添加邮箱 Mailcow 多子域名反向代理配置"
    echo "8. 删除指定域名配置"
    echo "9. 实时日志"
    echo "10. 查看状态"
    echo "=============================="
    echo "11. 备份 Caddy"
    echo "12. 恢复 Caddy（保留本地配置与证书）"
    echo "=============================="
    echo "88. 查看当前版本"
    echo "99. 卸载 Caddy"
    echo "00. 更新 Caddy"
    echo "=============================="
    echo -e "证书路径是: ${CYAN}/var/lib/caddy/.local/share/caddy/certificates/${RESET}"
    echo "=============================="
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) install_caddy ;; 2) add_domain ;; 3) reload_caddy ;;
        4) restart_caddy ;; 5) stop_caddy ;; 6) add_tls_skip_verify ;;
        7) add_mailcow_config ;; 8) delete_config ;; 9) view_logs ;;
        10) status_caddy ;; 11) backup_caddy ;; 12) restore_caddy_smart ;;
        88) show_version ;; 99) uninstall_caddy ;; 00) update_caddy ;;
        0) exit 0 ;; *) echo "❌ 无效选项" ; sleep 1 ;;
    esac
}

while true; do menu; done
