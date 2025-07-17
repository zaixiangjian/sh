#!/bin/bash

# Create the backup directory if it doesn't exist
mkdir -p /home/博客

# Create a tar archive of the web directory and save it in /home/博客/
tar czvf /home/博客/web_$(date +"%Y%m%d%H%M%S").tar.gz -C /home/ web

# Transfer the latest tar archive to another VPS
# 如果你确认这是你自己的服务器，并且知道密钥变化是正常的，可以这样处理：
# SSH密码变化ssh链接输入代码


# ssh-keygen -f "/root/.ssh/known_hosts" -R "103.234.53.1"



# Transfer the tar archive to another VPS
ls -t /home/博客/*.tar.gz | head -1 | xargs -I {} sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 {} root@vpsip:/home/博客


# Keep only 5 tar archives in /home/博客/ and delete the rest
cd /home/博客/ && ls -t *.tar.gz | tail -n +4 | xargs -I {} rm {}
