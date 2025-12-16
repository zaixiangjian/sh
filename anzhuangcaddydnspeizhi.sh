#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Caddy + Cloudflare DNS 插件 一键安装脚本（改进版）#
# 适用系统：Debian / Ubuntu (amd64)
# 功能：
#   - 自动检查并安装必要环境
#   - 安装 Go（官方二进制，避免 apt 旧版本）
#   - 使用 xcaddy 编译带 Cloudflare DNS 的 Caddy
#   - 安装 systemd 服务（可选）
# ======================================================

# ---------- 基础检查 ----------
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 用户运行：sudo bash caddydns.sh"
  exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
  echo "❌ 仅支持 amd64 (x86_64)，当前架构：$ARCH"
  exit 1
fi

# ---------- 变量定义 ----------
GO_VERSION="1.22.5"
GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/${GO_TARBALL}"
GO_INSTALL_DIR="/usr/local/go"
SRC_DIR="/usr/local/src/caddy-build"

# ---------- 安装系统依赖 ----------
echo "▶ 安装系统依赖"
apt update
apt install -y \
  curl wget git ca-certificates \
  build-essential pkg-config \
  libcap2-bin systemd

# ---------- 安装 Go ----------
if ! command -v go >/dev/null 2>&1; then
  echo "▶ 安装 Go ${GO_VERSION}"
  wget -q ${GO_URL}
  rm -rf ${GO_INSTALL_DIR}
  tar -C /usr/local -xzf ${GO_TARBALL}
  rm -f ${GO_TARBALL}

  echo 'export PATH=/usr/local/go/bin:$PATH' >/etc/profile.d/go.sh
  export PATH=/usr/local/go/bin:$PATH
else
  echo "✔ 已存在 Go：$(go version)"
fi

# ---------- 安装 xcaddy ----------
if ! command -v xcaddy >/dev/null 2>&1; then
  echo "▶ 安装 xcaddy"
  export GOPATH=/root/go
  export PATH=$PATH:/usr/local/go/bin:$GOPATH/bin
  go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
  install -m 755 "$GOPATH/bin/xcaddy" /usr/local/bin/xcaddy
else
  echo "✔ xcaddy 已存在"
fi

# ---------- 编译 Caddy ----------
echo "▶ 编译 Caddy（Cloudflare DNS 插件）"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

xcaddy build \
  --with github.com/caddy-dns/cloudflare

# ---------- 安装 Caddy ----------
install -m 755 caddy /usr/local/bin/caddy

# 设置低端口能力（可监听 80/443）
setcap 'cap_net_bind_service=+ep' /usr/local/bin/caddy

# ---------- 安装 systemd 服务（官方方式） ----------
if [ ! -f /etc/systemd/system/caddy.service ]; then
  echo "▶ 安装 Caddy systemd 服务"
  cat >/etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
fi

# ---------- 创建配置目录 ----------
mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy

# ---------- 验证 ----------
echo "\n✔ Caddy 版本："
caddy version

echo "\n✔ 已编译 DNS 模块："
caddy list-modules | grep dns || true

cat <<EOF

🎉 安装完成！

下一步：
1. 创建 /etc/caddy/Caddyfile
2. 设置 Cloudflare API Token：
   export CLOUDFLARE_API_TOKEN=xxxx
3. 启动服务：
   systemctl daemon-reexec
   systemctl daemon-reload
   systemctl enable --now caddy

EOF
