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
SRC="/home/博客 /home/图床 /home/密码 /home/论坛"
DEST="root@vpsip:/home/quanbubeifei.x"
PASS="vps密码"

### ==============================
### 保证远程目录存在
### ==============================
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p /home/quanbubeifei.x"

### ==============================
### 执行初次同步（整目录）
### ==============================
for dir in $SRC; do
    sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$dir/" "$DEST/"
done

### ==============================
### 实时监控文件变化
### ==============================
# 安装 inotifywait 如果不存在
if ! command -v inotifywait >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y inotify-tools >/dev/null 2>&1
fi

# 遍历每个目录进行监控
for dir in $SRC; do
    inotifywait -m -r -e modify,create,delete "$dir" 2>/dev/null | while read -r path action file; do
        sshpass -p "$PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" "$dir/" "$DEST/" >/dev/null 2>&1
    done &
done

# 等待所有后台监控进程结束
wait
