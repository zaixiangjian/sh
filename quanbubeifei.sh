13)
  read -e -p "输入远程服务器IP: " useip
  read -e -p "输入远程服务器密码: " usepasswd

  mkdir -p /home/docker
  cd /home/docker || exit 1

  # ------------------ 下载原始脚本 ------------------
  wget -q -O quanbubeifei.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/quanbubeifei.sh
  chmod +x quanbubeifei.sh

  # 替换远程IP和密码
  sed -i "s/vpsip/$useip/g" quanbubeifei.sh
  sed -i "s/vps密码/$usepasswd/g" quanbubeifei.sh

  local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

  TMP_SCRIPT="/home/docker/quanbubeifei_tmp.sh"
  OBFUSCATED_SCRIPT="/home/docker/quanbubeifei_obf.sh"
  OUTPUT_BIN="/home/docker/quanbubeifei.x"
  BACKUP_DIRS="/home/博客 /home/图床 /home/密码 /home/论坛"
  BACKUP_OUTPUT="/home/quanbubeifei.x"

  # ------------------ 生成脚本 ------------------
  cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }

tar -czf "$BACKUP_OUTPUT" $BACKUP_DIRS
EOF

  cat quanbubeifei.sh >> "$TMP_SCRIPT"

  # ------------------ 混淆 ------------------
  bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
  sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"

  # ------------------ 编译成二进制 ------------------
  shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
  chmod +x "$OUTPUT_BIN"
  strip "$OUTPUT_BIN" >/dev/null 2>&1
  upx "$OUTPUT_BIN" >/dev/null 2>&1

  rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" quanbubeifei.sh

  echo "13 号程序已生成：$OUTPUT_BIN"
  echo "备份文件将保存到：$BACKUP_OUTPUT"

  # ------------------------ 定时任务 ------------------------
  echo "------------------------"
  echo "选择备份频率："
  echo "1. 每周备份"
  echo "2. 每天固定时间备份"
  echo "3. 每N天备份一次（精确到分钟）"
  read -e -p "请输入选择编号: " dingshi13

  LOCK_FILE="/tmp/quanbubeifei.lock"

  case $dingshi13 in
    1)
      read -e -p "选择每周备份的星期几 (0-6): " weekday
      read -e -p "几点（0-23）: " hour
      read -e -p "几分（0-59）: " minute
      (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
      echo "已设置每周星期${weekday} ${hour}:${minute} 备份"
      ;;
    2)
      read -e -p "每天几点（0-23）: " hour
      read -e -p "每天几分（0-59）: " minute
      (crontab -l 2>/dev/null; echo "$minute $hour * * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
      echo "已设置每天 ${hour}:${minute} 备份"
      ;;
    3)
      read -e -p "每几天一次: " interval
      read -e -p "几点（0-23）: " hour
      read -e -p "几分（0-59）: " minute
      (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
      echo "已设置每 ${interval} 天 ${hour}:${minute} 备份"
      ;;
    *)
      echo "无效选项，跳过定时任务。"
      ;;
  esac

  # ------------------ 开机启动 ------------------
  if crontab -l 2>/dev/null | grep -q "@reboot $OUTPUT_BIN"; then
      echo "开机自启已存在。"
  else
      (crontab -l 2>/dev/null; echo "@reboot nohup $OUTPUT_BIN >/dev/null 2>&1 &") | crontab -
      echo "已设置开机自动后台运行 $OUTPUT_BIN"
  fi

  # ------------------ 立即后台运行 ------------------
  nohup $OUTPUT_BIN >/dev/null 2>&1 &
  echo "13 号任务已立即开始执行..."

  ;;
