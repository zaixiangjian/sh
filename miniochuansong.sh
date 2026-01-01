#!/bin/bash

sshpass -p 'vps密码' ssh -o StrictHostKeyChecking=no -p 22 root@vpsip "mkdir -p /home/docker/minio"
