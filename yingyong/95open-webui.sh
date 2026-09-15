#!/usr/bin/env bash
set -o pipefail

# Open WebUI 本地管理脚本
# 路径: /root/open-webui.sh

APP_NAME="open-webui"
IMAGE="ghcr.io/open-webui/open-webui:main"
HOST_PORT="3000"
CONTAINER_PORT="8080"
BASE_DIR="/home/docker/open-webui"
DATA_DIR="${BASE_DIR}/data"
ENV_FILE="${BASE_DIR}/open-webui.env"
BACKUP_DIR="/home"

red='\033[31m'
green='\033[32m'
yellow='\033[33m'
blue='\033[36m'
plain='\033[0m'

pause() {
    read -r -p "按回车键继续..." _
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${red}请使用 root 用户运行。${plain}"
        exit 1
    fi
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

get_ip() {
    curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || \
    curl -4 -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
    hostname -I 2>/dev/null | awk '{print $1}'
}

install_docker() {
    if cmd_exists docker; then
        echo -e "${green}Docker 已安装：$(docker --version 2>/dev/null)${plain}"
        return 0
    fi

    echo -e "${yellow}未检测到 Docker，开始自动安装 Docker...${plain}"

    if cmd_exists apt-get; then
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release
        curl -fsSL https://get.docker.com | sh
    elif cmd_exists dnf; then
        dnf install -y curl
        curl -fsSL https://get.docker.com | sh
    elif cmd_exists yum; then
        yum install -y curl
        curl -fsSL https://get.docker.com | sh
    elif cmd_exists apk; then
        apk add --no-cache docker docker-cli-compose curl
        rc-update add docker boot >/dev/null 2>&1 || true
        service docker start >/dev/null 2>&1 || true
    else
        echo -e "${red}未识别的软件包管理器，请先手动安装 Docker。${plain}"
        return 1
    fi

    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true

    if ! cmd_exists docker; then
        echo -e "${red}Docker 安装失败，请手动安装后重试。${plain}"
        return 1
    fi

    echo -e "${green}Docker 安装完成：$(docker --version 2>/dev/null)${plain}"
}

container_exists() {
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$APP_NAME"
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$APP_NAME"
}

is_installed() {
    container_exists || [ -d "$DATA_DIR" ] || [ -f "$ENV_FILE" ]
}

ensure_dirs() {
    mkdir -p "$DATA_DIR"
}

quote_env_value() {
    # env-file 支持 KEY=value；这里去掉换行，避免写坏配置。
    printf '%s' "$1" | tr -d '\r\n'
}

write_default_env_if_missing() {
    ensure_dirs
    if [ ! -f "$ENV_FILE" ]; then
        local ip
        ip=$(get_ip)
        cat > "$ENV_FILE" <<EOF
# Open WebUI 配置文件，由 /root/open-webui.sh 管理
# Open WebUI 默认配置
WEBUI_URL=http://${ip:-127.0.0.1}:${HOST_PORT}
FRONTEND_URL=http://${ip:-127.0.0.1}:${HOST_PORT}
ENABLE_SIGNUP=true
ENABLE_LOGIN_FORM=true
ENABLE_PASSWORD_AUTH=true
ENABLE_MAIL=False
MAIL_SERVER=
MAIL_PORT=587
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_FROM=
MAIL_FROM_NAME=Open WebUI
MAIL_STARTTLS=True
MAIL_SSL_TLS=False
EOF
    fi
}

read_env_value() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2-
}

set_env_value() {
    local key="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp)
    touch "$ENV_FILE"
    if grep -qE "^${key}=" "$ENV_FILE"; then
        awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(done==0) print k "=" v}' "$ENV_FILE" > "$tmp"
    else
        cp "$ENV_FILE" "$tmp"
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

run_container() {
    ensure_dirs
    write_default_env_if_missing

    docker rm -f "$APP_NAME" >/dev/null 2>&1 || true

    docker run -d \
        --name "$APP_NAME" \
        --restart always \
        -p "${HOST_PORT}:${CONTAINER_PORT}" \
        --env-file "$ENV_FILE" \
        -v "${DATA_DIR}:/app/backend/data" \
        "$IMAGE"
}

install_app() {
    clear
    echo "▶️ 安装 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }
    ensure_dirs
    write_default_env_if_missing

    # 默认安装明确关闭邮件，避免沿用旧 SMTP 配置。
    set_env_value ENABLE_MAIL "False"
    set_env_value MAIL_SERVER ""
    set_env_value MAIL_USERNAME ""
    set_env_value MAIL_PASSWORD ""
    set_env_value MAIL_FROM ""

    if container_exists; then
        echo -e "${yellow}检测到 open-webui 容器已存在，将按当前配置重建容器，数据目录保留：${DATA_DIR}${plain}"
    fi

    echo -e "${yellow}正在拉取镜像：${IMAGE}${plain}"
    docker pull "$IMAGE" || { echo -e "${red}镜像拉取失败。${plain}"; pause; return 1; }

    if run_container; then
        local ip url
        ip=$(get_ip)
        url=$(read_env_value WEBUI_URL)
        echo -e "${green}Open WebUI 安装完成。${plain}"
        echo -e "访问地址：${green}${url:-http://${ip:-服务器IP}:${HOST_PORT}}${plain}"
        echo "数据目录：${DATA_DIR}"
        echo "配置文件：${ENV_FILE}"
        echo "首次进入需要创建管理员账号。"
    else
        echo -e "${red}Open WebUI 启动失败，请查看日志：docker logs open-webui${plain}"
    fi
    pause
}

update_app() {
    clear
    echo "▶️ 更新 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }
    write_default_env_if_missing

    echo -e "${yellow}正在拉取最新镜像...${plain}"
    docker pull "$IMAGE" || { echo -e "${red}镜像拉取失败。${plain}"; pause; return 1; }

    if run_container; then
        echo -e "${green}Open WebUI 已更新并重启。${plain}"
    else
        echo -e "${red}更新后启动失败，请查看日志：docker logs open-webui${plain}"
    fi
    pause
}

restart_app() {
    clear
    echo "▶️ 重启 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }
    write_default_env_if_missing

    if container_exists; then
        if run_container; then
            echo -e "${green}Open WebUI 已按当前配置重启。${plain}"
        else
            echo -e "${red}重启失败，请查看日志：docker logs open-webui${plain}"
        fi
    else
        echo -e "${yellow}Open WebUI 未安装，开始安装...${plain}"
        docker pull "$IMAGE" && run_container
    fi
    pause
}

backup_app() {
    clear
    echo "▶️ 备份 Open WebUI"
    echo -e "${green}================================${plain}"

    if [ ! -d "$BASE_DIR" ]; then
        echo -e "${yellow}未找到数据目录：${BASE_DIR}${plain}"
        pause
        return 1
    fi

    install_docker || { pause; return 1; }

    local was_running="no"
    if container_running; then
        was_running="yes"
        echo -e "${yellow}检测到 Open WebUI 正在运行，先停止以确保备份一致...${plain}"
        docker stop "$APP_NAME" >/dev/null || { echo -e "${red}停止容器失败，取消备份。${plain}"; pause; return 1; }
    fi

    local ts backup_file
    ts=$(date '+%Y%m%d-%H%M%S')
    backup_file="${BACKUP_DIR}/open-webui-${ts}.tar.gz"

    echo -e "${yellow}正在备份到：${backup_file}${plain}"
    if tar -czf "$backup_file" -C "/home/docker" "open-webui"; then
        echo -e "${green}备份完成：${backup_file}${plain}"
    else
        echo -e "${red}备份失败。${plain}"
        [ "$was_running" = "yes" ] && docker start "$APP_NAME" >/dev/null 2>&1 || true
        pause
        return 1
    fi

    if [ "$was_running" = "yes" ]; then
        echo -e "${yellow}恢复启动 Open WebUI...${plain}"
        docker start "$APP_NAME" >/dev/null 2>&1 || run_container >/dev/null 2>&1 || true
    fi

    pause
}

list_backups() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'open-webui-[0-9]*.tar.gz' -printf '%T@ %f\n' 2>/dev/null | sort -nr
}

restore_app() {
    clear
    echo "▶️ 恢复 Open WebUI"
    echo -e "${green}================================${plain}"

    install_docker || { pause; return 1; }

    mapfile -t backups < <(list_backups | awk '{print $2}')
    if [ "${#backups[@]}" -eq 0 ]; then
        echo -e "${yellow}/home 下未找到 open-webui-时间.tar.gz 备份文件。${plain}"
        pause
        return 1
    fi

    local i
    for i in "${!backups[@]}"; do
        echo "$((i+1)).${backups[$i]}"
    done
    echo "------------------------"
    echo "0. 返回上一级"
    echo

    read -r -p "请输入你的选择（回车默认恢复最新）: " choice
    choice=${choice:-1}
    if [ "$choice" = "0" ]; then
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        echo -e "${red}输入无效。${plain}"
        pause
        return 1
    fi

    local selected="${BACKUP_DIR}/${backups[$((choice-1))]}"
    echo -e "${yellow}将恢复备份：${selected}${plain}"
    read -r -p "确认恢复？当前 /home/docker/open-webui 会先移动为 .before_restore 备份 (Y/N): " confirm
    case "$confirm" in
        Y|y) ;;
        *) echo "已取消。"; pause; return 0 ;;
    esac

    local was_installed="no"
    is_installed && was_installed="yes"

    if container_exists; then
        echo -e "${yellow}停止并删除现有容器...${plain}"
        docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    fi

    # 没安装时先准备 Docker 和基础目录；恢复包会覆盖数据。
    mkdir -p "/home/docker"

    local move_path=""
    if [ -e "$BASE_DIR" ]; then
        move_path="${BASE_DIR}.before_restore_$(date '+%Y%m%d-%H%M%S')"
        mv "$BASE_DIR" "$move_path" || { echo -e "${red}移动当前目录失败，取消恢复。${plain}"; pause; return 1; }
        echo "当前目录已保存为：${move_path}"
    fi

    if tar -xzf "$selected" -C "/home/docker"; then
        if [ ! -d "$BASE_DIR" ]; then
            echo -e "${red}备份结构不正确，未包含 open-webui 目录。${plain}"
            rm -rf "$BASE_DIR"
            [ -n "$move_path" ] && mv "$move_path" "$BASE_DIR"
            pause
            return 1
        fi
        write_default_env_if_missing
        echo -e "${green}恢复完成。${plain}"
    else
        echo -e "${red}解压失败，尝试回滚。${plain}"
        rm -rf "$BASE_DIR"
        [ -n "$move_path" ] && mv "$move_path" "$BASE_DIR"
        pause
        return 1
    fi

    echo -e "${yellow}启动 Open WebUI...${plain}"
    docker pull "$IMAGE" >/dev/null 2>&1 || true
    if run_container; then
        echo -e "${green}Open WebUI 已恢复并启动。${plain}"
        [ "$was_installed" = "no" ] && echo -e "${green}原本未安装，已自动完成容器安装。${plain}"
    else
        echo -e "${red}恢复后启动失败，请查看日志：docker logs open-webui${plain}"
    fi

    pause
}

uninstall_app() {
    clear
    echo "▶️ 卸载 Open WebUI"
    echo -e "${green}================================${plain}"
    echo -e "${red}注意：此操作会删除容器。是否删除数据目录可单独选择。${plain}"
    read -r -p "确认卸载 Open WebUI 容器？(Y/N): " confirm
    case "$confirm" in
        Y|y) ;;
        *) echo "已取消。"; pause; return 0 ;;
    esac

    if cmd_exists docker; then
        docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    fi
    echo -e "${green}容器已删除。${plain}"

    if [ -d "$BASE_DIR" ]; then
        read -r -p "是否同时删除数据目录 ${BASE_DIR}？此操作不可恢复 (Y/N): " del_data
        case "$del_data" in
            Y|y)
                rm -rf "$BASE_DIR"
                echo -e "${green}数据目录已删除。${plain}"
                ;;
            *)
                echo "数据目录已保留：${BASE_DIR}"
                ;;
        esac
    fi
    pause
}

show_menu() {
    clear
    if is_installed; then
        if container_running; then
            echo -e "${green}open-webui 已安装（运行中）${plain}"
        else
            echo -e "${yellow}open-webui 已安装（未运行）${plain}"
        fi
    else
        echo "open-webui 未安装"
    fi
    echo "一个类似ChatGPT的AI网页界面，支持多模型接入和API管理。"
    echo "官网: https://github.com/open-webui/open-webui"
    echo
    echo "------------------------"
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份"
    echo "4. 恢复"
    echo "9. 卸载"
    echo "------------------------"
    echo "0. 返回上一级"
    echo "------------------------"
}

main() {
    need_root
    while true; do
        show_menu
        read -r -p "请输入你的选择: " choice
        case "$choice" in
            1) install_app ;;
            2) update_app ;;
            3) backup_app ;;
            4) restore_app ;;
            9) uninstall_app ;;
            0) exit 0 ;;
            *) echo -e "${red}无效输入。${plain}"; sleep 1 ;;
        esac
    done
}

main "$@"
