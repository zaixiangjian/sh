#!/bin/bash

REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
SSH_PORT=22

# 等待时间（秒），可调，防止 SSH 瞬时多次连接被拒
WAIT_SECONDS=5

# 要传送的文件和目录
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

# 锁文件，保证同一时间只有一个 rsync 在跑
LOCK_FILE="/tmp/quanbubeifen-rsync.lock"

for SRC in "${SRC_LIST[@]}"; do
  echo "开始传送: $SRC"

  # 使用 flock 防止并发
  (
    flock -n 200 || { echo "另一个传输正在运行，跳过: $SRC"; exit 1; }

    sshpass -p "$REMOTE_PASS" rsync -avz --delete \
      -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
      "$SRC" root@"$REMOTE_IP":"$SRC"

  ) 200>"$LOCK_FILE"

  # 每个目录/文件传输完成后等待一段时间
  sleep "$WAIT_SECONDS"
done

echo "全部传送完成"
