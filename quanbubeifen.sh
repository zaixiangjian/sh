#!/bin/bash

REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
SSH_PORT=22

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


# ===== 你的原始传输逻辑（完全不动）=====
SRC_LIST=(
  /home/beifen.sh
  /home/备份/

)

for SRC in "${SRC_LIST[@]}"; do
  echo "开始传送: $SRC"
  sshpass -p "$REMOTE_PASS" \
    rsync -avz --delete \
    -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
    "$SRC" root@"$REMOTE_IP":"$SRC"
done

echo "全部传送完成"
