#!/bin/bash
set -e

# ========= 配置 =========
DOWNLOAD_URL="https://github.com/zaixiangjian/ziyongcdn/releases/download/m3u8/m3u8-app.tar.gz"
TARGET_DIR="/home"
TAR_FILE="/home/m3u8-app.tar.gz"
APP_DIR="/home/m3u8-app"
CADDY_USER="caddy"
CADDY_GROUP="caddy"
# ========================

echo "📥 开始下载 m3u8-app..."
if command -v curl >/dev/null 2>&1; then
    curl -L -o "$TAR_FILE" "$DOWNLOAD_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$TAR_FILE" "$DOWNLOAD_URL"
else
    echo "❌ curl 和 wget 都不存在，无法下载"
    exit 1
fi

echo "📦 解压到 /home ..."
tar -xzvf "$TAR_FILE" -C "$TARGET_DIR"

echo "🔐 设置 Caddy 访问权限..."

# 允许 caddy 进入 /home
chmod +x /home

# 设置项目目录权限
chown -R ${CADDY_USER}:${CADDY_GROUP} "$APP_DIR"
chmod -R 755 "$APP_DIR"

echo "✅ m3u8-app 部署完成！"
echo "📁 目录：$APP_DIR"
