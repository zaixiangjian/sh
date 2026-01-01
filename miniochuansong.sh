#!/bin/bash

# 传输整个 minio 目录（rsync 比 scp 更稳）
sshpass -p "$usepasswd" rsync -av -e "ssh -p 22 -o StrictHostKeyChecking=no" /home/docker/minio/ root@"$useip":/home/docker/minio/
