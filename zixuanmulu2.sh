#!/bin/bash

CONF_FILE="/root/.zixuanmulu2.conf"

# 判断是否已有记录
if [ -f "$CONF_FILE" ]; then
    SRC=$(cat "$CONF_FILE")
    echo "自动使用上次目录: $SRC"
else
    # 第一次运行时让用户输入
    read -e -p "请输入要同步的本地目录 (默认: /home/docker/wangpan/): " SRC
    SRC=${SRC:-/home/docker/wangpan/}
    echo "$SRC" > "$CONF_FILE"
fi

# 如果本地目录不存在，则自动创建
if [ ! -d "$SRC" ]; then
    echo "本地目录 $SRC 不存在，正在创建..."
    mkdir -p "$SRC"
    echo "本地目录已创建：$SRC"
fi

# 保存目录（保证手动修改也能更新记录）
echo "$SRC" > "$CONF_FILE"

# 远程服务器目录，与本地一致
DEST="root@vpsip:$SRC"

# 远程服务器密码
PASS="vps密码"

# 创建远程目录（如果不存在）
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@vpsip "mkdir -p $SRC"

# 使用 sshpass 调用 rsync
echo "开始同步本地文件夹到远程服务器..."
sshpass -p "$PASS" rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" "$SRC/" "$DEST/"

echo "同步完成！"
