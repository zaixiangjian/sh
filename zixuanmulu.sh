#!/bin/bash

# 本地目录，支持手动输入，如果不输入使用默认值
read -e -p "请输入要传送的本地目录（默认 /home/docker/wangpan/）: " input_dir
SRC="${input_dir:-/home/docker/wangpan/}"

# 如果末尾没有 / 自动添加
[[ "${SRC: -1}" != "/" ]] && SRC="$SRC/"

# 远程服务器目录，与本地一致
DEST="root@vpsip:$SRC"

# 远程服务器密码（如果使用密码方式）
PASS="vps密码"

# 创建远程目录（如果不存在）
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p $SRC"

# 使用 sshpass 调用 rsync
echo "开始同步本地文件夹到远程服务器..."
sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC" "$DEST"

echo "同步完成！"
