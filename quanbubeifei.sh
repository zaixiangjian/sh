#!/bin/bash

### ==============================
### 防止脚本重复运行（flock）
### ==============================
LOCKFILE="/tmp/quanbubeifei.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 0

### ==============================
### 基本变量
### ==============================
SRC="/home/博客 /home/图床 /home/密码 /home/论坛"
DEST_DIR="/home"          # 目标目录（远程）
DEST="root@vpsip:${DEST_DIR}"
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p ${DEST_DIR}"
PASS="vps密码"

### ==============================
### 保证远程目录存在
### ==============================
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p ${DEST_DIR}"

### ==============================
### 初次同步
### ==============================
for dir in $SRC; do
    sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$dir/" "$DEST/"
done

### ==============================
### 安装 inotify-tools
### ==============================
if ! command -v inotifywait >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y inotify-tools >/dev/null 2>&1
fi

### ==============================
### 监听每个目录的修改并实时同步
### ==============================
for dir in $SRC; do
    inotifywait -m -r -e modify,create,delete "$dir" 2>/dev/null | while read -r path action file; do
        sshpass -p "$PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" "$dir/" "$DEST/" >/dev/null 2>&1
    done &
done

wait
