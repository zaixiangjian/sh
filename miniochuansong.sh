#!/bin/bash

# 传输整个 minio 目录（rsync 比 scp 更稳）
sshpass -p "vps密码" rsync -av -e "ssh -p 22 -o StrictHostKeyChecking=no" /home/docker/minio/ root@"vpsip":/home/docker/minio/
