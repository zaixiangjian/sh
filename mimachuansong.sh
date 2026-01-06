#!/bin/bash

# 本地备份目录（英文）
LOCAL_DIR="/home/docker/vaultwarden/data/backup"

# 远程 VPS 信息
REMOTE_USER="ailiaobiji"
REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
REMOTE_DIR="~/mima_backup"  # 远程目录

# 确保本地目录存在
mkdir -p "$LOCAL_DIR"

# 获取最新的 tar.gz 文件
LATEST_FILE=$(ls -t "$LOCAL_DIR"/*.tar.gz 2>/dev/null | head -1)

if [ -n "$LATEST_FILE" ]; then
    # 在远程创建目录
    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"
    # 上传文件
    sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no -P 22 "$LATEST_FILE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
    echo "备份已上传到 $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
else
    echo "没有找到备份文件，跳过上传"
fi
