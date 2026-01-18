#!/bin/bash

# 本地备份目录
LOCAL_DIR="/home/web/密码"

# 远程 VPS 信息
REMOTE_USER="zaihuigengmei"
REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
REMOTE_DIR="/home/zaihuigengmei/mima_backup"  # 绝对路径

# 获取最新的 tar.gz 文件
LATEST_FILE=$(ls -t "$LOCAL_DIR"/*.tar.gz 2>/dev/null | head -n 1)

if [ -n "$LATEST_FILE" ]; then
    # 确保远程目录存在
    sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_IP" "mkdir -p $REMOTE_DIR"
    
    # 上传文件
    sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no -P 22 "$LATEST_FILE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
    
    echo "备份文件已上传: $LATEST_FILE"
else
    echo "没有找到备份文件，跳过上传"
fi
