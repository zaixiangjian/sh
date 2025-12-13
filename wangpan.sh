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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
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
# 依赖检查与安装
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
log "检查并创建远程目录"
sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no \
    "${REMOTE_USER}@${REMOTE_IP}" "mkdir -p '$SRC/cloudreve/data'" >>"$LOG_FILE" 2>&1

########################################
# 启动时全量同步一次（整个网盘目录）
########################################
log "开始初次全量同步（整个网盘目录）"
sshpass -p "$REMOTE_PASS" rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no" \
    "$SRC/" "$DEST/" >>"$LOG_FILE" 2>&1
log "初次全量同步完成"

########################################
# 实时监控 cloudreve.db（支持 WAL 和 rollback journal 模式）
########################################
log "开始实时监控数据库文件及其临时文件（data 目录）"

inotifywait -m -e close_write,attrib,create,move_to,delete \
    -r "/home/docker/wangpan/cloudreve/data" --exclude '.*(cache|tmp).*' |
while read -r path action file; do
    # 支持 WAL 模式 (-wal, -shm) 和 rollback journal 模式 (-journal) 以及主文件
    if [[ "$file" == "cloudreve.db" || "$file" == "cloudreve.db-wal" || \
          "$file" == "cloudreve.db-shm" || "$file" == "cloudreve.db-journal" ]]; then
        
        log "检测到数据库相关事件: $action $path$file ，立即同步主数据库文件"
        
        sshpass -p "$REMOTE_PASS" rsync -az \
            -e "ssh -o StrictHostKeyChecking=no" \
            "$FILE_TO_WATCH" "${REMOTE_USER}@${REMOTE_IP}:${SRC}/cloudreve/data/cloudreve.db" >>"$LOG_FILE" 2>&1
        
        if [ $? -eq 0 ]; then
            log "数据库同步成功（主文件已更新到远程）"
        else
            log "数据库同步失败！请检查网络、密码、权限或远程路径"
        fi
    fi
done
