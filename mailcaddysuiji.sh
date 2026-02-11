#!/bin/bash

# ======================================================
# 配置路径
# ======================================================
MAILCOW_BASE="/home/docker/mailcow-dockerized"
POSTFIX_CONF_DIR="$MAILCOW_BASE/data/conf/postfix"
SASL_PASSWD="$POSTFIX_CONF_DIR/sasl_passwd"
SASL_RAW="$POSTFIX_CONF_DIR/sasl_passwd.raw"
HAPROXY_CONF="$MAILCOW_BASE/haproxy/haproxy.cfg"
POSTFIX_CONTAINER="mailcowdockerized-postfix-mailcow-1"
HAPROXY_CONTAINER="mail-relay-balancer"
DOCKER_NETWORK="mailcowdockerized_mailcow-network"

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

[[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1
mkdir -p "$MAILCOW_BASE/haproxy"
touch "$SASL_RAW"

# ======================================================
# 核心同步逻辑
# ======================================================
sync_all() {
    echo -e "${CYAN}🛠 正在重构 1:1 精确匹配轮询体系...${RESET}"
    
    if [ ! -s "$SASL_RAW" ]; then
        echo -e "${RED}❌ 错误: 中继列表为空${RESET}"; return
    fi

    # 1. 准备 HAProxy 配置 (多通道模式)
    cat <<EOF > "$HAPROXY_CONF"
global
    log stdout format raw local0
defaults
    mode tcp
    timeout connect 5s
    timeout client 1m
    timeout server 1m
EOF

    # 2. 准备 Postfix 变量
    MAP_STR="randmap:{"
    SASL_CONTENT=""
    local i=1
    ALIAS_STR=""

    # 循环处理每个账号，实现点对点映射
    while read -r line; do
        [[ -z "$line" ]] && continue
        
        # 提取数据
        REAL_SRV=$(echo "$line" | awk '{print $1}' | sed 's/[][]//g')
        USER_PASS=$(echo "$line" | awk '{print $2}')
        
        # 为每个后端创建一个 HAProxy 监听 (监听 2525 端口，但使用不同的网络别名触发)
        # 注意：这里我们让 HAProxy 容器拥有多个网络别名
        # 每个别名进入 HAProxy 时，我们根据访问的“目的端口”或“目的别名”无法在 TCP 模式下直接区分
        # 修正：我们将 HAProxy 设置为监听多个端口，对应不同的后端
        
        LISTEN_PORT=$((2525 + i - 1))
        
        cat <<EOF >> "$HAPROXY_CONF"
listen relay_channel_$i
    bind *:$LISTEN_PORT
    server s$i $REAL_SRV check inter 5s
EOF

        # Postfix 配置：每个别名对应一个唯一的本地端口
        MAP_STR="${MAP_STR}smtp:[$HAPROXY_CONTAINER]:$LISTEN_PORT,"
        SASL_CONTENT="${SASL_CONTENT}[$HAPROXY_CONTAINER]:$LISTEN_PORT    $USER_PASS\n"
        
        ((i++))
    done < "$SASL_RAW"

    MAP_STR="${MAP_STR%,}}"
    
    # 3. 写入 Postfix 密码本
    echo -e "$SASL_CONTENT" > "$SASL_PASSWD"

    # 4. 启动 HAProxy (只映射一个容器，不再需要网络别名，靠端口区分)
    docker rm -f "$HAPROXY_CONTAINER" 2>/dev/null
    docker run -d --name "$HAPROXY_CONTAINER" --network "$DOCKER_NETWORK" \
        -v "$HAPROXY_CONF":/usr/local/etc/haproxy/haproxy.cfg:ro --restart always haproxy:alpine >/dev/null

    # 5. 应用 Postfix 配置
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "sender_dependent_default_transport_maps = $MAP_STR"
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "smtp_sasl_auth_enable = yes"
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "smtp_sasl_password_maps = hash:/opt/postfix/conf/sasl_passwd"
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "smtp_sasl_security_options = noanonymous"
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "relayhost ="
    
    docker exec -i "$POSTFIX_CONTAINER" postmap /opt/postfix/conf/sasl_passwd
    docker exec -i "$POSTFIX_CONTAINER" postfix reload

    echo -e "${GREEN}✅ 1:1 轮询体系已就绪！${RESET}"
    echo "Postfix 将在端口 2525, 2526... 之间轮询，HAProxy 会将其精准导向对应服务器。"
}

# 1. 添加账号
add_account() {
    echo -e "\n${CYAN}--- 添加独立账号 ---${RESET}"
    read -rp "SMTP 地址 (如 mail.onetu.org): " HOST
    read -rp "端口 (默认 587): " PORT
    PORT=${PORT:-587}
    read -rp "邮箱账号: " USER
    read -rp "密码: " PASS
    
    [[ -z "$HOST" || -z "$USER" || -z "$PASS" ]] && return

    sed -i "/\[$HOST\]:$PORT/d" "$SASL_RAW" 2>/dev/null
    echo "[$HOST]:$PORT    $USER:$PASS" >> "$SASL_RAW"
    sync_all
}

# 5. 卸载
uninstall() {
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "sender_dependent_default_transport_maps ="
    docker exec -i "$POSTFIX_CONTAINER" postconf -e "relayhost ="
    docker exec -i "$POSTFIX_CONTAINER" postfix reload
    docker rm -f "$HAPROXY_CONTAINER" 2>/dev/null
    > "$SASL_RAW"
    echo "已卸载"; sleep 2
}

# ======================================================
# 主菜单
# ======================================================
while true; do
    clear
    echo -e "${CYAN}Mailcow 精确轮询管理 (Fixed 1:1 Port Mapping)${RESET}"
    echo "-----------------------------------------------"
    echo -e "${YELLOW}当前中继：${RESET}"
    [ ! -s "$SASL_RAW" ] && echo "  [ 空 ]" || awk '{print "  ● "$1}' "$SASL_RAW"
    echo "-----------------------------------------------"
    echo -e "1. ${GREEN}添加${RESET} 账号"
    echo -e "3. ${CYAN}同步${RESET}"
    echo -e "5. ${RED}卸载${RESET}"
    echo -e "6. 查看日志"
    echo -e "0. 退出"
    read -p "指令: " opt
    case "$opt" in
        1) add_account ;;
        3) sync_all ;;
        5) uninstall ;;
        6) docker logs -f "$POSTFIX_CONTAINER" ;;
        0) exit 0 ;;
    esac
done
