#!/bin/bash

# 传输整个 minio 目录（本地删远程也删）
sshpass -p "vps密码" rsync -av --delete -e "ssh -p 22 -o StrictHostKeyChecking=no" /home/docker/minio/ root@"vpsip":/home/docker/minio/
