#!/bin/bash

REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
SSH_PORT=22

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

for SRC in "${SRC_LIST[@]}"; do
  echo "开始传送: $SRC"

  sshpass -p "$REMOTE_PASS" rsync -avz \
    -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
    "$SRC" root@"$REMOTE_IP":"$SRC"

done

echo "全部传送完成"
