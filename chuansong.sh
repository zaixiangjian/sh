#!/bin/bash


# Transfer the tar archive to another VPS
cd /home/ && ls -t /home/*.tar.gz | head -1 | xargs -I {} sshpass -p 'vps密码' scp -o StrictHostKeyChecking=no -P 22 {} root@vpsip:/home/

# Keep only 5 tar archives and delete the rest
cd /home/ && ls -t /home/*.tar.gz | tail -n +4 | xargs -I {} rm {}
