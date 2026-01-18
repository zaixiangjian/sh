#!/bin/bash

# 本地备份目录（保留中文）
LOCAL_DIR="/home/web/密码"

# 远程 VPS 信息
REMOTE_USER="zaihuigengmei"
REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
REMOTE_DIR="/home/zaihuigengmei/mima_backup"  # 绝对路径

# 获取最新的 tar.gz 文件
LATEST_FILE=$(ls -t "$LOCAL_DIR"/*.tar.gz 2>/dev/null | head -1)

if [ -n "$LATEST_FILE" ]; then
    echo "开始上传备份文件: $LATEST_FILE"
    sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no -P 22 "$LATEST_FILE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
    if [ $? -eq 0 ]; then
        echo "备份文件已成功上传到远程: $REMOTE_DIR"
    else
        echo "备份上传失败，请检查网络或远程权限"
    fi
else
    echo "没有找到备份文件，跳过上传"
fi
