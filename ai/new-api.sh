#!/bin/bash

APP_DIR="/home/docker/new-api"
BACKUP_DIR="/home"
APP_PORT="8300"

APP_NAME="New API"
COMPOSE_PROJECT="new-api"

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
        docker compose -p "$COMPOSE_PROJECT" "$@"
    elif check_cmd docker-compose; then
        docker-compose -p "$COMPOSE_PROJECT" "$@"
    else
        echo "未检测到 Docker Compose"
        return 1
    fi
}

ensure_docker() {
    if check_cmd docker && docker info >/dev/null 2>&1; then
        return 0
    fi

    if check_cmd docker; then
        echo "检测到 Docker 客户端，但 Docker 服务未运行，正在尝试启动..."
        systemctl enable --now docker >/dev/null 2>&1 || true
        if docker info >/dev/null 2>&1; then
            return 0
        fi
    fi

    echo "未检测到可用 Docker，开始安装 Docker..."
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 用户运行，或先手动安装 Docker"
        return 1
    fi

    curl -fsSL https://get.docker.com | bash || return 1
    systemctl enable --now docker >/dev/null 2>&1 || true

    docker info >/dev/null 2>&1 || {
        echo "Docker 安装或启动失败，请手动检查"
        return 1
    }
}

is_installed() {
    [ -f "$APP_DIR/docker-compose.yml" ]
}

volume_exists() {
    docker volume inspect "$1" >/dev/null 2>&1
}

compose_project_name() {
    echo "$COMPOSE_PROJECT"
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
        pg_data)
            by_container=$(docker inspect new-api-postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
            ;;
        redis_data)
            by_container=$(docker inspect new-api-redis --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)
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
    find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'new-api-*.tar.gz' -o -name 'new-api--*.tar.gz' \) 2>/dev/null | sort -r
}

get_server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

show_status() {
    echo ""
    if ! is_installed; then
        echo "状态: 未安装"
        return 0
    fi

    if ! check_cmd docker; then
        echo "状态: 已有配置目录，但 Docker 未安装"
        return 0
    fi

    local app_status pg_status redis_status
    app_status=$(docker inspect -f '{{.State.Status}}' new-api 2>/dev/null || true)
    pg_status=$(docker inspect -f '{{.State.Status}}' new-api-postgres 2>/dev/null || true)
    redis_status=$(docker inspect -f '{{.State.Status}}' new-api-redis 2>/dev/null || true)

    echo "状态: 已安装"
    echo "主程序: ${app_status:-未创建}"
    echo "PostgreSQL: ${pg_status:-未创建}"
    echo "Redis: ${redis_status:-未创建}"
    echo "访问地址: http://$(get_server_ip):${APP_PORT}"
}

# ==============================
# 安装
# ==============================

install_app() {
    if ! ensure_docker; then
        return 1
    fi

    if is_installed; then
        echo "检测到已安装 $APP_NAME: $APP_DIR"
        read -p "是否拉取镜像并启动/更新现有服务？[Y/n]: " update_confirm
        case "$update_confirm" in
            n|N|no|NO) echo "已取消"; return 0 ;;
            *) update_app; return $? ;;
        esac
    fi

    mkdir -p "$APP_DIR/data" "$APP_DIR/logs"
    cd "$APP_DIR" || exit 1

    echo "正在生成配置..."

    POSTGRES_PASSWORD=$(openssl rand -hex 24)
    REDIS_PASSWORD=$(openssl rand -hex 24)
    SESSION_SECRET=$(openssl rand -hex 32)

    cat > .env <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
SESSION_SECRET=$SESSION_SECRET
TZ=Asia/Shanghai
APP_PORT=$APP_PORT
EOF

    cat > docker-compose.yml <<'EOF'
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: unless-stopped
    command: --log-dir /app/logs
    ports:
      - "${APP_PORT}:3000"
    environment:
      - SQL_DSN=postgresql://root:${POSTGRES_PASSWORD}@postgres:5432/new-api
      - REDIS_CONN_STRING=redis://:${REDIS_PASSWORD}@redis:6379
      - SESSION_SECRET=${SESSION_SECRET}
      - TZ=${TZ}
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - NODE_NAME=new-api-node-1
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    depends_on:
      - postgres
      - redis
    networks:
      - new-api-net
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":\\s*true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  postgres:
    image: postgres:15-alpine
    container_name: new-api-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: root
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: new-api
      TZ: ${TZ}
    volumes:
      - pg_data:/var/lib/postgresql/data
    networks:
      - new-api-net

  redis:
    image: redis:7-alpine
    container_name: new-api-redis
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - new-api-net

volumes:
  pg_data:
  redis_data:

networks:
  new-api-net:
    driver: bridge
EOF

    compose_cmd up -d || return 1

    echo ""
    echo "安装完成"
    echo "访问地址: http://$(get_server_ip):${APP_PORT}"
    echo "---------------------------------------------------------"
    echo "容器地址是3000"
    echo "---------------------------------------------------------"
    echo "首次打开网页后按向导创建管理员账号"
    echo "配置目录: $APP_DIR"
    echo "数据目录: $APP_DIR/data"
    echo "日志目录: $APP_DIR/logs"
}

# ==============================
# 更新
# ==============================

update_app() {
    if ! ensure_docker; then
        return 1
    fi

    if ! is_installed; then
        echo "未检测到 $APP_NAME 安装目录: $APP_DIR"
        return 1
    fi

    cd "$APP_DIR" || exit 1
    compose_cmd pull || return 1
    compose_cmd up -d || return 1
    echo "更新完成"
    echo "访问地址: http://$(get_server_ip):${APP_PORT}"
}

# ==============================
# 启停/日志
# ==============================

start_app() {
    if ! ensure_docker; then
        return 1
    fi
    if ! is_installed; then
        echo "未检测到 $APP_NAME 安装目录: $APP_DIR"
        return 1
    fi
    cd "$APP_DIR" || exit 1
    compose_cmd up -d
}

stop_app() {
    if ! is_installed; then
        echo "未检测到 $APP_NAME 安装目录: $APP_DIR"
        return 1
    fi
    cd "$APP_DIR" || exit 1
    compose_cmd down
}

restart_app() {
    stop_app && start_app
}

show_logs() {
    if ! is_installed; then
        echo "未检测到 $APP_NAME 安装目录: $APP_DIR"
        return 1
    fi
    cd "$APP_DIR" || exit 1
    compose_cmd logs --tail=200 new-api
}

# ==============================
# 卸载
# ==============================

uninstall_app() {
    if ! is_installed; then
        echo "未检测到 $APP_NAME 安装目录: $APP_DIR"
        return 1
    fi

    echo "将完全卸载 $APP_NAME，并删除容器、镜像、数据卷和配置目录。"
    echo "配置目录: $APP_DIR"
    read -p "确认卸载？请输入 yes 继续: " confirm
    if [ "$confirm" != "yes" ]; then
        echo "已取消卸载"
        return 0
    fi

    cd "$APP_DIR" || exit 1
    compose_cmd down -v --rmi all || return 1
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
        echo "未检测到 $APP_NAME 安装目录: $APP_DIR"
        return 1
    fi

    local timestamp backup_file tmp_dir backup_status was_running
    timestamp=$(date +%Y%m%d%H%M%S)
    backup_file="$BACKUP_DIR/new-api-${timestamp}.tar.gz"
    tmp_dir=$(mktemp -d)
    backup_status=0
    was_running=0

    if docker inspect -f '{{.State.Running}}' new-api 2>/dev/null | grep -q true; then
        was_running=1
    fi

    echo "正在备份 $APP_NAME..."
    echo "备份文件: $backup_file"
    echo "备份流程: 停止 $APP_NAME → 备份配置、绑定目录和数据卷 → 按原状态启动 $APP_NAME"

    echo "正在停止 $APP_NAME..."
    cd "$APP_DIR" || {
        rm -rf "$tmp_dir"
        return 1
    }
    compose_cmd down || {
        rm -rf "$tmp_dir"
        echo "停止 $APP_NAME 失败，已取消备份"
        return 1
    }

    mkdir -p "$tmp_dir/app" "$tmp_dir/volumes"

    echo "正在备份配置和绑定目录..."
    tar czf "$tmp_dir/app/app.tar.gz" -C "$(dirname "$APP_DIR")" "$(basename "$APP_DIR")" || {
        echo "配置目录备份失败"
        backup_status=1
    }

    if [ "$backup_status" -eq 0 ]; then
        local logical_volume actual_volume
        for logical_volume in pg_data redis_data; do
            if ! actual_volume=$(find_volume_name "$logical_volume"); then
                if [ "$logical_volume" = "pg_data" ]; then
                    echo "错误：未找到关键 Docker 卷: $logical_volume"
                    echo "为避免生成无法恢复用户、渠道、令牌、用量数据的坏备份，本次备份已中止。"
                    backup_status=1
                    break
                fi
                echo "跳过不存在的 Docker 卷: $logical_volume"
                continue
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

    if [ "$was_running" -eq 1 ]; then
        echo "正在启动 $APP_NAME..."
        cd "$APP_DIR" && compose_cmd up -d || {
            echo "警告：备份后启动 $APP_NAME 失败，请手动检查: $APP_DIR"
            [ "$backup_status" -eq 0 ] && backup_status=1
        }
    else
        echo "备份前 $APP_NAME 未运行，备份后保持停止状态。"
    fi

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

    local backups latest backup_file index selected tmp_dir volume_file old_dir
    mapfile -t backups < <(backup_files)

    if [ "${#backups[@]}" -eq 0 ]; then
        echo "未在 $BACKUP_DIR 找到备份文件: new-api-*.tar.gz"
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
    read -p "恢复会覆盖当前 $APP_NAME 数据，确认继续？[y/N]: " confirm
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

    if [ ! -f "$tmp_dir/volumes/pg_data.tar.gz" ]; then
        echo "错误：备份中缺少 PostgreSQL 数据卷: volumes/pg_data.tar.gz"
        echo "这个备份不包含用户、渠道、令牌、用量等核心数据库数据，已中止恢复。"
        echo "请换一个包含 volumes/pg_data.tar.gz 的备份文件。"
        rm -rf "$tmp_dir"
        return 1
    fi

    if is_installed; then
        echo "正在停止当前 $APP_NAME..."
        cd "$APP_DIR" || {
            rm -rf "$tmp_dir"
            return 1
        }
        compose_cmd down || {
            rm -rf "$tmp_dir"
            return 1
        }
    else
        echo "未检测到当前 $APP_NAME 安装，将直接从备份恢复配置和数据。"
    fi

    echo "正在恢复配置目录..."
    old_dir="${APP_DIR}.before_restore_$(date +%Y%m%d%H%M%S)"
    if [ -d "$APP_DIR" ]; then
        mv "$APP_DIR" "$old_dir" || {
            rm -rf "$tmp_dir"
            echo "移动当前配置目录失败"
            return 1
        }
    fi

    mkdir -p "$(dirname "$APP_DIR")"
    tar xzf "$tmp_dir/app/app.tar.gz" -C "$(dirname "$APP_DIR")" || {
        echo "恢复配置目录失败"
        rm -rf "$APP_DIR"
        if [ -n "$old_dir" ] && [ -d "$old_dir" ]; then
            mv "$old_dir" "$APP_DIR" 2>/dev/null || true
        fi
        rm -rf "$tmp_dir"
        return 1
    }

    local logical_volume actual_volume legacy_volume_file
    for logical_volume in pg_data redis_data; do
        volume_file="$tmp_dir/volumes/${logical_volume}.tar.gz"
        actual_volume=$(resolve_volume_name "$logical_volume")

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

    echo "正在启动 $APP_NAME..."
    cd "$APP_DIR" || return 1
    compose_cmd up -d || return 1

    echo "恢复完成"
    if [ -n "$old_dir" ] && [ -d "$old_dir" ]; then
        echo "恢复前目录已保留: $old_dir"
    fi
    echo "访问地址: http://$(get_server_ip):${APP_PORT}"
}

# ==============================
# 菜单
# ==============================

while true; do
    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear
    fi
    echo "=================================="
    echo "        New API 管理脚本"
    echo "开源 AI 模型聚合与分发平台，支持多渠道接入、令牌管理与计费"
    echo "部署组件：New API + PostgreSQL + Redis"
    echo "开源地址："
    echo "https://github.com/QuantumNous/new-api"
    echo "=================================="
    echo
    echo "------------------------"
    echo "默认访问端口：${APP_PORT}，容器内部端口：3000"
    echo "首次打开网页后按向导创建管理员账号"
    show_status
    echo "------------------------"
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份（home目录）"
    echo "4. 恢复（从home/目录获取）"
    echo "5. 启动"
    echo "6. 停止"
    echo "7. 重启"
    echo "8. 查看日志"
    echo "9. 卸载"
    echo "0. 退出"
    echo
    read -r -p "请输入选项: " choice || { echo "已退出"; exit 0; }

    case $choice in
        1) install_app; pause ;;
        2) update_app; pause ;;
        3) backup_app; pause ;;
        4) restore_app; pause ;;
        5) start_app; pause ;;
        6) stop_app; pause ;;
        7) restart_app; pause ;;
        8) show_logs; pause ;;
        9) uninstall_app; pause ;;
        0) echo "已退出"; exit 0 ;;
        *) echo "无效选项"; pause ;;
    esac
done
