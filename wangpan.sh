#!/bin/bash

### ==============================
### 防止脚本重复运行（flock）
### ==============================
LOCKFILE="/tmp/wangpan.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 0   # 如果已有进程运行，直接退出，不输出

### ==============================
### 基本变量
### ==============================
SRC="/home/docker/wangpan/"
FILE_TO_WATCH="/home/docker/wangpan/cloudreve/data/cloudreve.db"
DEST="root@vpsip:$SRC"
PASS="vps密码"

### ==============================
### 保证远程目录存在
### ==============================
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p $SRC"

### ==============================
### 执行初次同步（整目录）
### ==============================
sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC/" "$DEST/"

### ==============================
### 实时监控 cloudreve.db 变化
### ==============================

# 安装 inotifywait 如果不存在
if ! command -v inotifywait >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y inotify-tools >/dev/null 2>&1
fi

# 实时监控，修改时自动同步，不输出日志
inotifywait -m -e modify "$FILE_TO_WATCH" 2>/dev/null | while read -r path action file; do
    sshpass -p "$PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" "$SRC/" "$DEST/" >/dev/null 2>&1
done
