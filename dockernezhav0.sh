#!/bin/bash

NEZHA_DIR="/opt/nezha/dashboard"
BACKUP_DIR="/home/备份"
IMAGE="zaixiangjian/nezhav0:latest"

# =========================
# Docker 安装检测
# =========================
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        return
    fi

    echo "未检测到 Docker，正在安装..."

    curl -fsSL https://get.docker.com | bash

    systemctl enable docker
    systemctl start docker

    echo "Docker 安装完成"
}

# =========================
# 1234 安装哪吒
# =========================
install_nezha() {

    install_docker

    mkdir -p "${NEZHA_DIR}/data"

    echo "请输入 GitHub 用户名:"
    read -r ADMIN

    echo "请输入 GitHub Client ID:"
    read -r CLIENT_ID

    echo "请输入 GitHub Client Secret:"
    read -r CLIENT_SECRET

    read -rp "请输入面板端口 (默认 8008): " PANEL_PORT
    PANEL_PORT=${PANEL_PORT:-8008}

    read -rp "请输入 Agent RPC 端口 (默认 5555): " AGENT_PORT
    AGENT_PORT=${AGENT_PORT:-5555}

    cat > "${NEZHA_DIR}/data/config.yaml" <<EOF
language: zh-CN

oauth2:
  type: github
  admin: ${ADMIN}
  clientid: ${CLIENT_ID}
  clientsecret: ${CLIENT_SECRET}
EOF

    cat > "${NEZHA_DIR}/docker-compose.yaml" <<EOF
services:
  dashboard:
    image: ${IMAGE}
    container_name: nezha-dashboard
    restart: always
    ports:
      - "${PANEL_PORT}:80"
      - "${AGENT_PORT}:${AGENT_PORT}"
    volumes:
      - ./data:/dashboard/data
    environment:
      - TZ=Asia/Shanghai
EOF

    cd "${NEZHA_DIR}" || exit 1

    docker compose pull
    docker compose up -d

    echo "✅ 安装完成"
}

# =========================
# 启动 / 停止
# =========================
start_nezha() {
    cd "${NEZHA_DIR}" || exit 1
    docker compose start
}

stop_nezha() {
    cd "${NEZHA_DIR}" || exit 1
    docker compose stop
}

# =========================
# 999 备份（完整目录）
# =========================
backup_nezha() {

    install_docker
    mkdir -p "${BACKUP_DIR}"

    cd "${NEZHA_DIR}" || exit 1

    echo "🛑 停止服务..."
    docker compose stop >/dev/null 2>&1

    TIME=$(date +"%Y%m%d_%H%M%S")
    FILE="${BACKUP_DIR}/nzhav0-${TIME}.tar.gz"

    echo "📦 备份整个目录..."

    # ✔ 关键修复：整个目录备份
    tar -zcf "${FILE}" -C "${NEZHA_DIR}" .

    echo "✅ 备份完成: ${FILE}"

    docker compose start >/dev/null 2>&1
}

# =========================
# 888 恢复（完整修复）
# =========================
restore_nezha() {

    install_docker
    mkdir -p "${BACKUP_DIR}"

    echo "🔍 扫描备份..."

    BACKUPS=($(ls -t ${BACKUP_DIR}/nzhav0-*.tar.gz 2>/dev/null))

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "❌ 没有备份"
        return
    fi

    i=1
    for file in "${BACKUPS[@]}"; do
        echo "$i) $(basename "$file")"
        ((i++))
    done

    echo "回车=最新"
    read -rp "请选择: " CHOICE

    FILE="${BACKUPS[0]}"

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -gt 0 ]; then
        FILE="${BACKUPS[$((CHOICE-1))]}"
    fi

    echo "📦 使用: $(basename "$FILE")"

    cd "${NEZHA_DIR}" 2>/dev/null && docker compose down >/dev/null 2>&1

    echo "🧹 清理旧目录..."
    rm -rf "${NEZHA_DIR}"
    mkdir -p "${NEZHA_DIR}"

    echo "📥 恢复数据..."

    # ✔ 修复：必须恢复到目标目录
    tar -zxf "$FILE" -C "${NEZHA_DIR}"

    cd "${NEZHA_DIR}" || exit 1

    # ✔ 防止 compose 丢失
    if [ ! -f docker-compose.yaml ]; then
        cat > docker-compose.yaml <<EOF
services:
  dashboard:
    image: ${IMAGE}
    container_name: nezha-dashboard
    restart: always
    ports:
      - "8008:80"
      - "5555:5555"
    volumes:
      - ./data:/dashboard/data
    environment:
      - TZ=Asia/Shanghai
EOF
    fi

    docker compose up -d

    echo "✅ 恢复完成"
}

# =========================
# 4 卸载
# =========================
uninstall_nezha() {

    read -rp "确认卸载?(y/N): " c
    [[ "$c" != "y" && "$c" != "Y" ]] && return

    cd "${NEZHA_DIR}" 2>/dev/null
    docker compose down >/dev/null 2>&1

    rm -rf "${NEZHA_DIR}"

    docker rmi ${IMAGE} >/dev/null 2>&1

    echo "✔ 已卸载"
}

# =========================
# 菜单
# =========================
while true; do
    clear
    echo "========================"
    echo "1 安装"
    echo "2 启动"
    echo "3 停止"
    echo "4 卸载"
    echo "888 恢复"
    echo "999 备份"
    echo "0 退出"
    echo "========================"

    read -rp "请选择: " num

    case $num in
        1|1234) install_nezha ;;
        2) start_nezha ;;
        3) stop_nezha ;;
        4) uninstall_nezha ;;
        888) restore_nezha ;;
        999) backup_nezha ;;
        0) exit 0 ;;
        *) echo "输入错误" ;;
    esac

    read -rp "回车继续..."
done
