#!/bin/bash

set -e

RUSTDESK_VERSION="1.1.14"
DOWNLOAD_URL="https://github.com/rustdesk/rustdesk-server/releases/download/${RUSTDESK_VERSION}/rustdesk-server-linux-amd64.zip"
INSTALL_DIR="/root/rustdesk"

function install_rustdesk() {
    echo "🔄 更新系统..."
    apt update -y && apt upgrade -y

    echo "📦 安装 unzip npm..."
    apt install -y unzip npm

    echo "🗑 删除旧版本目录..."
    rm -rf $INSTALL_DIR
    mkdir -p $INSTALL_DIR

    echo "🌐 下载 RustDesk Server..."
    wget -O /tmp/rustdesk.zip "$DOWNLOAD_URL"

    echo "📂 解压到 /root/rustdesk ..."
    unzip /tmp/rustdesk.zip -d $INSTALL_DIR

    echo "📦 安装 PM2..."
    npm install -g pm2

    echo "🚀 启动 hbbs / hbbr ..."
    cd $INSTALL_DIR/amd64

    pm2 delete hbbs >/dev/null 2>&1 || true
    pm2 delete hbbr >/dev/null 2>&1 || true

    pm2 start hbbs
    pm2 start hbbr

    echo "🧷 设置 PM2 开机启动..."
    pm2 startup
    pm2 save

    echo "====================================="
    echo "🎉 RustDesk Server 安装成功！"
    echo "📌 安装目录：$INSTALL_DIR"
    echo "📌 程序目录：$INSTALL_DIR/amd64"
    echo "🚀 hbbs / hbbr 已启动并开机自启"
    echo "====================================="
}

function uninstall_rustdesk() {
    echo "🛑 停止 PM2 进程..."
    pm2 delete hbbs || true
    pm2 delete hbbr || true
    pm2 save

    echo "🗑 删除目录 $INSTALL_DIR ..."
    rm -rf $INSTALL_DIR

    echo "❌ RustDesk Server 已卸载。"
}

function view_status() {
    echo "📊 查看 PM2 运行状态..."
    pm2 list
}

function view_logs() {
    echo "📜 查看 hbbs 日志（实时）"
    pm2 logs hbbs
}

function menu() {
    echo "=============================="
    echo "     🛠 RustDesk 管理脚本"
    echo "=============================="
    echo "1. 安装 RustDesk Server"
    echo "2. 查看服务状态 (pm2 list)"
    echo "3. 查看日志 (hbbs)"
    echo "4. 卸载 RustDesk Server"
    echo "0. 退出"
    echo "=============================="
    read -p "请输入选项: " choice

    case "$choice" in
        1) install_rustdesk ;;
        2) view_status ;;
        3) view_logs ;;
        4) uninstall_rustdesk ;;
        0) exit 0 ;;
        *) echo "❌ 无效选项，请重试" ;;
    esac
}

while true; do
    menu
done
