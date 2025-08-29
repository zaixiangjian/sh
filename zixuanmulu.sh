#!/bin/bash

# 手动输入本地目录
read -e -p "请输入要传送的本地目录（如 /home/docker/wangpan）: " SRC

# 如果末尾没有 / 自动添加
[[ "${SRC: -1}" != "/" ]] && SRC="$SRC/"

# 远程服务器目录，与本地一致
read -e -p "请输入远程服务器IP: " REMOTE_IP
DEST="root@$REMOTE_IP:$SRC"

# 远程服务器密码
read -s -p "请输入远程服务器密码: " PASS
echo

# 创建远程目录（如果不存在）
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@$REMOTE_IP "mkdir -p $SRC"

# 使用 sshpass 调用 rsync
echo "开始同步本地文件夹到远程服务器..."
sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC" "$DEST"

echo "同步完成！"
