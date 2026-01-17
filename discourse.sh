#!/bin/bash
# Discourse 一键安装 / 重建脚本
# root 用户运行

# 检查是否为 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本！"
  exit 1
fi

echo "请选择操作："
echo "1) 安装 Discourse"
echo "2) 重新构建容器"
echo "---------------------------------------------------------------------------"
echo "默认备份目录"
echo "/var/discourse/shared/standalone/backups/default/"
echo "---------------------------------------------------------------------------"
read -rp "请输入 1 或 2: " choice

if [ "$choice" = "1" ]; then
    echo "更新系统并安装依赖..."
    apt update -y
    apt install -y sudo curl git netcat-openbsd docker.io

    echo "启动 Docker 并设置开机自启..."
    systemctl enable docker
    systemctl start docker

    echo "克隆 Discourse Docker 仓库..."
    git clone https://github.com/discourse/discourse_docker.git /var/discourse
    cd /var/discourse || exit
    chmod 700 containers

    echo "执行 Discourse 安装..."
    ./discourse-setup

    echo "安装完成！"
    echo "如果需要重新构建容器，请运行脚本并选择 2。"

elif [ "$choice" = "2" ]; then
    if [ -d /var/discourse ]; then
        cd /var/discourse || exit
        echo "开始重建 Discourse 容器..."
        ./launcher rebuild app
        echo "重建完成！"
    else
        echo "/var/discourse 不存在，请先安装 Discourse。"
        exit 1
    fi
else
    echo "无效选择，退出脚本。"
    exit 1
fi
