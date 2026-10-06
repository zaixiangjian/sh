#!/bin/bash

set -e

APP_NAME="CLIProxyAPI"
APP_DIR="/home/docker/CLIProxyAPI"
BACKUP_DIR="/home"
PORT="8317"

install_app() {

    echo
    echo "开始安装 ${APP_NAME}"
    echo

    mkdir -p "$APP_DIR"

    cd "$APP_DIR"

    if [ ! -f docker-compose.yml ]; then
        git clone https://github.com/router-for-me/CLIProxyAPI.git .
    fi

    cp -n config.example.yaml config.yaml
    cp -n .env.example .env

    read -s -p "请输入管理密钥: " KEY
    echo

    sed -i -E '
    s/^(\s*)allow-remote:\s*false\s*$/\1allow-remote: true/
    s/^(\s*)secret-key:\s*""\s*$/\1secret-key: "'"$KEY"'"/
    ' config.yaml

    docker compose up -d

    echo
    echo "=================================="
    echo "安装完成"
    echo "WebUI:"
    echo "http://你的IP:${PORT}/management.html"
    echo "=================================="
    echo
}

update_app() {

    echo
    echo "更新 ${APP_NAME}"
    echo

    if [ ! -d "$APP_DIR" ]; then
        echo "未安装"
        return
    fi

    cd "$APP_DIR"

    docker compose down || true

    git pull

    docker compose pull

    docker compose up -d

    echo
    echo "更新完成"
    echo
}

backup_app() {

    echo

    if [ ! -d "$APP_DIR" ]; then
        echo "未安装"
        return
    fi

    BACKUP_FILE="${BACKUP_DIR}/CPA-$(date +%Y%m%d%H%M%S).tar.gz"
    WAS_RUNNING="no"

    echo "开始备份..."
    echo "为保证文件一致性，将先停止容器再备份。"
    echo

    if [ -f "$APP_DIR/docker-compose.yml" ]; then
        if docker inspect -f '{{.State.Running}}' cli-proxy-api 2>/dev/null | grep -q true; then
            WAS_RUNNING="yes"
        fi

        echo "停止容器..."
        cd "$APP_DIR"
        docker compose down || true
        sleep 2
    fi

    tar -czf "$BACKUP_FILE" -C /home/docker CLIProxyAPI
    TAR_STATUS=$?

    if [ "$WAS_RUNNING" = "yes" ] && [ -f "$APP_DIR/docker-compose.yml" ]; then
        echo "启动容器..."
        cd "$APP_DIR"
        docker compose up -d
    fi

    if [ $TAR_STATUS -ne 0 ]; then
        echo "备份失败"
        return 1
    fi

    echo "备份完成:"
    echo "$BACKUP_FILE"
    echo
}

restore_app() {

    local backups selected index FILE
    mapfile -t backups < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'CPA-*.tar.gz' -printf '%f\n' 2>/dev/null | LC_ALL=C sort -r
    )

    if [ "${#backups[@]}" -eq 0 ]; then
        echo "未在 $BACKUP_DIR 找到备份文件: CPA-*.tar.gz"
        return 0
    fi

    echo
    echo "检测到以下备份文件："
    for index in "${!backups[@]}"; do
        echo "$((index + 1)). ${backups[$index]}"
    done
    echo

    IFS= read -r -p "请选择要恢复的备份编号（回车恢复最新备份，0取消）: " selected || { echo "已取消恢复"; return 0; }
    if [ "$selected" = "0" ]; then
        echo "已取消恢复"
        return 0
    fi
    selected="${selected:-1}"
    local backup_count="${#backups[@]}"
    if ! [[ "$selected" =~ ^[1-9][0-9]*$ ]] || [ "${#selected}" -gt "${#backup_count}" ] || [ "$selected" -gt "$backup_count" ]; then
        echo "无效备份编号"
        return 0
    fi
    FILE="${BACKUP_DIR}/${backups[$((selected - 1))]}"

    if [ ! -f "$FILE" ]; then
        echo "备份文件不存在"
        return 0
    fi

    local confirm
    echo "备份文件: $FILE"
    echo "恢复目标: $APP_DIR"
    echo "恢复会替换当前配置、认证数据及安装目录，并重新启动容器。"
    IFS= read -r -p "确认恢复请输入 yes（其他输入取消）: " confirm || { echo "已取消恢复"; return 0; }
    if [ "$confirm" != "yes" ]; then
        echo "已取消恢复"
        return 0
    fi

    echo
    echo "开始恢复:"
    echo "$FILE"
    echo

    # 如果已安装
    if [ -d "$APP_DIR" ]; then

        echo "检测到已安装"

        cd "$APP_DIR"

        echo "停止容器..."

        docker compose down || true

        echo "删除旧目录..."

        rm -rf "$APP_DIR"
    fi

    echo
    echo "恢复备份文件..."
    echo

    mkdir -p /home/docker

    tar -xzf "$FILE" -C /home/docker

    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        echo "恢复失败"
        return
    fi

    echo "启动容器..."

    cd "$APP_DIR"

    docker compose up -d

    echo
    echo "=================================="
    echo "恢复完成"
    echo "WebUI:"
    echo "http://你的IP:${PORT}/management.html"
    echo "=================================="
    echo
}

uninstall_app() {
    local confirm
    echo "⚠️ 卸载将删除 ${APP_NAME} 容器、镜像、数据卷及安装目录，配置和认证数据将丢失。"
    IFS= read -r -p "确认卸载请输入 yes（其他输入取消）: " confirm || return 0
    if [ "$confirm" != "yes" ]; then
        echo "已取消卸载"
        return 0
    fi

    echo
    echo "卸载 ${APP_NAME}"
    echo

    if [ ! -d "$APP_DIR" ]; then
        echo "未安装"
        return
    fi

    cd "$APP_DIR"

    docker compose down --rmi all --volumes || true

    cd /home/docker

    rm -rf "$APP_DIR"

    echo
    echo "已删除:"
    echo "- 容器"
    echo "- 网络"
    echo "- 卷"
    echo "- ${APP_DIR}"
    echo
}


show_menu() {

    if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "$TERM" != "dumb" ]; then
        clear
    fi

    echo "=================================="
    echo "        CLIProxyAPI 管理脚本"
    echo "开源 AI API 代理，将 CLI 账号接入 OpenAI、Gemini、Claude 兼容接口"
    echo "部署组件：CLIProxyAPI（Docker）"
    echo "开源地址："
    echo "https://github.com/router-for-me/CLIProxyAPI"
    echo "=================================="
    echo
    echo "------------------------"
    echo "默认访问端口：${PORT}"
    echo "管理页面：http://你的IP:${PORT}/management.html"
    echo "------------------------"
    echo "1. 安装"
    echo "2. 更新"
    echo "3. 备份（home目录）"
    echo "4. 恢复（从home/目录获取）"
    echo "9. 卸载"
    echo "0. 退出"
    echo
}

while true; do

    show_menu

    read -r -p "请输入选项: " CHOICE || { echo "已退出"; exit 0; }

    case $CHOICE in

        1)
            install_app
            ;;

        2)
            update_app
            ;;

        3)
            backup_app
            ;;

        4)
            restore_app
            ;;

        9)
            uninstall_app
            ;;

        0)
            echo
            echo "已退出"
            echo
            exit 0
            ;;

        *)
            echo
            echo "无效选项"
            echo
            ;;
    esac

    read -p "按回车继续..."

done
