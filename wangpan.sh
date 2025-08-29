#!/bin/bash

# 本地目录
SRC="/home/docker/wangpan/"
# 远程服务器目录，与本地一致
DEST="root@vpsip:$SRC"

# 远程服务器密码（如果使用密码方式）
PASS="vps密码"

# 创建远程目录（如果不存在）
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p $SRC"

# 使用 rsync 同步文件夹
echo "开始同步本地文件夹到远程服务器..."
rsync -avz --delete "$SRC/" "$DEST/"

echo "同步完成！"
