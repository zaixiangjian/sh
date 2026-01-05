#!/bin/bash

### ==============================
### 防止脚本重复运行（flock）
### ==============================
LOCKFILE="/tmp/wangpan.lock"
PIDFILE="/tmp/wangpan.pid"

# 假锁检测：如果 LOCKFILE 存在，但 PID 文件不存在，直接清理
if [ -f "$LOCKFILE" ]; then
    if [ -f "$PIDFILE" ]; then
        old_pid=$(cat "$PIDFILE")
        if ! kill -0 "$old_pid" 2>/dev/null; then
            echo "检测到假锁死，自动清理"
            rm -f "$LOCKFILE" "$PIDFILE"
        fi
    else
        echo "锁文件存在但 PID 文件不存在，自动清理"
        rm -f "$LOCKFILE"
    fi
fi

# 加锁
exec 200>"$LOCKFILE"
flock -n 200 || { echo "另一个传输正在运行，退出"; exit 0; }

# 写入当前 PID
echo $$ > "$PIDFILE"
trap 'rm -f "$LOCKFILE" "$PIDFILE"' EXIT

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
