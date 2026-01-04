#!/bin/bash
# --------------------------------------------------------
# 单 SSH 会话传输多个目录到远程 VPS
# 支持中文目录、锁机制、防止短时间多 SSH 被拒绝
# --------------------------------------------------------

REMOTE_IP="vpsip"        # 远程 VPS IP
REMOTE_PASS="vps密码"    # VPS root 密码
SSH_PORT=22               # SSH 端口

# 等待时间（秒），传输完成后暂停，防止短时间多次 SSH
WAIT_SECONDS=10

# 要传输的文件和目录
SRC_LIST=(
  /home/beifen.sh
  /home/博客/
  /home/图床/
  /home/密码/
  /home/论坛/
  /home/论坛1/
  /home/论坛备份/
  /home/论坛备份1/
)

# 锁文件，防止并发执行
LOCK_FILE="/tmp/quanbubeifen-rsync.lock"

# -------------------- 单 SSH 会话传输 --------------------

(
    # 使用 flock 防止同时执行多个实例
    flock -n 200 || { echo "另一个传输正在运行，退出"; exit 1; }

    echo "[$(date)] 开始传输所有目录到 $REMOTE_IP"

    # 拼接存在的目录和文件，避免不存在时报错
    ARGS=""
    for SRC in "${SRC_LIST[@]}"; do
        if [ -e "$SRC" ]; then
            ARGS="$ARGS $SRC"
        else
            echo "[$(date)] 文件或目录不存在，跳过: $SRC"
        fi
    done

    # 如果没有可传输的目录，则退出
    if [ -z "$ARGS" ]; then
        echo "[$(date)] 没有可传输的目录或文件，退出"
        exit 0
    fi

    # rsync 传输，单 SSH 会话
    sshpass -p "$REMOTE_PASS" rsync -avz --delete \
        -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
        $ARGS root@"$REMOTE_IP":/

    echo "[$(date)] 全部目录传输完成"

) 200>"$LOCK_FILE"

# 等待一段时间，防止监控脚本连续触发
sleep "$WAIT_SECONDS"
