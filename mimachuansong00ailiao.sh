#!/bin/bash

# 本地备份目录（保留中文）
LOCAL_DIR="/home/密码"

# 远程 VPS 信息
REMOTE_USER="zaihuigengmei"
REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
REMOTE_DIR="~/mima_backup"  # 远程目录（放在远程用户 home 下）

# 获取最新的 tar.gz 文件
LATEST_FILE=$(ls -t "/home/web/密码/"*.tar.gz 2>/dev/null | head -1)

if [ -n "$LATEST_FILE" ]; then
    sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 "$LATEST_FILE" ailiaobiji@vpsip:~/mima_backup/
else
    echo "没有找到备份文件，跳过上传"
fi
