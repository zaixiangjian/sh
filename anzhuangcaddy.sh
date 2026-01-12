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
RESET="\033[0m"

# ======================================================
# 核心功能函数
# ======================================================

# 格式化并重载 (内部调用)
format_and_reload() {
    echo "🧹 格式化并校验..."
    # 确保文件存在
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
    
    # 使用 caddy fmt 自动美化
    caddy fmt --overwrite "$CONFIG_FILE" >/dev/null 2>&1
    
    if caddy validate --config "$CONFIG_FILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl restart caddy
        echo -e "${GREEN}✅ 配置已生效并重启${RESET}"
    else
        echo -e "${RED}❌ 配置有误，请手动检查 $CONFIG_FILE${RESET}"
    fi
}

# 1. 安装 Caddy
install_caddy() {
    echo -e "${GREEN}🔄 安装/修复 Caddy...${RESET}"
    if ! command -v caddy >/dev/null 2>&1; then
        echo "⚠️ 未检测到 Caddy，安装官方二进制..."
        apt update && apt install -y sudo curl ca-certificates
        ARCH="$(dpkg --print-architecture)"
        case "$ARCH" in
            amd64) CADDY_ARCH="amd64" ;;
            arm64) CADDY_ARCH="arm64" ;;
            *) echo "❌ 不支持架构: $ARCH"; return ;;
        esac
        curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${CADDY_ARCH}" -o /usr/bin/caddy
        chmod +x /usr/bin/caddy
    fi

    getent group caddy >/dev/null || groupadd caddy
    id -u caddy >/dev/null 2>&1 || useradd --system --gid caddy --home /var/lib/caddy --shell /usr/sbin/nologin caddy
    
    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy
    [ -f "$CONFIG_FILE" ] || echo ":80 { root * /var/www/html }" > "$CONFIG_FILE"

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
    systemctl restart caddy
    echo "✅ Caddy 安装/修复完成"
    caddy version
}

# 2. 添加普通反向代理
add_domain() {
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
        read -rp "请输入该网站的备注（必填）: " COMMENT
        [[ -n "$COMMENT" ]] && break
        echo "❌ 备注不能为空"
    done

    if grep -q "$DOMAIN" "$CONFIG_FILE"; then
        echo -e "${RED}⚠️ 域名 $DOMAIN 已存在！${RESET}"
        return
    fi

    echo "📝 正在添加 $DOMAIN..."
    cat <<EOF >> "$CONFIG_FILE"

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

# 8. 删除指定域名配置
delete_config() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "❌ 配置文件为空。"
        return
    fi

    # 提取域名列表
    mapfile -t DOMAINS < <(grep -E '^[^# \t].*\{' "$CONFIG_FILE" | sed 's/{//g' | awk '{print $1}')
    
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        echo "⚠️ 未发现配置块。"
        return
    fi

    echo "已发现以下配置："
    for i in "${!DOMAINS[@]}"; do
        echo "$((i+1)). ${DOMAINS[$i]}"
    done

    read -rp "请输入要删除的序号: " SELECTED
    if [[ ! "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -lt 1 ] || [ "$SELECTED" -gt "${#DOMAINS[@]}" ]; then
        echo "❌ 无效选择"; return
    fi

    TARGET_DOMAIN="${DOMAINS[$((SELECTED-1))]}"
    read -rp "确定删除 $TARGET_DOMAIN? (y/n): " CONFIRM
    if [[ "$CONFIRM" == [yY] ]]; then
        # 删除逻辑：匹配域名行及其后直到第一个 } 结束的所有内容
        # 顺便尝试删除其上方的 TAG 行
        sed -i "/# TAG:.*$/,/$TARGET_DOMAIN/d" "$CONFIG_FILE" # 尝试清理上方的TAG
        sed -i "/$TARGET_DOMAIN/,/}/d" "$CONFIG_FILE"
        echo "🗑 已删除 $TARGET_DOMAIN。"
        format_and_reload
    fi
}

# 11. 备份 Caddy
backup_caddy() {
    echo -e "${GREEN}▶️ 开始备份...${RESET}"
    mkdir -p "$BACKUP_DIR"
    tar -czvf "$BACKUP_FILE" \
        /etc/caddy/Caddyfile \
        /var/lib/caddy \
        /etc/systemd/system/caddy.service \
        /usr/bin/caddy 2>/dev/null
    echo -e "${GREEN}✅ 备份成功：$BACKUP_FILE${RESET}"
}

# 12. 智能恢复
restore_caddy_smart() {
    if [ ! -f "$BACKUP_FILE" ]; then 
        echo -e "${RED}❌ 未找到备份文件${RESET}"; return
    fi
    
    TMP_DIR=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"
    
    # 简单的合并逻辑：如果备份里的域名本地没有，就追加
    SRC_FILE="$TMP_DIR/etc/caddy/Caddyfile"
    if [ -f "$SRC_FILE" ]; then
        while read -r domain; do
            if ! grep -q "$domain" "$CONFIG_FILE"; then
                echo "➕ 正在恢复域名: $domain"
                # 提取整个大括号块
                awk -v d="$domain" '$0 ~ d && $0 ~ "{" {p=1} p {print} p && /^}/ {p=0; exit}' "$SRC_FILE" >> "$CONFIG_FILE"
            fi
        done < <(grep '{' "$SRC_FILE" | grep -v '^[[:space:]]' | sed 's/{//g' | awk '{print $1}')
    fi
    
    # 恢复证书
    cp -an "$TMP_DIR/var/lib/caddy/." "/var/lib/caddy/" 2>/dev/null
    
    chown -R caddy:caddy /etc/caddy /var/lib/caddy
    format_and_reload
    rm -rf "$TMP_DIR"
}

# 其他简单函数保持原样并修复格式...
reload_caddy() { systemctl reload caddy && echo "OK"; }
restart_caddy() { systemctl restart caddy && echo "OK"; }
stop_caddy() { systemctl stop caddy && echo "OK"; }
view_logs() { journalctl -u caddy -f; }
status_caddy() { systemctl status caddy; }
show_version() { caddy version 2>/dev/null || echo "未安装"; }
uninstall_caddy() {
    systemctl stop caddy
    systemctl disable caddy
    rm -f /usr/bin/caddy /etc/systemd/system/caddy.service
    rm -rf /etc/caddy
    echo "✅ 已卸载"
}

# 查看列表
list_config() {
    echo -e "${YELLOW}📄 当前配置列表：${RESET}"
    if [ ! -s "$CONFIG_FILE" ]; then echo "空"; return; fi
    grep -E '^[^# \t].*\{|^# TAG:' "$CONFIG_FILE" | sed 's/{//g'
}

# ======================================================
# 主菜单
# ======================================================
menu() {
    # clear # 如果不希望每次清除屏幕可注释掉
    echo -e "\n--- Caddy 管理工具 ---"
    list_config
    echo "----------------------"
    echo "1. 安装 Caddy          2. 添加反代"
    echo "3. 重载配置            4. 重启服务"
    echo "5. 停止服务            8. 删除配置"
    echo "9. 实时日志            10. 查看状态"
    echo "11. 备份               12. 智能恢复"
    echo "88. 版本               99. 卸载"
    echo "0. 退出"
    read -p "请输入: " choice

    case "$choice" in
        1) install_caddy ;;
        2) add_domain ;;
        3) reload_caddy ;;
        4) restart_caddy ;;
        5) stop_caddy ;;
        8) delete_config ;;
        9) view_logs ;;
        10) status_caddy ;;
        11) backup_caddy ;;
        12) restore_caddy_smart ;;
        88) show_version ;;
        99) uninstall_caddy ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
}

while true; do
    menu
done
