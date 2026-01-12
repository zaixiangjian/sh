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

# 1. 安装 Caddy
install_caddy() {
    echo -e "${GREEN}🔄 正在检查并安装/修复 Caddy...${RESET}"

    # 检查当前 caddy 是否可用
    if command -v caddy >/dev/null 2>&1; then
        if ! caddy version >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️ 检测到 Caddy 已损坏 (Segmentation fault)，准备强制修复...${RESET}"
            rm -f /usr/bin/caddy  # 删除损坏的二进制
        fi
    fi

    # 安装基础依赖
    apt update && apt install -y sudo curl ca-certificates gnupg lsb-release

    # 官方源安装逻辑
    if ! command -v caddy >/dev/null 2>&1; then
        echo "🌐 正在添加官方仓库..."
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update
        apt install -y caddy
    else
        echo "✅ Caddy 运行正常，跳过安装。"
    fi

    # 权限与目录初始化
    mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
    chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy

    # 确保 Caddyfile 存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e ":80 {\n    respond \"Hello, Caddy!\"\n}" > "$CONFIG_FILE"
    fi

    # 刷新 systemd
    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy
    
    echo -e "${GREEN}✨ 修复完成，当前版本：$(caddy version)${RESET}"
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
    echo -e "${GREEN}▶️ 重载 Caddy 配置...${RESET}"
    systemctl reload caddy || echo -e "${RED}Caddy 重载失败${RESET}"
}

# 4. 重启 Caddy
restart_caddy() {
    echo "🔁 重启 Caddy..."
    sudo systemctl restart caddy
    echo "✅ Caddy 已重启"
}

# 5. 停止 Caddy
stop_caddy() {
    echo "🛑 停止 Caddy..."
    sudo systemctl stop caddy
    echo "✅ Caddy 已停止"
}

# 6. 添加 TLS Skip Verify
add_tls_skip_verify() {
    read -p "请输入你的域名: " DOMAIN
    read -p "请输入端口: " PORT
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

# 7. Mailcow 配置
add_mailcow_config() {
    read -p "请输入你的主域名（例如 mail.example.com）: " DOMAIN
    read -p "请输入反向代理端口（例如 8880）: " PORT
    cat <<EOF | sudo tee -a "$CONFIG_FILE" > /dev/null
$DOMAIN, autodiscover.$DOMAIN, autoconfig.$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
}
EOF
    format_and_reload
    echo "✅ 已添加 Mailcow 配置"
}

# 8. 删除指定域名配置
delete_config() {
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "❌ 配置文件为空或不存在。"
        return
    fi

    # --- 第一阶段：显示简洁索引 ---
    echo "=============================="
    echo "      🗑  删除配置管理"
    echo "=============================="
    
    # 提取备注和域名生成索引列表，存入数组
    mapfile -t INDEX_LIST < <(awk '
        /^# TAG: / { tag = substr($0, 8); next }
        /^[^# \t].*{$/ { 
            display_tag = (tag == "" ? "无备注" : tag);
            printf "[%s] %s\n", display_tag, $1;
            tag = "";
        }
    ' "$CONFIG_FILE")

    if [ ${#INDEX_LIST[@]} -eq 0 ]; then
        echo "⚠️  未发现可删除的配置块。"
        return
    fi

    for i in "${!INDEX_LIST[@]}"; do
        echo "$((i+1)). ${INDEX_LIST[$i]}"
    done

    echo ""
    echo "请选择要删除的域名序号："
    
    # --- 第二阶段：显示带行号的完整内容供核对 ---
    echo "------------------------------"
    echo "完整配置预览 (供核对):"
    cat -n "$CONFIG_FILE"
    echo "------------------------------"

    read -p "请输入序号: " SELECTED
    
    # 校验输入有效性
    if [[ ! "$SELECTED" =~ ^[0-9]+$ ]] || [ "$SELECTED" -lt 1 ] || [ "$SELECTED" -gt "${#INDEX_LIST[@]}" ]; then
        echo "❌ 无效的选择，已取消。"
        return
    fi

    # 获取用户选择的域名（从索引中提取）
    TARGET_LINE="${INDEX_LIST[$((SELECTED-1))]}"
    # 提取方括号后的域名部分
    TARGET_DOMAIN=$(echo "$TARGET_LINE" | awk '{print $2}' | sed 's/,//g')

    read -p "确定要删除 $TARGET_DOMAIN 及其配置吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]]; then
        # 执行删除：从匹配域名的行开始，删除到最近的结束大括号 }
        # 注意：这里假设你的配置块是以 } 结尾且顶格
        sed -i "/$TARGET_DOMAIN/,/^}/d" "$CONFIG_FILE"
        
        # 同时尝试删除该块上方的 TAG 行
        # 匹配逻辑：如果某行是 TAG 备注，且下一行就是刚删掉的内容（现在变为空行或新域名），则清理
        sed -i "/# TAG:.*$(echo "$TARGET_LINE" | cut -d' ' -f1 | tr -d '[]')/d" "$CONFIG_FILE"

        echo "🗑  已删除 $TARGET_DOMAIN。"
        format_and_reload
    else
        echo "↩️  操作已取消。"
    fi
}

# 9. 实时日志
view_logs() {
    journalctl -u caddy -f
}

# 10. 查看状态
status_caddy() {
    systemctl status caddy
}

# ======================================================
# 11. 备份 Caddy
# ======================================================
backup_caddy() {
    echo -e "${GREEN}▶️ 开始备份 Caddy...${RESET}"
    mkdir -p "$BACKUP_DIR"
    
    # 切换到根目录进行打包，确保路径结构为 etc/caddy... 而非绝对路径
    # 这样可以极大提高恢复时的兼容性
    tar -czvf "$BACKUP_FILE" -C / \
        etc/caddy \
        var/lib/caddy \
        etc/systemd/system/caddy.service \
        usr/bin/caddy

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 备份成功：$BACKUP_FILE${RESET}"
    else
        echo -e "${RED}❌ 备份失败${RESET}"
    fi
}

# ======================================================
# 12. 恢复 Caddy（智能去重合并）
# ======================================================
restore_caddy_smart() {
    if [ ! -f "$BACKUP_FILE" ]; then 
        echo -e "${RED}❌ 未找到备份文件 $BACKUP_FILE${RESET}"
        return
    fi
    
    echo -e "${YELLOW}📂 正在执行智能去重合并恢复...${RESET}"
    systemctl stop caddy 2>/dev/null || true
    
    TMP_DIR=$(mktemp -d)
    tar -xzf "$BACKUP_FILE" -C "$TMP_DIR"

    # --- 1. 定位 Caddyfile ---
    RECOVER_CADDYFILE=$(find "$TMP_DIR" -name "Caddyfile" -type f | head -n 1)
    
    if [ -n "$RECOVER_CADDYFILE" ] && [ -f "$RECOVER_CADDYFILE" ]; then
        echo "🔍 找到备份配置: $RECOVER_CADDYFILE"
        [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"
        
        # 提取备份中所有的域名（过滤注释和空行，只取 { 前的内容）
        # 这里使用 awk 确保只抓取顶格的域名行
        BACKUP_DOMAINS=$(grep '{' "$RECOVER_CADDYFILE" | grep -v '^[[:space:]]' | grep -v '^#' | sed 's/{//g')
        
        # 为了防止 sed 嵌套错误，我们改用一种更安全的方式：
        # 将备份文件中的每个域名块单独提取，并检查本地是否存在
        while read -r DOMAIN_LINE; do
            # 获取该行第一个域名作为判断标识
            FIRST_DOMAIN=$(echo "$DOMAIN_LINE" | awk '{print $1}' | sed 's/,//g')
            [ -z "$FIRST_DOMAIN" ] && continue

            if grep -q "$FIRST_DOMAIN" "$CONFIG_FILE"; then
                echo -e "${YELLOW}ℹ️ 域名 $FIRST_DOMAIN 已存在，跳过。${RESET}"
            else
                echo -e "${GREEN}📝 发现新配置 $FIRST_DOMAIN，正在追加...${RESET}"
                
                # 关键修复：使用 awk 提取从特定域名行开始，到遇到第一个顶格的 } 为止的内容
                # 这样可以完美避开配置块内部的层级干扰
                echo -e "\n# --- 恢复自备份 $(date +%F) ---" >> "$CONFIG_FILE"
                awk -v start="$FIRST_DOMAIN" '
                    $0 ~ start && $0 ~ "{" {found=1}
                    found {print $0}
                    found && /^}/ {found=0; exit}
                ' "$RECOVER_CADDYFILE" >> "$CONFIG_FILE"
            fi
        done <<< "$BACKUP_DOMAINS"
    else
        echo -e "${RED}❌ 备份包内未找到 Caddyfile${RESET}"
    fi

    # --- 2. 恢复证书 (增量补全) ---
    RECOVER_DATA_DIR=$(find "$TMP_DIR" -type d -path "*/var/lib/caddy" | head -n 1)
    if [ -d "$RECOVER_DATA_DIR" ]; then
        echo "🔁 正在补全缺失的证书文件..."
        cp -an "$RECOVER_DATA_DIR/." "/var/lib/caddy/"
    fi

    # --- 3. 权限修正与清理 ---
    chown -R caddy:caddy /etc/caddy /var/lib/caddy
    chmod +x /usr/bin/caddy 2>/dev/null || true
    
    # 使用 caddy fmt 强制重新整理所有大括号层级
    echo "🎨 正在优化 Caddyfile 布局格式..."
    caddy fmt --overwrite "$CONFIG_FILE" 2>/dev/null || true
    
    systemctl daemon-reload
    systemctl restart caddy
    rm -rf "$TMP_DIR"
    echo -e "${GREEN}✅ 智能恢复与合并完成！${RESET}"
}












88. 查看当前版本
show_version() {
    echo -ne "${GREEN}🔍 正在检查 Caddy 状态: ${RESET}"
    
    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}未安装${RESET}"
        return 1
    fi

    # 尝试运行 caddy version
    VERSION_INFO=$(caddy version 2>&1)
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}运行中${RESET}"
        echo -e "📦 版本信息: $VERSION_INFO"
        echo -e "📍 程序路径: $(which caddy)"
    elif [ $EXIT_CODE -eq 139 ]; then
        # 139 通常是 Segmentation fault 的退出码
        echo -e "${RED}程序已损坏 (Segmentation fault)${RESET}"
        echo -e "${YELLOW}提示: 请尝试运行 1 号选项或 00 选项进行修复。${RESET}"
    else
        echo -e "${RED}异常 (错误码: $EXIT_CODE)${RESET}"
        echo -e "具体报错: $VERSION_INFO"
    fi
}


# 99. 卸载 Caddy
uninstall_caddy() {
    echo "⚠️ 正在卸载 Caddy..."
    systemctl stop caddy
    apt remove --purge -y caddy 2>/dev/null || rm -f /usr/bin/caddy
    rm -rf /etc/caddy
    echo "✅ Caddy 已卸载"
}

# 辅助函数：格式化并重载
format_and_reload() {
    echo "🧹 格式化并校验..."
    caddy fmt --overwrite "$CONFIG_FILE" 2>/dev/null
    if caddy validate --config "$CONFIG_FILE" --adapter caddyfile >/dev/null 2>&1; then
        systemctl restart caddy
        echo "✅ 配置已生效"
    else
        echo "❌ 配置有误，请检查 Caddyfile"
    fi
}

# 00. 更新 Caddy（安全更新版）
update_caddy() {
    echo -e "${YELLOW}🚀 正在尝试安全更新 Caddy...${RESET}"
    
    # 优先使用 apt 更新
    if dpkg -l | grep -q caddy; then
        apt update && apt install --only-upgrade -y caddy
    else
        # 如果不是 apt 安装的，则手动下载
        ARCH=$(uname -m)
        [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
        [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="arm64"
        
        # 下载到临时文件，防止直接覆盖时下载中断导致损坏
        echo "⬇️ 正在下载最新版 ($ARCH)..."
        curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$ARCH" -o /tmp/caddy_new
        
        if [ $? -eq 0 ] && [ -s /tmp/caddy_new ]; then
            chmod +x /tmp/caddy_new
            # 简单校验下载的文件是否能运行
            if /tmp/caddy_new version >/dev/null 2>&1; then
                mv /tmp/caddy_new /usr/bin/caddy
                echo "✅ 更新成功！"
            else
                echo "❌ 下载的文件似乎损坏，已放弃替换。"
                rm -f /tmp/caddy_new
                return 1
            fi
        else
            echo "❌ 下载失败，请检查网络。"
            return 1
        fi
    fi
    systemctl restart caddy
}



function list_config() {
    echo "=============================="
    echo "        🛠 Caddy 管理脚本"
    echo "📄 当前配置内容："
    echo "=============================="
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo "⚠️  当前还没有任何配置。"
        echo "------------------------------"
        return
    fi

    # 使用 awk 提取 备注 + 完整配置块
    awk '
    BEGIN { count = 0; tag = ""; block = ""; inside = 0 }

    # 1. 捕获 TAG 备注行
    /^# TAG: / { 
        tag = substr($0, 8); 
        next 
    }

    # 2. 捕获块开始 (顶格域名 + {)
    /^[^# \t].*{$/ {
        inside = 1
        block = $0
        next
    }

    # 3. 捕获块内部及结束
    inside == 1 {
        block = block "\n" $0
        # 匹配顶格的结束大括号
        if ($0 ~ /^}/) {
            count++
            display_tag = (tag == "" ? "未归类" : tag)
            # 输出格式：数字. [备注] 完整块
            printf "%d. [\033[36m%s\033[0m] %s\n\n", count, display_tag, block
            
            # 重置变量供下一个块使用
            tag = ""
            block = ""
            inside = 0
        }
    }
    ' "$CONFIG_FILE"

    echo "=============================="
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
    echo "证书路径是"
    echo "/var/lib/caddy/.local/share/caddy/certificates/"
    echo "=============================="
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) install_caddy ;;
        2) add_domain ;;
        3) reload_caddy ;;
        4) restart_caddy ;;
        5) stop_caddy ;;
        6) add_tls_skip_verify ;;
        7) add_mailcow_config ;;
        8) delete_config ;;
        9) view_logs ;;
        10) status_caddy ;;

        11) backup_caddy ;;
        12) restore_caddy_smart ;;


        88) show_version ;;
        99) uninstall_caddy ;;
        00) update_caddy ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项" ; sleep 1 ;;
    esac
}

while true; do
    menu
done
