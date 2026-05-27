#!/bin/bash

APP_DIR="/home/docker/sub2api"
BACKUP_DIR="/home"
APP_PORT="18080"

# ==============================
# 工具函数
# ==============================

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

pause() {
    echo ""
    read -p "按回车继续..."
}

# ==============================
# 安装
# ==============================

install_app() {
    mkdir -p "$APP_DIR"
    cd "$APP_DIR" || exit

    echo "正在生成配置..."

    POSTGRES_PASSWORD=$(openssl rand -hex 32)
    JWT_SECRET=$(openssl rand -hex 32)
    TOTP_KEY=$(openssl rand -hex 32)
    ADMIN_PASSWORD=$(openssl rand -hex 16)

    cat > .env <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
JWT_SECRET=$JWT_SECRET
TOTP_ENCRYPTION_KEY=$TOTP_KEY
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=$ADMIN_PASSWORD
POSTGRES_DB=sub2api
POSTGRES_USER=sub2api
TZ=Asia/Shanghai
EOF

    cat > docker-compose.yml <<EOF
services:
  sub2api:
    image: weishaw/sub2api:latest
    container_name: sub2api
    restart: unless-stopped
    ports:
      - "${APP_PORT}:8080"
    environment:
      - AUTO_SETUP=true
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=sub2api
      - DATABASE_PASSWORD=\${POSTGRES_PASSWORD}
      - DATABASE_DBNAME=sub2api
      - REDIS_HOST=redis
      - ADMIN_EMAIL=\${ADMIN_EMAIL}
      - ADMIN_PASSWORD=\${ADMIN_PASSWORD}
      - JWT_SECRET=\${JWT_SECRET}
      - TOTP_ENCRYPTION_KEY=\${TOTP_ENCRYPTION_KEY}
      - TZ=Asia/Shanghai
    volumes:
      - sub2api_data:/app/data
    depends_on:
      - postgres
      - redis
    networks:
      - sub2api-net

  postgres:
    image: postgres:16-alpine
    container_name: sub2api-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: sub2api
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: sub2api
      TZ: Asia/Shanghai
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - sub2api-net

  redis:
    image: redis:7-alpine
    container_name: sub2api-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - sub2api-net

volumes:
  sub2api_data:
  postgres_data:
  redis_data:

networks:
  sub2api-net:
    driver: bridge
EOF

    docker compose up -d 2>/dev/null || docker-compose up -d

    echo ""
    echo "安装完成"
    echo "访问地址: http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
    echo "管理员邮箱: admin@example.com"
    echo "管理员密码: $ADMIN_PASSWORD"
    echo "配置目录: $APP_DIR"
}

# ==============================
# 更新
# ==============================

update_app() {
    cd "$APP_DIR" || exit
    docker compose pull 2>/dev/null || docker-compose pull
    docker compose up -d 2>/dev/null || docker-compose up -d
    echo "更新完成"
}

# ==============================
# 卸载
# ==============================

uninstall_app() {
    cd "$APP_DIR" || exit
    docker compose down -v --rmi all 2>/dev/null || docker-compose down -v --rmi all
    rm -rf "$APP_DIR"
    echo "已完全卸载"
}



# ==============================
# 菜单
# ==============================

while true; do
    clear
    echo "================================="
    echo "        Sub2API 管理脚本"
    echo "================================="
    echo "1) 安装 Sub2API"
    echo "2) 更新 Sub2API"
    echo "3) 卸载 Sub2API"
    echo "0) 退出"
    echo "================================="
    read -p "请选择: " choice

    case $choice in
        1) install_app; pause ;;
        2) update_app; pause ;;
        3) uninstall_app; pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
    esac
done
