#!/bin/bash
# 一键安装 Discourse 脚本
# 适用于 Ubuntu/Debian 系统

# 检查是否为 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本！"
  exit 1
fi

echo "更新系统并安装依赖..."
apt update -y
apt install -y sudo curl git netcat-openbsd docker.io

# 启动 Docker 并设置开机自启
systemctl enable docker
systemctl start docker

echo "克隆 Discourse Docker 仓库..."
git clone https://github.com/discourse/discourse_docker.git /var/discourse
cd /var/discourse || exit

chmod 700 containers

echo "准备执行 Discourse 安装..."
echo "请根据提示输入你的域名、邮箱及 SMTP 等信息。"
./discourse-setup

echo "安装完成！如果需要重新构建容器，请运行："
echo "cd /var/discourse && ./launcher rebuild app"
