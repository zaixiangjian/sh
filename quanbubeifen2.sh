#!/bin/bash
# --------------------------------------------------------
# 单 SSH 会话传输多个目录到远程 VPS（保持原路径）
# 中文目录支持、锁机制、防止短时间多 SSH 被拒绝
# --------------------------------------------------------

LOCKFILE="/tmp/quanbubeifen.lock"
PIDFILE="/tmp/quanbubeifen.pid"

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

REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
SSH_PORT=22
WAIT_SECONDS=10

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

echo "[$(date)] 开始传输所有目录到 $REMOTE_IP（保持原路径）"

for SRC in "${SRC_LIST[@]}"; do
    if [ -e "$SRC" ]; then
        echo "传输: $SRC -> $REMOTE_IP:$SRC"
        sshpass -p "$REMOTE_PASS" rsync -avz --delete \
            -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
            "$SRC" root@"$REMOTE_IP":"$SRC"
        sleep "$WAIT_SECONDS"
    else
        echo "[$(date)] 文件或目录不存在，跳过: $SRC"
    fi
done

echo "[$(date)] 全部目录传输完成"
