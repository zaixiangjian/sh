#!/bin/bash
# --------------------------------------------------------
# 单 SSH 会话传输多个目录到远程 VPS（保持原路径）
# 中文目录支持、锁机制、防止短时间多 SSH 被拒绝
# --------------------------------------------------------

REMOTE_IP="vpsip"        # 远程 VPS IP
REMOTE_PASS="vps密码"    # VPS root 密码
SSH_PORT=22               # SSH 端口

WAIT_SECONDS=10           # 传输完成后等待，防止短时间触发

# 要传输的文件和目录（本地路径）
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

# 锁文件
LOCK_FILE="/tmp/quanbubeifen-rsync.lock"

# -------------------- 单 SSH 会话传输 --------------------
(
    flock -n 200 || { echo "另一个传输正在运行，退出"; exit 1; }

    echo "[$(date)] 开始传输所有目录到 $REMOTE_IP（保持原路径）"

    for SRC in "${SRC_LIST[@]}"; do
        if [ -e "$SRC" ]; then
            echo "传输: $SRC -> $REMOTE_IP:$SRC"
            sshpass -p "$REMOTE_PASS" rsync -avz --delete \
                -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
                "$SRC" root@"$REMOTE_IP":"$SRC"
            
            # 每个目录传完等待，防止 VPS 拒绝连接
            sleep "$WAIT_SECONDS"
        else
            echo "[$(date)] 文件或目录不存在，跳过: $SRC"
        fi
    done

    echo "[$(date)] 全部目录传输完成"

) 200>"$LOCK_FILE"
