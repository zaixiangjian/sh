#!/bin/bash

# Transfer the tar archive to another VPS
ls -t /home/密码/*.tar.gz | head -1 | xargs -I {} sshpass -p "$usepasswd" scp -o StrictHostKeyChecking=no -P 22 {} root@"$useip":/home/密码
