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
    
    # 基础依赖安装
    apt update && apt install -y sudo curl ca-certificates gnupg lsb-release

    if command -v caddy >/dev/null 2>&1; then
        if ! caddy version >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️ 检测到 Caddy 已损坏，准备强制修复...${RESET}"
            rm -f /usr/bin/caddy
        fi
    fi

    if ! command -v caddy >/dev/null 2>&1; then
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update && apt install -y caddy
    fi

    # --- 关键改进点 ---
    # 不管 apt 有没有创建用户，我们都调用修复函数强制补齐用户和权限
    fix_caddy_env 

    echo -e "${GREEN}✨ Caddy 就绪：$(caddy version)${RESET}"
}

# 2. 添加普通反向代理
add_domain() {
    # --- 1. 输入校验 ---
    while true; do
        read -rp "请输入你的域名（例如 www.123.com）: " DOMAIN
        [[ -n "$DOMAIN" ]] && break
        echo "❌ 域名不能为空"
    done

    while true; do
        read -rp "请输入反向代理端口（例如 8008）: " PORT
        [[ "$PORT" =~ ^[0-9]+$ ]] && break
        echo "❌ 端口必须是纯数字"
    done

    while true; do
        read -rp "请输入该网站的备注（必填，例如：网盘）: " COMMENT
        [[ -n "$COMMENT" ]] && break
        echo "❌ 备注不能为空，良好的备注是后期维护的关键"
    done

    # --- 2. 查重逻辑（防止配置冲突） ---
    if grep -q "$DOMAIN" "$CONFIG_FILE"; then
        echo "⚠️  域名 $DOMAIN 已存在于 Caddyfile 中，请勿重复添加！"
        read -rp "按回车返回..." _
        return
    fi

    # --- 3. 写入配置（带备注） ---
    # 格式：# [备注] 域名
    echo "📝 正在添加 $DOMAIN 的配置..."
    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null

# TAG: $COMMENT
$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT {
        header_up X-Real-IP {http.request.header.CF-Connecting-IP}
        header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
    }
}
EOF

    # 调用你定义的格式化与重启函数
    format_and_reload
    
    echo "✅ 域名 $DOMAIN 已成功添加！"
    sleep 2
}

# 3. 重载配置
reload_caddy() {
    echo "▶️ 正在重载 Caddy 配置..."
    if systemctl reload caddy; then
        echo -e "${GREEN}✅ 重载成功${RESET}"
    else
        echo -e "${RED}❌ 重载失败${RESET}"
    fi
    sleep 2
}

# 4. 重启 Caddy
restart_caddy() {
    echo "🔁 正在重启 Caddy..."
    if systemctl restart caddy; then
        echo -e "${GREEN}✅ 重启成功${RESET}"
    else
        echo -e "${RED}❌ 重启失败${RESET}"
    fi
    sleep 2
}

# 5. 停止 Caddy
stop_caddy() {
    echo "🛑 正在停止 Caddy..."
    if systemctl stop caddy; then
        echo -e "${RED}❌ 已停止${RESET}"
    else
        echo -e "${RED}❌ 停止操作失败${RESET}"
    fi
    sleep 2
}

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
                # 回复时间
                # echo -e "\n# --- 恢复自备份 $(date +%F) ---" >> "$CONFIG_FILE"
                # 关键修复：恢复时同时抓取上一行的 # TAG: 备注
                awk -v domain="$FIRST_DOMAIN" '/^# TAG: / { tag=$0 } $0 ~ domain && $0 ~ "{" { if(tag!="") print tag; found=1 } found { print $0 } found && /^}/ { exit }' "$RECOVER_CADDYFILE" >> "$CONFIG_FILE"
            fi
        done <<< "$BACKUP_DOMAINS"
fi
    cp -an "$TMP_DIR/var/lib/caddy/." "/var/lib/caddy/" 2>/dev/null
    
    # 修改这里：从单纯的 chown 改为调用全能修复函数
    fix_caddy_env
    
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



# 00. 更新 Caddy
update_caddy() {
    echo -e "${YELLOW}🚀 正在检查 Caddy 更新...${RESET}"

    # 当前版本
    OLD_VERSION=$(caddy version 2>/dev/null || echo "none")

    # 检测架构
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
    [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="arm64"

    # 下载官方最新 Caddy
    TMP_FILE="/tmp/caddy_new"
    echo "⏳ 下载官方最新 Caddy..."
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$ARCH" -o "$TMP_FILE"

    if [[ ! -s "$TMP_FILE" ]]; then
        echo -e "${RED}❌ 下载失败，可能网络或文件问题${RESET}"
        rm -f "$TMP_FILE"
        return
    fi

    chmod +x "$TMP_FILE"

    # 检查版本
    NEW_VERSION=$("$TMP_FILE" version 2>/dev/null)
    if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
        echo -e "${GREEN}✅ 已是最新版本 ($NEW_VERSION)${RESET}"
        rm -f "$TMP_FILE"
        return
    fi

    # 替换为新版本
    mv "$TMP_FILE" /usr/bin/caddy
    chmod +x /usr/bin/caddy

    # 修复权限和环境
    fix_caddy_env

    # 重启服务
    systemctl restart caddy
    echo -e "${GREEN}✅ 更新成功，新版本: $NEW_VERSION${RESET}"
}



# 000. 一键修复运行环境
fix_caddy_env() {
    echo -e "${YELLOW}🛠 正在检测并修复 Caddy 运行环境...${RESET}"
    
    # 1. 补齐组
    grep -q "^caddy:" /etc/group || groupadd --system caddy

    # 2. 补齐用户 (使用兼容性更好的短参数)
    if ! id "caddy" >/dev/null 2>&1; then
        useradd --system -g caddy -d /var/lib/caddy -s /usr/sbin/nologin -c "Caddy web server" caddy
        echo -e "${GREEN}✅ 已创建 caddy 用户${RESET}"
    fi

    # 3. 修正目录权限
    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy
    
    # 4. 重启尝试
    systemctl daemon-reload
    if systemctl restart caddy; then
        echo -e "${GREEN}✅ 环境修复成功，Caddy 已启动！${RESET}"
    else
        echo -e "${RED}❌ 权限已修复，但启动失败。请运行选项 9 查看日志。${RESET}"
    fi
    sleep 2
}








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
    echo "000. 一键修复 Caddy 环境 (用户/权限问题)"
    echo "=============================="
    echo -e "证书路径是: ${CYAN}/var/lib/caddy/.local/share/caddy/certificates/${RESET}"
    echo -e "配置文件路径: ${CYAN}/etc/caddy/${RESET}"
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
        000) fix_caddy_env ;;
        0) exit 0 ;; *) echo "❌ 无效选项" ; sleep 1 ;;
    esac
}

while true; do menu; done
