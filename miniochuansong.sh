#!/bin/bash

sshpass -p 'vps密码' scp -r -o StrictHostKeyChecking=no -P 22 \
/home/docker/minio/ root@vpsip:/home/docker/minio/
