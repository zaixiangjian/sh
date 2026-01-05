#!/bin/bash

REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
SSH_PORT=22

LOCK_FILE="/tmp/quanbubeifen.lock"
PID_FILE="/tmp/quanbubeifen.pid"

# ===== 第一步：清理假死锁（在 flock 之前）=====
if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE")
  if ! ps -p "$old_pid" >/dev/null 2>&1; then
    echo "检测到假死锁，自动清理"
    rm -f "$LOCK_FILE" "$PID_FILE"
  fi
fi

# ===== 第二步：尝试加锁 =====
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "另一个传输正在运行，退出"
  exit 1
}

# ===== 第三步：记录 PID =====
echo $$ > "$PID_FILE"
trap 'rm -f "$LOCK_FILE" "$PID_FILE"' EXIT

# ===== 你的原始传输逻辑（完全不动）=====
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

for SRC in "${SRC_LIST[@]}"; do
  echo "开始传送: $SRC"
  sshpass -p "$REMOTE_PASS" \
    rsync -avz --delete \
    -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
    "$SRC" root@"$REMOTE_IP":"$SRC"
done

echo "全部传送完成"
