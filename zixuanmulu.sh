#!/bin/bash

# 让用户输入本地目录，默认是 /home/docker/wangpan/
read -e -p "请输入要同步的本地目录 (默认: /home/docker/wangpan/): " SRC
SRC=${SRC:-/home/docker/wangpan/}

# 远程服务器目录，与本地一致
DEST="root@vpsip:$SRC"

# 远程服务器密码
PASS="vps密码"

# 创建远程目录（如果不存在）
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p $SRC"

# 使用 sshpass 调用 rsync
echo "开始同步本地文件夹到远程服务器..."
sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC/" "$DEST/"

echo "同步完成！"
