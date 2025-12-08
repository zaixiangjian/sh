#!/bin/bash

### ==============================
### 防止脚本重复运行（flock）
### ==============================
LOCKFILE="/tmp/quanbubeifei.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 0

### ==============================
### 系统命令绝对路径
### ==============================
SSHPASS=/usr/bin/sshpass
RSYNC=/usr/bin/rsync
INOTIFY=/usr/bin/inotifywait
SSH_OPTS="-o StrictHostKeyChecking=no"

### ==============================
### 基本变量
### ==============================
SRC=( "/home/博客" "/home/图床" "/home/密码" "/home/论坛" )

DEST_DIR="/home/"
DEST="root@vpsip:${DEST_DIR}"
PASS="vps密码"

### ==============================
### 保证远程目录存在
### ==============================
$SSHPASS -p "$PASS" ssh $SSH_OPTS root@vpsip "mkdir -p ${DEST_DIR}"

### ==============================
### 初次同步
### ==============================
for dir in $SRC; do
    $SSHPASS -p "$PASS" $RSYNC -avz --delete -e "ssh $SSH_OPTS" "$dir/" "$DEST/"
done

### ==============================
### 安装 inotify-tools
### ==============================
if ! command -v $INOTIFY >/dev/null 2>&1; then
    apt update -y >/dev/null 2>&1
    apt install -y inotify-tools >/dev/null 2>&1
fi

### ==============================
### 实时监控每个目录的修改并同步
### ==============================
for dir in $SRC; do
    $INOTIFY -m -r -e modify,create,delete "$dir" 2>/dev/null | while read -r path action file; do
        $SSHPASS -p "$PASS" $RSYNC -avz -e "ssh $SSH_OPTS" "$dir/" "$DEST/" >/dev/null 2>&1
    done &
done

wait
