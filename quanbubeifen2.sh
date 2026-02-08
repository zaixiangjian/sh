#!/bin/bash
# --------------------------------------------------------
# 单 SSH 会话传输多个目录到远程 VPS（保持原路径）
# 200 号专用：独立锁机制
# --------------------------------------------------------

# 修改点：将文件名改为 quanbubeifen2，避免与 100 冲突
LOCKFILE="/tmp/quanbubeifen2.lock"
PIDFILE="/tmp/quanbubeifen2.pid"

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

# 加锁 (注意这里的 200> 是文件描述符，建议保持或改为 201 以示彻底区别)
exec 201>"$LOCKFILE"
flock -n 201 || { echo "另一个 200 号传输正在运行，退出"; exit 0; }

# 写入当前 PID
echo $$ > "$PIDFILE"
trap 'rm -f "$LOCKFILE" "$PIDFILE"' EXIT

REMOTE_IP="vpsip"
REMOTE_PASS="vps密码"
SSH_PORT=22



# 延迟传送
WAIT_SECONDS=5




SRC_LIST=(
  /home/beifen.sh
  /home/备份/

)

echo "[$(date)] 开始传输所有目录到 $REMOTE_IP（保持原路径）"

for SRC in "${SRC_LIST[@]}"; do
    if [ -e "$SRC" ]; then
        echo "传输: $SRC -> $REMOTE_IP:$SRC"
        sshpass -p "$REMOTE_PASS" rsync -avz \
            -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=no" \
            "$SRC" root@"$REMOTE_IP":"$SRC"


        sleep "$WAIT_SECONDS"


    else
        echo "[$(date)] 文件或目录不存在，跳过: $SRC"
    fi
done

echo "[$(date)] 全部目录传输完成"
