#!/bin/bash

# caddydns.sh - 一键安装带 Cloudflare DNS 插件的 Caddy（适用于 Debian/Ubuntu 系统）
# 支持 amd64 和 arm64 架构
# 使用 xcaddy 编译最新版 Caddy，并集成 github.com/caddy-dns/cloudflare 模块
# 作者：Grok 生成
# 用法：sudo bash caddydns.sh

set -e  # 遇到错误立即退出

echo "=========================================="
echo "一键安装带 Cloudflare DNS 插件的 Caddy"
echo "适用于 Debian/Ubuntu 系统"
echo "=========================================="

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 sudo 或 root 用户运行此脚本！"
  exit 1
fi

# 更新软件包列表并安装必要依赖
echo "更新软件源并安装依赖..."
apt update
apt install -y curl wget tar git build-essential

# 检测系统架构
ARCH=$(uname -m)
case $ARCH in
  x86_64)
    XCADDY_ARCH="amd64"
    ;;
  aarch64)
    XCADDY_ARCH="arm64"
    ;;
  *)
    echo "错误：不支持的架构 $ARCH"
    exit 1
    ;;
esac

# 下载最新 xcaddy 预编译二进制文件（当前最新版本 v0.4.5）
echo "下载 xcaddy（适用于 linux $XCADDY_ARCH）..."
XCADDY_VERSION="v0.4.5"
XCADDY_TAR="xcaddy_${XCADDY_VERSION#_}_linux_${XCADDY_ARCH}.tar.gz"
wget "https://github.com/caddyserver/xcaddy/releases/download/${XCADDY_VERSION}/${XCADDY_TAR}"

# 解压并安装 xcaddy
echo "安装 xcaddy 到 /usr/local/bin ..."
tar -xzvf "$XCADDY_TAR" xcaddy
mv xcaddy /usr/local/bin/
chmod +x /usr/local/bin/xcaddy

# 清理下载文件
rm "$XCADDY_TAR"

# 使用 xcaddy 编译带 Cloudflare DNS 插件的 Caddy（自动使用最新 Caddy 版本）
echo "正在使用 xcaddy 编译 Caddy（集成 Cloudflare DNS 插件）..."
echo "这可能需要几分钟时间，请耐心等待..."
xcaddy build --with github.com/caddy-dns/cloudflare

# 将编译好的 caddy 移动到系统路径
echo "安装 caddy 到 /usr/local/bin ..."
mv caddy /usr/local/bin/
chmod +x /usr/local/bin/caddy

# 验证安装
echo "安装完成！"
echo "Caddy 版本："
caddy version

echo ""
echo "验证已集成 Cloudflare DNS 模块："
if caddy list-modules | grep -q "dns.providers.cloudflare"; then
  echo "成功：dns.providers.cloudflare 模块已集成！"
else
  echo "警告：未检测到 Cloudflare DNS 模块，请检查编译过程。"
fi

echo ""
echo "使用建议："
echo "1. 配置 Caddyfile（默认路径 /etc/caddy/Caddyfile）"
echo "2. 使用 acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN} 配置 DNS-01 挑战"
echo "3. 设置 CLOUDFLARE_API_TOKEN 环境变量或在 Caddyfile 中配置"
echo "4. 运行：sudo caddy run --config /etc/caddy/Caddyfile"
echo "更多文档：https://caddyserver.com/docs/ 和 https://github.com/caddy-dns/cloudflare"

echo "=========================================="
echo "安装完毕！"
