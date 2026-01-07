#!/usr/bin/env bash
set -e

INSTALL_DIR="/home/docker"
MAILCOW_DIR="${INSTALL_DIR}/mailcow-dockerized"

echo "=============================="
echo " Mailcow One-Click Installer"
echo " Install path: ${MAILCOW_DIR}"
echo "=============================="
sleep 1

# 1. 必须 root
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请使用 root 用户运行"
  exit 1
fi

# 2. 创建目录
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# 3. 安装依赖
echo "🔧 安装系统依赖..."
apt update
apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  git \
  jq

# 4. 安装 Docker（如果不存在）
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 安装 Docker..."
  curl -fsSL https://get.docker.com | sh
fi

# 5. 安装 docker-compose（插件模式）
if ! docker compose version >/dev/null 2>&1; then
  echo "🐳 安装 docker-compose..."
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/v2.25.0/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

systemctl enable docker
systemctl restart docker

# 6. 下载 Mailcow
if [ ! -d "${MAILCOW_DIR}" ]; then
  echo "📥 克隆 Mailcow 仓库..."
  git clone https://github.com/mailcow/mailcow-dockerized.git
else
  echo "📁 Mailcow 目录已存在，跳过 clone"
fi

cd "${MAILCOW_DIR}"

# 7. 生成配置（交互式）
echo "⚙️ 运行 Mailcow 配置生成脚本..."
bash generate_config.sh

# 8. 拉取镜像
echo "📦 拉取 Docker 镜像..."
docker compose pull

# 9. 启动服务
echo "🚀 启动 Mailcow..."
docker compose up -d

# 读取 MAILCOW_HOSTNAME
MAILCOW_HOSTNAME=$(grep '^MAILCOW_HOSTNAME=' mailcow.conf | cut -d= -f2)


# 10. 完成提示
echo "------------------------------------------------"
echo "✅ Mailcow 安装完成！"
echo "📂 安装目录: ${MAILCOW_DIR}"
echo ""
echo "🌐 管理后台"
echo "https://${MAILCOW_HOSTNAME}/admin"
echo "默认管理员账号"
echo "admin"
echo "密码"
echo "moohoo"
echo ""
echo "尽快修改密码"
echo "------------------------------------------------"
