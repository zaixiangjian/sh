#!/bin/bash
set -e

echo "=========================================="
echo "一键安装带 Cloudflare DNS 插件的 Caddy"
echo "适用于 Debian / Ubuntu（极简环境兼容）"
echo "=========================================="

# 必须 root
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行"
  exit 1
fi

# ---------- 关键：初始化极简环境 ----------
export HOME=/root
export GOPATH=/root/go
export GOCACHE=/root/.cache/go-build
export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin

mkdir -p "$GOPATH" "$GOCACHE"

# GOPROXY（国内 / 网络不稳定强烈建议）
export GOPROXY=https://goproxy.cn,direct

echo "[1/6] 更新软件源并安装依赖..."
apt update
apt install -y curl wget tar git build-essential golang-go ca-certificates

echo "[2/6] Go 版本："
go version

echo "[3/6] 安装 xcaddy..."
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

if [ ! -f "$GOPATH/bin/xcaddy" ]; then
  echo "❌ xcaddy 安装失败"
  exit 1
fi

mv "$GOPATH/bin/xcaddy" /usr/local/bin/
chmod +x /usr/local/bin/xcaddy

echo "[4/6] 使用 xcaddy 编译 Caddy（Cloudflare DNS）..."
xcaddy build --with github.com/caddy-dns/cloudflare

echo "[5/6] 安装 caddy..."
mv caddy /usr/local/bin/
chmod +x /usr/local/bin/caddy

echo "[6/6] 验证安装..."
caddy version

echo ""
echo "检测 Cloudflare DNS 模块："
if caddy list-modules | grep -q dns.providers.cloudflare; then
  echo "✅ Cloudflare DNS 模块已集成"
else
  echo "❌ Cloudflare DNS 模块未找到"
fi

echo ""
echo "使用建议："
echo "1. 配置 Caddyfile（默认路径 /etc/caddy/Caddyfile）"
echo "2. 使用 acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN} 配置 DNS-01 挑战"
echo "3. 设置 CLOUDFLARE_API_TOKEN 环境变量或在 Caddyfile 中配置"
echo "4. 运行：sudo caddy run --config /etc/caddy/Caddyfile"
echo "更多文档：https://caddyserver.com/docs/ 和 https://github.com/caddy-dns/cloudflare"
echo "=========================================="
echo "详细文档"
echo "https://raw.githubusercontent.com/zaixiangjian/sh/refs/heads/main/anzhuangcaddydnspeizhipeizhiwenjianneirong.txt"
echo "=========================================="
echo "安装完毕！"
