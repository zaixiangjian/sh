#!/bin/bash

# 目标备份目录
BACKUP_DIR="/home/mima"

# 如果目录不存在则创建
if [ ! -d "$BACKUP_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
fi
# Create a tar archive of the web directory
cd /home/web/ && tar czvf /home/密码/mima_$(date +"%Y%m%d%H%M%S").tar.gz vaultwarden


# Transfer the tar archive to another VPS
cd /home/密码 && ls -t *.tar.gz | head -1 | xargs -I {} sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 "{}" root@vpsip:/home/mima/

# Keep only 5 tar archives and delete the rest
cd /home/ && ls -t /home/*.tar.gz | tail -n +10 | xargs -I {} rm {}
