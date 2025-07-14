#!/bin/bash

# Create the backup directory if it doesn't exist
mkdir -p /home/密码/

# Create a tar archive of the web directory and save it in /home/beifen/
tar -czvf /home/密码/mima_$(date +%Y%m%d%H%M%S).tar.gz -C /home/web vaultwarden

# Transfer the latest tar archive to another VPS
# 如果你确认这是你自己的服务器，并且知道密钥变化是正常的，可以这样处理：
# SSH密码变化ssh链接输入代码


# ssh-keygen -f "/root/.ssh/known_hosts" -R "103.234.53.1"

#                                                                                         别忘记哈希加密
ls -t /home/密码/*.tar.gz | head -1 | xargs -I {} sshpass -p '密码' scp -o StrictHostKeyChecking=no -P 22 {} root@1.1.1.1:/home/密码



# Keep only 5 tar archives in /home/beifen/ and delete the rest
cd /home/web/beifen/ && ls -t *.tar.gz | tail -n +10 | xargs -I {} rm {}

cd /home/博客/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
cd /home/论坛/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
cd /home/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
