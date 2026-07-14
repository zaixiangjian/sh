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

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif check_cmd docker-compose; then
        docker-compose "$@"
    else
        echo "未检测到 Docker Compose"
        return 1
    fi
}

ensure_docker() {
    if check_cmd docker; then
        return 0
    fi

    echo "未检测到 Docker，开始安装 Docker..."
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 用户运行，或先手动安装 Docker"
        return 1
    fi

    curl -fsSL https://get.docker.com | bash || return 1
    systemctl enable --now docker >/dev/null 2>&1 || true
}

is_installed() {
    [ -f "$APP_DIR/docker-compose.yml" ]
}

volume_exists() {
    docker volume inspect "$1" >/dev/null 2>&1
}

compose_project_name() {
    basename "$APP_DIR"
}

find_volume_name() {
    local logical_name project_name prefixed_name by_container
    logical_name="$1"
    project_name=$(compose_project_name)
    prefixed_name="${project_name}_${logical_name}"

    if volume_exists "$prefixed_name"; then
        echo "$prefixed_name"
        return 0
    fi

    if volume_exists "$logical_name"; then
        echo "$logical_name"
        return 0
    fi

    case "$logical_name" in
        sub2api_data)
            by_container=$(docker inspect sub2api --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
        postgres_data)
            by_container=$(docker inspect sub2api-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
        redis_data)
            by_container=$(docker inspect sub2api-redis --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
    esac

    if [ -n "$by_container" ] && volume_exists "$by_container"; then
        echo "$by_container"
        return 0
    fi

    return 1
}

resolve_volume_name() {
    local logical_name project_name prefixed_name
    logical_name="$1"
    project_name=$(compose_project_name)
    prefixed_name="${project_name}_${logical_name}"

    find_volume_name "$logical_name" || echo "$prefixed_name"
}

backup_files() {
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'sub2api-*.tar.gz' -o -name 'sub2api--*.tar.gz' \) 2>/dev/null | sort -r
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
    echo "---------------------------------------------------------"
    echo "容器地址是8080"
    echo "---------------------------------------------------------"
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
# 备份
# ==============================

backup_app() {
    if ! ensure_docker; then
        echo "Docker 环境异常，无法备份"
        return 1
    fi

    if ! is_installed; then
        echo "未检测到 Sub2API 安装目录: $APP_DIR"
        return 1
    fi

    local timestamp backup_file tmp_dir backup_status
    timestamp=$(date +%Y%m%d%H%M%S)
    backup_file="$BACKUP_DIR/sub2api-${timestamp}.tar.gz"
    tmp_dir=$(mktemp -d)
    backup_status=0

    echo "正在备份 Sub2API..."
    echo "备份文件: $backup_file"
    echo "备份流程: 停止 Sub2API → 备份配置和数据卷 → 启动 Sub2API"

    echo "正在停止 Sub2API..."
    cd "$APP_DIR" || {
        rm -rf "$tmp_dir"
        return 1
    }
    compose_cmd down || {
        rm -rf "$tmp_dir"
        echo "停止 Sub2API 失败，已取消备份"
        return 1
    }

    mkdir -p "$tmp_dir/app" "$tmp_dir/volumes"

    echo "正在备份配置目录..."
    tar czf "$tmp_dir/app/app.tar.gz" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" || {
        echo "配置目录备份失败"
        backup_status=1
    }

    if [ "$backup_status" -eq 0 ]; then
        local logical_volume actual_volume
        for logical_volume in sub2api_data postgres_data redis_data; do
            if ! actual_volume=$(find_volume_name "$logical_volume"); then
                echo "错误：未找到关键 Docker 卷: $logical_volume"
                echo "为避免生成无法恢复用户/API/数据库的坏备份，本次备份已中止。"
                backup_status=1
                break
            fi

            echo "正在备份 Docker 卷: $actual_volume -> $logical_volume"
            docker run --rm \
                -v "$actual_volume:/volume:ro" \
                -v "$tmp_dir/volumes:/backup" \
                alpine sh -c "cd /volume && tar czf /backup/${logical_volume}.tar.gz ." || {
                    echo "Docker 卷备份失败: $actual_volume"
                    backup_status=1
                    break
                }
        done
    fi

    if [ "$backup_status" -eq 0 ]; then
        tar czf "$backup_file" -C "$tmp_dir" . || {
            echo "打包备份失败"
            backup_status=1
        }
    fi

    rm -rf "$tmp_dir"

    echo "正在启动 Sub2API..."
    cd "$APP_DIR" && compose_cmd up -d || {
        echo "警告：备份后启动 Sub2API 失败，请手动检查: $APP_DIR"
        [ "$backup_status" -eq 0 ] && backup_status=1
    }

    if [ "$backup_status" -eq 0 ]; then
        echo "备份完成: $backup_file"
        return 0
    fi

    echo "备份失败"
    return 1
}

# ==============================
# 恢复
# ==============================

restore_app() {
    if ! ensure_docker; then
        echo "Docker 环境异常，无法恢复"
        return 1
    fi

    local backups latest backup_file index selected tmp_dir volume_file
    mapfile -t backups < <(backup_files)

    if [ "${#backups[@]}" -eq 0 ]; then
        echo "未在 $BACKUP_DIR 找到备份文件: sub2api-*.tar.gz"
        return 1
    fi

    latest="${backups[0]}"

    echo "检测到以下备份文件："
    index=1
    for backup_file in "${backups[@]}"; do
        echo "$index) $(basename "$backup_file")"
        index=$((index + 1))
    done

    echo ""
    read -p "请选择要恢复的备份编号，直接回车恢复最新备份 [$(basename "$latest")]: " selected

    if [ -z "$selected" ]; then
        backup_file="$latest"
    elif [[ "$selected" =~ ^[0-9]+$ ]] && [ "$selected" -ge 1 ] && [ "$selected" -le "${#backups[@]}" ]; then
        backup_file="${backups[$((selected - 1))]}"
    else
        echo "无效选择"
        return 1
    fi

    echo "将恢复备份: $backup_file"
    read -p "恢复会覆盖当前 Sub2API 数据，确认继续？[y/N]: " confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) echo "已取消恢复"; return 0 ;;
    esac

    tmp_dir=$(mktemp -d)
    tar xzf "$backup_file" -C "$tmp_dir" || {
        rm -rf "$tmp_dir"
        echo "解压备份失败"
        return 1
    }

    if [ ! -f "$tmp_dir/app/app.tar.gz" ]; then
        echo "备份中缺少配置目录: app/app.tar.gz"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "$tmp_dir/volumes/postgres_data.tar.gz" ]; then
        echo "错误：备份中缺少 PostgreSQL 数据卷: volumes/postgres_data.tar.gz"
        echo "这个备份不包含用户、API Key、上游账号等核心数据库数据，已中止恢复。"
        echo "请换一个包含 volumes/postgres_data.tar.gz 的备份文件。"
        rm -rf "$tmp_dir"
        return 1
    fi

    if is_installed; then
        echo "正在停止当前 Sub2API..."
        cd "$APP_DIR" || {
            rm -rf "$tmp_dir"
            return 1
        }
        compose_cmd down || {
            rm -rf "$tmp_dir"
            return 1
        }
    else
        echo "未检测到当前 Sub2API 安装，将直接从备份恢复配置和数据。"
    fi

    echo "正在恢复配置目录..."
    rm -rf "$APP_DIR"
    mkdir -p "$(dirname "$APP_DIR")"
    tar xzf "$tmp_dir/app/app.tar.gz" -C "$(dirname "$APP_DIR")" || {
        rm -rf "$tmp_dir"
        echo "恢复配置目录失败"
        return 1
    }

    local logical_volume actual_volume legacy_volume_file
    for logical_volume in sub2api_data postgres_data redis_data; do
        volume_file="$tmp_dir/volumes/${logical_volume}.tar.gz"
        actual_volume=$(resolve_volume_name "$logical_volume")

        # 兼容旧备份：如果旧脚本曾把真实卷名打进文件名，也尝试读取真实卷名文件
        if [ ! -f "$volume_file" ]; then
            legacy_volume_file="$tmp_dir/volumes/${actual_volume}.tar.gz"
            [ -f "$legacy_volume_file" ] && volume_file="$legacy_volume_file"
        fi

        if [ -f "$volume_file" ]; then
            echo "正在恢复 Docker 卷: $logical_volume -> $actual_volume"
            docker volume rm "$actual_volume" >/dev/null 2>&1 || true
            docker volume create \
                --label "com.docker.compose.project=$(compose_project_name)" \
                --label "com.docker.compose.volume=$logical_volume" \
                "$actual_volume" >/dev/null || {
                rm -rf "$tmp_dir"
                echo "创建 Docker 卷失败: $actual_volume"
                return 1
            }
            docker run --rm \
                -v "$actual_volume:/volume" \
                -v "$(dirname "$volume_file"):/backup" \
                alpine sh -c "cd /volume && tar xzf /backup/$(basename "$volume_file")" || {
                    rm -rf "$tmp_dir"
                    echo "恢复 Docker 卷失败: $actual_volume"
                    return 1
                }
        else
            echo "跳过备份中不存在的 Docker 卷: $logical_volume"
        fi
    done

    rm -rf "$tmp_dir"

    echo "正在启动 Sub2API..."
    cd "$APP_DIR" || return 1
    compose_cmd up -d || return 1

    echo "恢复完成"
    echo "访问地址: http://$(hostname -I | awk '{print $1}'):${APP_PORT}"
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
    echo "11) 备份 Sub2API"
    echo "12) 恢复 Sub2API"
    echo "0) 退出"
    echo "================================="
    read -p "请选择: " choice

    case $choice in
        1) install_app; pause ;;
        2) update_app; pause ;;
        3) uninstall_app; pause ;;
        11) backup_app; pause ;;
        12) restore_app; pause ;;
        0) exit 0 ;;
        *) echo "无效选项"; pause ;;
    esac
done
