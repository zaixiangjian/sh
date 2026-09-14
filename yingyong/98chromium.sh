#!/bin/bash

APP_DIR="/home/docker/chromium"
BACKUP_DIR="/home"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
CONTAINER_NAME="chromium"

generate_auth() {
  USERNAME="user$(shuf -i 1000-9999 -n 1)"
  PASSWORD=$(openssl rand -base64 12)
}

install() {
  mkdir -p $APP_DIR
  cd $APP_DIR || exit

  generate_auth

  echo "生成账号密码："
  echo "用户名: $USERNAME"
  echo "密码: $PASSWORD"

  cat > $ENV_FILE <<EOF
CUSTOM_USER=$USERNAME
PASSWORD=$PASSWORD
LC_ALL=zh_CN.UTF-8
EOF

  cat > $COMPOSE_FILE <<EOF
version: "3.8"

services:
  chromium:
    image: lscr.io/linuxserver/chromium:latest
    container_name: $CONTAINER_NAME
    environment:
      - PUID=0
      - PGID=0
      - TZ=Asia/Shanghai
      - CUSTOM_USER=$USERNAME
      - PASSWORD=$PASSWORD
      - LC_ALL=zh_CN.UTF-8
      - TITLE=Chromium
    volumes:
      - ./config:/config
    ports:
      - "3000:3000"
      - "3001:3001"
    shm_size: "1gb"
    restart: unless-stopped
EOF

  docker compose up -d

  echo "安装完成：http://IP:3000"
}

update() {
  cd $APP_DIR || exit
  docker compose pull
  docker compose up -d
  echo "更新完成"
}

backup() {
  DATE=$(date +%Y%m%d_%H%M%S)
  FILE="$BACKUP_DIR/chromium-$DATE.tar.gz"

  tar -czvf $FILE -C /home/docker chromium

  echo "备份完成：$FILE"
}

restore() {
  echo "================================="
  echo " Chromium 备份恢复"
  echo "================================="

  FILES=($(ls -t /home/chromium-*.tar.gz 2>/dev/null))

  if [ ${#FILES[@]} -eq 0 ]; then
    echo "❌ 没有找到备份文件 (/home/chromium-*.tar.gz)"
    return
  fi

  echo "请选择备份文件（回车默认最新）："
  echo ""

  i=1
  for f in "${FILES[@]}"; do
    echo "$i) $(basename $f)"
    ((i++))
  done

  echo ""
  read -p "输入序号(默认1): " INDEX

  if [ -z "$INDEX" ]; then
    INDEX=1
  fi

  FILE="${FILES[$((INDEX-1))]}"

  if [ ! -f "$FILE" ]; then
    echo "❌ 文件不存在: $FILE"
    return
  fi

  echo "⚠️ 将恢复: $(basename $FILE)"
  read -p "确认输入 yes 继续: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "已取消"
    return
  fi

  echo "停止 Docker 容器..."
  docker stop chromium 2>/dev/null
  docker rm chromium 2>/dev/null

  echo "清理旧目录..."
  rm -rf /home/docker/chromium
  mkdir -p /home/docker

  echo "解压备份..."
  tar -xzvf "$FILE" -C /home/docker/

  cd /home/docker/chromium || exit
  docker compose up -d

  echo "✅ 恢复完成"
}

uninstall() {
  echo "⚠️ 即将卸载 Chromium（容器 + 本地数据全部删除）"
  read -p "确认输入 yes 继续: " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo "已取消卸载"
    return
  fi

  echo "停止并删除容器..."
  docker stop $CONTAINER_NAME 2>/dev/null
  docker rm $CONTAINER_NAME 2>/dev/null

  echo "删除 docker compose 项目目录..."
  rm -rf $APP_DIR

  echo "删除可能残留数据..."
  rm -rf /home/docker/chromium

  echo "（可选）是否删除镜像？(y/n)"
  read DELIMG

  if [ "$DELIMG" = "y" ]; then
    docker rmi lscr.io/linuxserver/chromium:latest 2>/dev/null
    echo "镜像已删除"
  fi

  echo "卸载完成"
}

menu() {
  while true; do
    echo "=============================="
    echo " Chromium Docker 管理工具"
    echo "=============================="
    echo "1) 安装"
    echo "2) 更新"
    echo "3) 备份"
    echo "4) 恢复"
    echo "9) 卸载（删除所有）"
    echo "0) 退出"
    echo "=============================="
    read -p "请选择: " num

    case $num in
      1) install ;;
      2) update ;;
      3) backup ;;
      4) restore ;;
      9) uninstall ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

menu
