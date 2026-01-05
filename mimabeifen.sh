#!/bin/bash

LOCKFILE="/tmp/vaultwarden_beifen.lock"
PIDFILE="/tmp/vaultwarden_beifen.pid"

# 假锁检测
if [ -f "$PIDFILE" ]; then
    old_pid=$(cat "$PIDFILE")
    if ! ps -p "$old_pid" >/dev/null 2>&1; then
        echo "检测到假锁死，自动清理"
        rm -f "$LOCKFILE" "$PIDFILE"
    fi
fi

# 加锁
exec 200>"$LOCKFILE"
flock -n 200 || { echo "另一个备份正在运行，退出"; exit 0; }

# 记录当前 PID
echo $$ > "$PIDFILE"
trap 'rm -f "$LOCKFILE" "$PIDFILE"' EXIT



# Create the backup directory if it doesn't exist
mkdir -p /home/密码/

# Create a tar archive of the web directory and save it in /home/beifen/
tar -czvf /home/密码/mima_$(date +%Y%m%d%H%M%S).tar.gz -C /home/docker vaultwarden

# Transfer the latest tar archive to another VPS
# 如果你确认这是你自己的服务器，并且知道密钥变化是正常的，可以这样处理：
# SSH密码变化ssh链接输入代码


# ssh-keygen -f "/root/.ssh/known_hosts" -R "103.234.53.1"

#                                                                                         别忘记哈希加密
ls -t /home/密码/*.tar.gz | head -1 | xargs -I {} sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 {} root@vpsip:/home/密码



# Keep only 5 tar archives in /home/beifen/ and delete the rest
cd /home/密码/ && ls -t *.tar.gz | tail -n +10 | xargs -I {} rm {}

cd /home/博客/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
cd /home/论坛/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
cd /home/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
