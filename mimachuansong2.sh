#!/bin/bash

# ==============================
# Vaultwarden 备份上传监控脚本
# ==============================

# 本地备份目录（中文路径用绝对路径包裹）
LOCAL_DIR="/home/web/密码"

# 远程 VPS 信息
REMOTE_USER="zaihuigengmei"
REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
REMOTE_DIR="/home/zaihuigengmei/mima_backup"  # 绝对路径，避免 ~ 问题

# 获取最新的 tar.gz 文件
LATEST_FILE=$(ls -t "$LOCAL_DIR"/*.tar.gz 2>/dev/null | head -1)

if [ -n "$LATEST_FILE" ]; then
    echo "✅ 准备上传文件: $LATEST_FILE"
    sshpass -p "$REMOTE_PASS" scp -o StrictHostKeyChecking=no "$LATEST_FILE" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
    if [ $? -eq 0 ]; then
        echo "✅ 文件已成功上传到 $REMOTE_USER@$REMOTE_IP:$REMOTE_DIR/"
    else
        echo "❌ 文件上传失败，请检查网络和路径"
    fi
else
    echo "⚠️ 没有找到备份文件，跳过上传"
fi
