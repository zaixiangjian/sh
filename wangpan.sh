#!/bin/bash

########################################
# 防止重复运行（flock）
########################################
LOCKFILE="/tmp/wangpan.lock"
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

########################################
# 基本配置（安装脚本用 sed 自动替换）
########################################
SRC="/home/docker/wangpan"
FILE_TO_WATCH="/home/docker/wangpan/cloudreve/data/cloudreve.db"

REMOTE_IP="vpsip"
REMOTE_USER="root"
REMOTE_PASS="vps密码"

DEST="${REMOTE_USER}@${REMOTE_IP}:${SRC}"

LOG_FILE="/home/docker/wangpan.log"

########################################
# 日志函数
########################################
log() {
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $1" >> "$LOG_FILE"
}

log "==== wangpan 启动 ===="

########################################
# 基础检查
########################################
if [ ! -d "$SRC" ]; then
    log "本地目录不存在：$SRC"
    exit 1
fi

if [ ! -f "$FILE_TO_WATCH" ]; then
    log "监控文件不存在：$FILE_TO_WATCH"
    exit 1
fi

########################################
# 依赖检查
########################################
need_cmds=(sshpass rsync inotifywait)

for cmd in "${need_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "缺少命令 $cmd，正在安装"
        apt update -y >>"$LOG_FILE" 2>&1
        apt install -y sshpass rsync inotify-tools >>"$LOG_FILE" 2>&1
        break
    fi
done

########################################
# 确保远程目录存在
########################################
log "检查远程目录"
sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
    "${REMOTE_USER}@${REMOTE_IP}" "mkdir -p '$SRC'" >>"$LOG_FILE" 2>&1

########################################
# 启动时全量同步一次
########################################
log "开始初次全量同步"
sshpass -p "$REMOTE_PASS" rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no" \
    "$SRC/" "$DEST/" >>"$LOG_FILE" 2>&1

log "初次同步完成"

########################################
# 实时监控 cloudreve.db
########################################
log "开始实时监控 $FILE_TO_WATCH"

inotifywait -m -e modify "$FILE_TO_WATCH" --format '%T %e' --timefmt '%F %T' |
while read -r event; do
    log "检测到数据库变更，执行同步"
    sshpass -p "$REMOTE_PASS" rsync -az \
        -e "ssh -o StrictHostKeyChecking=no" \
        "$SRC/" "$DEST/" >>"$LOG_FILE" 2>&1
    log "同步完成"
done
