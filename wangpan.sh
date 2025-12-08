#!/bin/bash

### ==============================
### 防止脚本重复运行（flock）
### ==============================
LOCKFILE="/tmp/wangpan.lock"
exec 200>$LOCKFILE
flock -n 200 || {
    echo "⚠ 上一次任务还在运行，已自动跳过本次执行"
    exit 1
}

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
echo "开始首次同步..."
sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC/" "$DEST/"
echo "首次同步完成！"

### ==============================
### 实时监控 cloudreve.db 变化
### ==============================

# 需要 inotifywait
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "未检测到 inotifywait，正在安装 inotify-tools..."
    apt update -y >/dev/null 2>&1
    apt install -y inotify-tools >/dev/null 2>&1
fi

echo "开始监控文件变化：$FILE_TO_WATCH"
echo "当数据库 cloudreve.db 变化时会自动同步..."

inotifywait -m -e modify "$FILE_TO_WATCH" | while read -r path action file; do
    echo "检测到 $file 发生变化，正在同步..."
    sshpass -p "$PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" "$SRC/" "$DEST/"
    echo "同步完成！"
done
