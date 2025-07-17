#!/bin/bash


# Transfer the tar archive to another VPS
ls -t /home/博客/*.tar.gz | head -1 | xargs -I {} sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 {} root@vpsip:/home/博客

# Keep only 5 tar archives and delete the rest
cd /home/博客/ && ls -t /home/博客/*.tar.gz | tail -n +4 | xargs -I {} rm {}
