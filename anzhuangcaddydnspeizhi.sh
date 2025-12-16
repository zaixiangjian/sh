#!/bin/bash

set -e  # 遇到错误立即退出

echo "===================="
echo "Caddy + Cloudflare DNS 一键安装脚本"
echo "适用于 Debian/Ubuntu 系统 (amd64)"
echo "将安装 xcaddy 并编译带 Cloudflare DNS 插件的 Caddy"
echo "===================="

# 更新系统并安装必要依赖
echo "正在更新系统并安装依赖..."
sudo apt update
sudo apt install -y curl git wget build-essential golang-go

# 检查架构（仅支持 amd64）
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    echo "错误：本脚本仅支持 amd64 架构，当前架构为 $ARCH"
    exit 1
fi

# 下载最新 xcaddy 预编译版本（v0.4.5 为当前最新）
echo "正在下载 xcaddy v0.4.5..."
wget https://github.com/caddyserver/xcaddy/releases/download/v0.4.5/xcaddy_0.4.5_linux_amd64.tar.gz

echo "解压并安装 xcaddy..."
tar -xzvf xcaddy_0.4.5_linux_amd64.tar.gz
sudo mv xcaddy /usr/local/bin/
sudo chmod +x /usr/local/bin/xcaddy

# 清理下载文件
rm xcaddy_0.4.5_linux_amd64.tar.gz

# 检查 xcaddy 是否安装成功
if ! command -v xcaddy &> /dev/null; then
    echo "xcaddy 安装失败，请检查网络或手动安装。"
    exit 1
fi

echo "xcaddy 安装成功，正在编译 Caddy（带 Cloudflare DNS 插件）..."

# 使用 xcaddy 编译 Caddy，添加 Cloudflare DNS 模块
xcaddy build --with github.com/caddy-dns/cloudflare

# 将编译好的 caddy 移动到系统路径
sudo mv caddy /usr/local/bin/
sudo chmod +x /usr/local/bin/caddy

# 检查 caddy 是否安装成功
if command -v caddy &> /dev/null; then
    echo "===================="
    echo "安装完成！"
    echo "Caddy 版本：$(caddy version)"
    echo "查看已内置 DNS 模块：caddy list-modules | grep dns"
    echo "常用命令："
    echo "  - 启动 Caddy：caddy run --config /path/to/Caddyfile"
    echo "  - 使用 Cloudflare DNS-01 挑战时，在 Caddyfile 中配置 acme_dns cloudflare {env.CF_API_TOKEN}"
    echo "===================="
else
    echo "Caddy 安装失败，请检查错误信息。"
    exit 1
fi
