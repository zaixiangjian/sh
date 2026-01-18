#!/bin/bash

# 自动化定时备份+传送脚本，适用于主脚本中 curl <zidongbeifen.sh> 直接调用
# 注意：本脚本应独立运行，不含 case/33) 标签或 menu 结构

      clear
      send_stats "定时远程备份+传送"

      echo "检查系统类型并安装依赖..."

      # 检查 curl
      if ! command -v curl > /dev/null 2>&1; then
        echo "curl 未安装，尝试安装..."
        if grep -qi "ubuntu\|debian" /etc/os-release; then
          apt-get update && apt-get install -y curl
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y curl
        fi
      else
        echo "curl 已安装，跳过"
      fi

# 检查 sshpass
if ! command -v sshpass > /dev/null 2>&1; then
    echo "sshpass 未安装，尝试安装..."
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update -y
        apt-get install -y sshpass
    elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y epel-release
        yum install -y sshpass
    else
        echo "不支持的系统，请手动安装 sshpass"
        exit 1
    fi
else
    echo "sshpass 已安装，跳过"
fi

      # 检查 shc
      if ! command -v shc > /dev/null 2>&1; then
        echo "shc 未安装，尝试安装..."
        if grep -qi "ubuntu\|debian" /etc/os-release; then
          apt-get update && apt-get install -y shc
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y shc
        fi
      else
        echo "shc 已安装，跳过"
      fi

# -----------------------------
# 检查 rsync
# -----------------------------
if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync 未安装，尝试安装..."
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update -y
        apt-get install -y rsync
    elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y rsync
    else
        echo "不支持的系统，请手动安装 rsync"
        exit 1
    fi
else
    echo "rsync 已安装，跳过"
fi

# -----------------------------
# 检查 ssh
# -----------------------------
if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh 未安装，尝试安装..."
    if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update -y
        apt-get install -y openssh-client
    elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y openssh-clients
    else
        echo "不支持的系统，请手动安装 ssh"
        exit 1
    fi
else
    echo "ssh 已安装，跳过"
fi





      # 检查 upx
      if ! command -v upx > /dev/null 2>&1; then
        echo "upx 未安装，尝试安装..."
        wget https://github.com/upx/upx/releases/download/v4.0.1/upx-4.0.1-amd64_linux.tar.xz -O /tmp/upx.tar.xz
        tar xf /tmp/upx.tar.xz -C /tmp
        cp /tmp/upx-4.0.1-amd64_linux/upx /usr/local/bin/
        chmod +x /usr/local/bin/upx
        rm -rf /tmp/upx.tar.xz /tmp/upx-4.0.1-amd64_linux
        echo "upx 安装完成"
      else
        echo "upx 已安装，跳过"
      fi

      # 检查 node 和 npm
      if ! command -v node > /dev/null 2>&1 || ! command -v npm > /dev/null 2>&1; then
        echo "node 或 npm 未安装，尝试安装..."
        if grep -qi "ubuntu\|debian" /etc/os-release; then
          apt-get update && apt-get install -y nodejs npm
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y nodejs npm
        fi
      else
        echo "node 和 npm 已安装，跳过"
      fi

      # 检查 bash-obfuscate
      if ! command -v bash-obfuscate > /dev/null 2>&1; then
        echo "bash-obfuscate 未安装，尝试安装..."
        npm install -g bash-obfuscate || echo "bash-obfuscate 安装失败，请手动安装"
      else
        echo "bash-obfuscate 已安装，跳过"
      fi

echo "当前已有定时任务："
echo "------------------------"

crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x|zidongtuchuang.x|wangpan.x|zixuanmulu.x" | nl | while read -r line; do
  num=$(echo "$line" | awk '{print $1}')
  content=$(echo "$line" | cut -d' ' -f2-)

  if echo "$content" | grep -q "beifen.x"; then
    echo "$num. 备份任务: $content"
  elif echo "$content" | grep -q "chuansong.x"; then
    echo "$num. 传送任务: $content"
  elif echo "$content" | grep -q "zidongtuchuang.x"; then
    echo "$num. 自动上传任务: $content"
  elif echo "$content" | grep -q "wangpan.x"; then
    echo "$num. 远程同步任务: $content"



    
  else
    echo "$num. 其他任务: $content"
  fi
done

      echo "------------------------"
      echo "1. 网站备份任务"
      echo "2. 网站传送任务"
      echo "------------------------"
      echo "3. 删除备份/传送任务"
      echo "4. 测试某个备份任务"
      echo "5. 测试某个传送任务"
      echo "------------------------"
      echo "6. 论坛传送任务"
      echo "7. 论坛传送任务1"
      echo "------------------------"
      echo "8. 恢复 Vaultwarden 数据备份"
      echo "9. Vaultwarden数据备份+自动监控文件变更备份传送"
      echo "10. 密码传送备份"
      echo "------------------------"
      echo "11. 图床备份"
      echo "------------------------"
      echo "12. 网盘传送自动监控变更传送"
      echo "13. 自定义目录传送修改/root/.zixuanmulu.conf目录文件"
      echo "14. 在github修改目录https://github.com/zaixiangjian/sh/blob/main/zixuanmulu2.sh"
      echo "------------------------"
      echo "15.外部网盘传送数据备份+自动监控文件变更备份传送"
      echo "16.网盘数据恢复"
      echo "17.S3对象存储minio传送每2分钟执行一次"
      echo "------------------------"
      echo "98.V 论坛备份"
      echo "99.J 论坛备份"
      echo "999. 论坛恢复检测/home目录解压到/var只需要kejilion.sh  11 72  2重建即可"
      echo "------------------------"
      echo "100.全部备份传送同步本地"
      echo "200.全部备份传送不删除远程文件"
      echo "------------------------"
      echo "使用100与200前先用远程连接一次更换为远程 IP "
      echo "ssh-keygen -f "/root/.ssh/known_hosts" -R "1.1.1.1""
      echo "------------------------"
      read -e -p "请选择操作编号: " action

      case $action in
        1)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          mkdir -p /home/web/beifen
          cd /home/web/beifen || exit 1

          wget -q -O beifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/beifen.sh
          chmod +x beifen.sh

          sed -i "s/vpsip/$useip/g" beifen.sh
          sed -i "s/vps密码/$usepasswd/g" beifen.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/web/beifen/beifen_tmp.sh"
          OBFUSCATED_SCRIPT="/home/web/beifen/beifen_obf.sh"
          OUTPUT_BIN="/home/web/beifen/beifen.x"

          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          cat beifen.sh >> "$TMP_SCRIPT"

          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" beifen.sh

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          read -e -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              read -e -p "几点备份（0-23）: " hour
              read -e -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              read -e -p "每天几点备份（0-23）: " hour
              read -e -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              read -e -p "每几天备份一次（如：2 表示每2天）: " interval
              read -e -p "几点（0-23）: " hour
              read -e -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
                echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
              fi
              ;;
            *)
              echo "无效输入"
              ;;
          esac
          ;;
        2)
          mkdir -p /home/web/beifen
          cd /home/web/beifen || exit 1

          wget -q -O chuansong.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/chuansong.sh
          chmod +x chuansong.sh

          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          sed -i "s/vpsip/$useip/g" chuansong.sh
          sed -i "s/vps密码/$usepasswd/g" chuansong.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/web/beifen/chuansong_tmp.sh"
          OBFUSCATED_SCRIPT="/home/web/beifen/chuansong_obf.sh"
          OUTPUT_BIN="/home/web/beifen/chuansong.x"

          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          cat chuansong.sh >> "$TMP_SCRIPT"

          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" chuansong.sh

          read -e -p "每天几点传送（0-23）: " chuan_hour
          read -e -p "每天几分传送（0-59）: " chuan_min

          if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
            echo "传送任务 $OUTPUT_BIN 已存在，跳过添加。"
          else
            (crontab -l 2>/dev/null; echo "$chuan_min $chuan_hour * * * $OUTPUT_BIN") | crontab -
            echo "已设置每天 ${chuan_hour}点${chuan_min}分 自动传送"
          fi
          ;;
        3)
          echo "------------------------"
          echo "当前定时任务如下："
          crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x|zidongtuchuang.x|wangpan.x|zixuanmulu.sh" | nl

          read -e -p "请输入要删除的任务编号: " del_num

          task_line=$(crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x|zidongtuchuang.x|wangpan.x|zixuanmulu.sh" | sed -n "${del_num}p")

          crontab -l 2>/dev/null | grep -v -E "beifen.x|chuansong.x|zidongtuchuang.x|wangpan.x|zixuanmulu.sh" > /tmp/tmp_cron
          crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x|zidongtuchuang.x|wangpan.x|zixuanmulu.sh" | sed "${del_num}d" >> /tmp/tmp_cron
          crontab /tmp/tmp_cron && rm -f /tmp/tmp_cron

          echo "已删除定时任务: $task_line"

          script_path=$(echo "$task_line" | awk '{for(i=1;i<=NF;i++){if($i ~ /\.x$/){print $i}}}')
          if [[ -n "$script_path" ]]; then
            echo "删除本地文件：$script_path"
            rm -f "$script_path"
            base="${script_path%.x}"
            rm -f "${base}_obf.sh.x.c" "${base}_tmp.sh" "${base}_obf.sh"
          fi
          ;;
        4)
          echo "------------------------"
          echo "当前可用备份任务如下："
          tasks=$(crontab -l 2>/dev/null | grep "beifen.x" | awk '{print $6}' | nl)
          echo "$tasks"

          read -e -p "请选择要测试的备份编号: " bnum
          selected=$(echo "$tasks" | sed -n "${bnum}p" | awk '{print $2}')

          if [[ -f "$selected" && -x "$selected" ]]; then
            echo "开始执行备份脚本：$selected"
            "$selected"
          else
            echo "备份脚本不可执行或不存在"
          fi
          ;;
        5)
          echo "------------------------"
          echo "当前可用传送任务如下："
          tasks=$(crontab -l 2>/dev/null | grep "chuansong.x" | awk '{print $6}' | nl)
          echo "$tasks"

          read -e -p "请选择要测试的传送编号: " tnum
          selected=$(echo "$tasks" | sed -n "${tnum}p" | awk '{print $2}')

          if [[ -f "$selected" && -x "$selected" ]]; then
            echo "开始执行传送脚本：$selected"
            bash "$selected"
          else
            echo "传送脚本不可执行或不存在"
          fi
          ;;


6)
    mkdir -p /home
    cd /home || exit 1

    wget -q -O luntanbeifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/luntanbeifen.sh
    chmod +x luntanbeifen.sh

    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    sed -i "s/vpsip/$useip/g" luntanbeifen.sh
    sed -i "s/vps密码/$usepasswd/g" luntanbeifen.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/luntanbeifen_tmp.sh"
    OBFUSCATED_SCRIPT="/home/luntanbeifen_obf.sh"
    OUTPUT_BIN="/home/luntanbeifen.x"

    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    cat luntanbeifen.sh >> "$TMP_SCRIPT"

    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" luntanbeifen.sh

    # 新增：选择每几分钟传送一次
    read -e -p "每几分钟传送一次（如：1 / 5 / 10）: " interval

    LOCK_FILE="/tmp/luntanbeifen.lock"

    if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
        echo "传送任务 $OUTPUT_BIN 已存在，跳过添加。"
    else
        # 使用用户输入的分钟间隔来设置定时任务
        if [[ -n "$interval" && "$interval" =~ ^[0-9]+$ ]]; then
            (crontab -l 2>/dev/null; echo "*/$interval * * * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
            echo "已设置每${interval}分钟执行一次传送任务"
        else
            echo "无效的间隔输入"
        fi
    fi
    ;;



7) 
    mkdir -p /home
    cd /home || exit 1

    wget -q -O luntanbeifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/luntanbeifen1.sh
    chmod +x luntanbeifen.sh

    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    sed -i "s/vpsip/$useip/g" luntanbeifen.sh
    sed -i "s/vps密码/$usepasswd/g" luntanbeifen.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/luntanbeifen_tmp.sh"
    OBFUSCATED_SCRIPT="/home/luntanbeifen_obf.sh"
    OUTPUT_BIN="/home/luntanbeifen.x"

    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    cat luntanbeifen.sh >> "$TMP_SCRIPT"

    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" luntanbeifen.sh

    # 新增：选择每几分钟传送一次
    read -e -p "每几分钟传送一次（如：1 / 5 / 10）: " interval

    LOCK_FILE="/tmp/luntanbeifen.lock"

    if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
        echo "传送任务 $OUTPUT_BIN 已存在，跳过添加。"
    else
        # 如果用户设置了分钟间隔，则使用 "*/N" 格式
        if [[ -n "$interval" && "$interval" =~ ^[0-9]+$ ]]; then
            (crontab -l 2>/dev/null; echo "*/$interval * * * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
            echo "已设置每${interval}分钟执行一次传送任务"
        else
            echo "无效的间隔输入"
        fi
    fi
    ;;


8)
  echo "------------------------"
  echo "恢复 Vaultwarden 数据库备份..."
  
  # 停止 Vaultwarden 容器
  docker stop vaultwarden
  echo "Vaultwarden 已停止"

  # 列出 /home/web/密码 目录中的所有备份文件
  backup_dir="/home/web/密码"
  backups=$(ls -t $backup_dir/mima_*.tar.gz 2>/dev/null)

  if [ -z "$backups" ]; then
    echo "没有找到备份文件，无法恢复！"
    exit 1
  fi

  echo "备份文件列表："
  echo "------------------------"
  i=1
  for backup in $backups; do
    echo "$i. $backup"
    i=$((i+1))
  done

  # 提示用户选择备份文件（默认为最新备份）
  read -e -p "请输入要恢复的备份编号（回车恢复最新）： " restore_choice

  if [ -z "$restore_choice" ]; then
    # 如果用户回车，则恢复最新备份
    restore_file=$(echo "$backups" | head -n 1)
  else
    # 否则恢复用户指定的备份
    restore_file=$(echo "$backups" | sed -n "${restore_choice}p")
  fi

  if [ -z "$restore_file" ]; then
    echo "无效的选择，恢复失败！"
    exit 1
  fi

  echo "正在恢复备份：$restore_file"

  # 解压备份文件到 /home/web/
  tar -xvzf "$restore_file" -C /home/web/

  # 检查解压是否成功
  if [ $? -eq 0 ]; then
    echo "备份恢复成功！"
  else
    echo "备份恢复失败！"
    exit 1
  fi

  # 重启 Vaultwarden 容器
  docker start vaultwarden
  echo "Vaultwarden 已重启"

  ;;

9)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    # 修改监控目录为 /home/web/vaultwarden
    mkdir -p /home/web/vaultwarden
    cd /home/web/vaultwarden || exit 1

    wget -q -O beifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/mimabeifen.sh
    chmod +x beifen.sh

    sed -i "s/vpsip/$useip/g" beifen.sh
    sed -i "s/vps密码/$usepasswd/g" beifen.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/web/vaultwarden/beifen_tmp.sh"
    OBFUSCATED_SCRIPT="/home/web/vaultwarden/beifen_obf.sh"
    OUTPUT_BIN="/home/web/vaultwarden/beifen.x"

    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    cat beifen.sh >> "$TMP_SCRIPT"

    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" beifen.sh

    echo "------------------------"
    echo "选择备份频率："
    echo "1. 每周备份"
    echo "2. 每天备份"
    echo "3. 每几天备份一次"
    read -e -p "请输入选择编号: " dingshi

    case $dingshi in
      1)
        read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
        read -e -p "几点备份（0-23）: " hour
        read -e -p "几分备份（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
          echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
        fi
        ;;
      2)
        read -e -p "每天几点备份（0-23）: " hour
        read -e -p "每天几分备份（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
          echo "已设置每天 ${hour}点${minute}分进行备份"
        fi
        ;;
      3)
        read -e -p "每几天备份一次（如：2 表示每2天）: " interval
        read -e -p "几点（0-23）: " hour
        read -e -p "几分（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
          echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
        fi
        ;;
      *)
        echo "无效输入"
        ;;
    esac

    # ----------- 新增：Vaultwarden 监控服务安装启动 -------------
    echo "开始安装 Vaultwarden 监控服务..."

    # 安装 inotify-tools
    if ! command -v inotifywait > /dev/null 2>&1; then
      echo "inotify-tools 未安装，尝试安装..."
      if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update && apt-get install -y inotify-tools
      elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y inotify-tools
      fi
    else
      echo "inotify-tools 已安装，跳过"
    fi

    # 创建 jiankong.sh 监控脚本
    cat > /home/web/vaultwarden/jiankong.sh << 'EOF'
#!/bin/bash

WATCH_DIR="/home/web/vaultwarden/data"
FILES="db.sqlite3 db.sqlite3-wal db.sqlite3-shm"
BIN="/home/web/vaultwarden/beifen.x"
LOCK_FILE="/tmp/mimabeifen.lock"
DELAY=5
INTERVAL=10   # 轮询兜底间隔秒

mkdir -p /tmp
[ ! -s "$LOCK_FILE" ] && echo "lock" > "$LOCK_FILE"

last_hash=""

trigger_backup() {
    (
        sleep $DELAY
        flock -n 200 || exit 0
        echo "执行备份..."
        "$BIN"
        echo "备份完成"
    ) 200>"$LOCK_FILE"
}

calc_hash() {
    sha1sum $(for f in $FILES; do echo "$WATCH_DIR/$f"; done 2>/dev/null) 2>/dev/null | sha1sum | awk '{print $1}'
}

inotifywait -m -e modify,create,delete,move "$WATCH_DIR" 2>/dev/null |
while read -r path action file; do
    case "$file" in
        db.sqlite3* )
            trigger_backup &
            ;;
    esac
done &

while true; do
    new_hash=$(calc_hash)
    if [ -n "$new_hash" ] && [ "$new_hash" != "$last_hash" ]; then
        echo "轮询检测到变化"
        last_hash="$new_hash"
        trigger_backup &
    fi
    sleep $INTERVAL
done
EOF
    chmod +x /home/web/vaultwarden/jiankong.sh

    # 创建 systemd 服务文件
    cat > /etc/systemd/system/vaultwarden-watch.service << EOF
[Unit]
Description=Vaultwarden 数据库监控备份
After=network.target

[Service]
Type=simple
ExecStart=/home/web/vaultwarden/jiankong.sh
Restart=always
User=root
WorkingDirectory=/home/web/vaultwarden/

[Install]
WantedBy=multi-user.target
EOF

    # 启用并启动服务
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable vaultwarden-watch
    systemctl restart vaultwarden-watch

    echo "Vaultwarden 监控服务已启动并设为开机自启。"
    systemctl status vaultwarden-watch --no-pager
    ;;

10)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    # 修改目录为 /home/web/vaultwarden
    mkdir -p /home/web/vaultwarden
    cd /home/web/vaultwarden || exit 1

    # 下载 mimachuansong.sh
    wget -q -O mimachuansong.sh https://raw.githubusercontent.com/zaixiangjian/sh/main/mimachuansong.sh
    chmod +x mimachuansong.sh

    # 替换远程服务器IP和密码
    sed -i "s/vpsip/$useip/g" mimachuansong.sh
    sed -i "s/vps密码/$usepasswd/g" mimachuansong.sh

    # 获取本地IP，用于限制执行
    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/web/vaultwarden/mimachuansong_tmp.sh"
    OBFUSCATED_SCRIPT="/home/web/vaultwarden/mimachuansong_obf.sh"
    OUTPUT_BIN="/home/web/vaultwarden/mimachuansong.x"

    # 添加IP限制
    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    cat mimachuansong.sh >> "$TMP_SCRIPT"

    # 混淆和编译为可执行文件
    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" mimachuansong.sh

    echo "------------------------"
    echo "选择备份频率："
    echo "1. 每周备份"
    echo "2. 每天备份"
    echo "3. 每几天备份一次"
    read -e -p "请输入选择编号: " dingshi

    case $dingshi in
      1)
        read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
        read -e -p "几点备份（0-23）: " hour
        read -e -p "几分（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务已存在，跳过添加"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
        fi
        ;;
      2)
        read -e -p "每天几点备份（0-23）: " hour
        read -e -p "每天几分备份（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务已存在，跳过添加"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
        fi
        ;;
      3)
        read -e -p "每几天备份一次: " interval
        read -e -p "几点（0-23）: " hour
        read -e -p "几分（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务已存在，跳过添加"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
        fi
        ;;
    esac

    echo "开始安装目录监控传送服务..."

    if ! command -v inotifywait >/dev/null 2>&1; then
      if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update && apt-get install -y inotify-tools
      elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y inotify-tools
      fi
    fi

    # 创建监控脚本（防重复执行 + 防死锁）
    cat > /home/web/vaultwarden/mimajiankongchuansong.sh << 'EOF'
#!/bin/bash

WATCH_DIR="/home/web/vaultwarden"
BIN="/home/web/vaultwarden/mimachuansong.x"
LOCK_FILE="/tmp/mimachuansong.lock"

[ -d "$WATCH_DIR" ] || exit 1

cleanup() {
  rm -f "$LOCK_FILE"
}
trap cleanup EXIT INT TERM

inotifywait -m -r -e modify,create,delete,move "$WATCH_DIR" |
while read path action file; do
    (
      flock -n 200 || exit 0
      "$BIN"
    ) 200>"$LOCK_FILE"
done
EOF

    chmod +x /home/web/vaultwarden/mimajiankongchuansong.sh

    SERVICE_NAME="vaultwarden-mimajiankongchuansong.service"

    cat > /etc/systemd/system/$SERVICE_NAME << EOF
[Unit]
Description=目录监控传送服务
After=network.target

[Service]
Type=simple
ExecStart=/home/web/vaultwarden/mimajiankongchuansong.sh
Restart=always
RestartSec=5
User=root
WorkingDirectory=/home/web/vaultwarden

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME

    systemctl status $SERVICE_NAME --no-pager
    ;;




        11)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          mkdir -p /home/web/beifen
          cd /home/web/beifen || exit 1

          wget -q -O beifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/zidongtuchuang.sh
          chmod +x beifen.sh

          sed -i "s/vpsip/$useip/g" beifen.sh
          sed -i "s/vps密码/$usepasswd/g" beifen.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/web/beifen/beifen_tmp.sh"
          OBFUSCATED_SCRIPT="/home/web/beifen/beifen_obf.sh"
          OUTPUT_BIN="/home/web/beifen/beifen.x"

          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          cat beifen.sh >> "$TMP_SCRIPT"

          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" beifen.sh

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          read -e -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              read -e -p "几点备份（0-23）: " hour
              read -e -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              read -e -p "每天几点备份（0-23）: " hour
              read -e -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              read -e -p "每几天备份一次（如：2 表示每2天）: " interval
              read -e -p "几点（0-23）: " hour
              read -e -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
                echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
              fi
              ;;
            *)
              echo "无效输入"
              ;;
          esac
          ;;


12)
  read -e -p "输入远程服务器IP: " useip
  read -e -p "输入远程服务器密码: " usepasswd

  mkdir -p /home/docker
  cd /home/docker || exit 1

  wget -q -O wangpan.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/wangpan.sh
  chmod +x wangpan.sh

  sed -i "s/vpsip/$useip/g" wangpan.sh
  sed -i "s/vps密码/$usepasswd/g" wangpan.sh

  local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

  TMP_SCRIPT="/home/docker/wangpan_tmp.sh"
  OBFUSCATED_SCRIPT="/home/docker/wangpan_obf.sh"
  OUTPUT_BIN="/home/docker/wangpan.x"

  cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

  cat wangpan.sh >> "$TMP_SCRIPT"

  bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
  sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
  shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
  chmod +x "$OUTPUT_BIN"
  strip "$OUTPUT_BIN" >/dev/null 2>&1
  upx "$OUTPUT_BIN" >/dev/null 2>&1

  rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" wangpan.sh

  echo "------------------------"
  echo "选择备份频率："
  echo "1. 每周备份"
  echo "2. 每天固定时间备份"
  echo "3. 每N天备份一次（精确到分钟）"
  read -e -p "请输入选择编号: " dingshi

  LOCK_FILE="/tmp/wangpan.lock"  # flock 锁文件

  # ------------------ 定时任务 ------------------
  case $dingshi in
    1)
      read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
      read -e -p "几点备份（0-23）: " hour
      read -e -p "几分备份（0-59）: " minute
      if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
        echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
      else
        (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
        echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
      fi
      ;;
    2)
      read -e -p "每天几点备份（0-23）: " hour
      read -e -p "每天几分备份（0-59）: " minute
      if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
        echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
      else
        (crontab -l 2>/dev/null; echo "$minute $hour * * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
        echo "已设置每天 ${hour}点${minute}分进行备份"
      fi
      ;;
    3)
      read -e -p "每几天备份一次（如：2 表示每2天）: " interval
      read -e -p "几点（0-23）: " hour
      read -e -p "几分（0-59）: " minute
      if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
        echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
      else
        (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -
        echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
      fi
      ;;
    *)
      echo "无效输入"
      ;;
  esac

# ------------------ 开机后台运行 ------------------
if crontab -l 2>/dev/null | grep -q "@reboot /home/docker/wangpan.x"; then
    echo "开机自启任务已存在，跳过添加。"
else
    (crontab -l 2>/dev/null; echo "@reboot nohup /home/docker/wangpan.x >/dev/null 2>&1 &") | crontab -
    echo "已设置开机自动后台运行 /home/docker/wangpan.x"
fi

# ------------------ 立即后台运行一次 ------------------
nohup /home/docker/wangpan.x >/dev/null 2>&1 &

  ;;



        13)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          mkdir -p /home/docker
          cd /home/docker || exit 1

          wget -q -O zixuanmulu.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/zixuanmulu.sh
          chmod +x zixuanmulu.sh

          sed -i "s/vpsip/$useip/g" zixuanmulu.sh
          sed -i "s/vps密码/$usepasswd/g" zixuanmulu.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/docker/zixuanmulu_tmp.sh"
          OBFUSCATED_SCRIPT="/home/docker/zixuanmulu_obf.sh"
          OUTPUT_BIN="/home/docker/zixuanmulu.x"

          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          cat zixuanmulu.sh >> "$TMP_SCRIPT"

          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" zixuanmulu.sh

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          read -e -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              read -e -p "几点备份（0-23）: " hour
              read -e -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              read -e -p "每天几点备份（0-23）: " hour
              read -e -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              read -e -p "每几天备份一次（如：2 表示每2天）: " interval
              read -e -p "几点（0-23）: " hour
              read -e -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
                echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
              fi
              ;;
            *)
              echo "无效输入"
              ;;
          esac
          ;;





        14)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          mkdir -p /home/docker
          cd /home/docker || exit 1

          wget -q -O zixuanmulu2.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/zixuanmulu2.sh
          chmod +x zixuanmulu2.sh

          sed -i "s/vpsip/$useip/g" zixuanmulu2.sh
          sed -i "s/vps密码/$usepasswd/g" zixuanmulu2.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/docker/zixuanmulu2_tmp.sh"
          OBFUSCATED_SCRIPT="/home/docker/zixuanmulu2_obf.sh"
          OUTPUT_BIN="/home/docker/zixuanmulu2.x"

          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          cat zixuanmulu2.sh >> "$TMP_SCRIPT"

          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" zixuanmulu2.sh

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          read -e -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              read -e -p "几点备份（0-23）: " hour
              read -e -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              read -e -p "每天几点备份（0-23）: " hour
              read -e -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              read -e -p "每几天备份一次（如：2 表示每2天）: " interval
              read -e -p "几点（0-23）: " hour
              read -e -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
                echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
              fi
              ;;
            *)
              echo "无效输入"
              ;;
          esac
          ;;



15)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    mkdir -p /home/docker/wangpan
    cd /home/docker/wangpan || exit 1

    wget -q -O waibucunchu.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/waibucunchu.sh
    chmod +x waibucunchu.sh

    sed -i "s/vpsip/$useip/g" waibucunchu.sh
    sed -i "s/vps密码/$usepasswd/g" waibucunchu.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/docker/wangpan/waibucunchu_tmp.sh"
    OBFUSCATED_SCRIPT="/home/docker/wangpan/waibucunchu_obf.sh"
    OUTPUT_BIN="/home/docker/wangpan/waibucunchu.x"

    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    cat waibucunchu.sh >> "$TMP_SCRIPT"

    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" waibucunchu.sh

    echo "------------------------"
    echo "选择备份频率："
    echo "1. 每周备份"
    echo "2. 每天备份"
    echo "3. 每几天备份一次"
    read -e -p "请输入选择编号: " dingshi

    case $dingshi in
      1)
        read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
        read -e -p "几点备份（0-23）: " hour
        read -e -p "几分备份（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
          echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
        fi
        ;;
      2)
        read -e -p "每天几点备份（0-23）: " hour
        read -e -p "每天几分备份（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
          echo "已设置每天 ${hour}点${minute}分进行备份"
        fi
        ;;
      3)
        read -e -p "每几天备份一次（如：2 表示每2天）: " interval
        read -e -p "几点（0-23）: " hour
        read -e -p "几分（0-59）: " minute
        if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
          echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
        else
          (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
          echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
        fi
        ;;
      *)
        echo "无效输入"
        ;;
    esac

    echo "开始安装 Cloudreve 监控服务..."

    if ! command -v inotifywait > /dev/null 2>&1; then
      echo "inotify-tools 未安装，尝试安装..."
      if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update && apt-get install -y inotify-tools
      elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y inotify-tools
      fi
    else
      echo "inotify-tools 已安装，跳过"
    fi

    cat > /home/docker/wangpan/jiankongwangpan.sh << 'EOF'
#!/bin/bash

WATCH_FILES="/home/docker/wangpan/cloudreve/data/cloudreve.db"

inotifywait -m -e modify,create,delete $WATCH_FILES |
while read path action file; do
    echo "Change detected in file: $file (Action: $action)"
    /home/docker/wangpan/waibucunchu.x
done
EOF

    chmod +x /home/docker/wangpan/jiankongwangpan.sh

    cat > /etc/systemd/system/cloudreve-watch.service << EOF
[Unit]
Description=Cloudreve 数据库监控备份
After=network.target

[Service]
Type=simple
ExecStart=/home/docker/wangpan/jiankongwangpan.sh
Restart=always
User=root
WorkingDirectory=/home/docker/wangpan/

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable cloudreve-watch
    systemctl restart cloudreve-watch

    echo "Cloudreve 监控服务已启动并设为开机自启。"
    systemctl status cloudreve-watch --no-pager
    ;;



    16)
      echo "------------------------"
      echo "恢复 cloudreve 数据库备份..."
      
      # 停止 cloudreve 容器
      docker stop cloudreve
      echo "cloudreve 已停止"

      # 列出 /home/密码 目录中的所有备份文件
      backup_dir="/home/网盘"
      backups=$(ls -t $backup_dir/wangpan_*.tar.gz)

      if [ -z "$backups" ]; then
        echo "没有找到备份文件，无法恢复！"
        exit 1
      fi

      echo "备份文件列表："
      echo "------------------------"
      i=1
      for backup in $backups; do
        echo "$i. $backup"
        i=$((i+1))
      done

      # 提示用户选择备份文件（默认为最新备份）
      read -e -p "请输入要恢复的备份编号（回车恢复最新）： " restore_choice

      if [ -z "$restore_choice" ]; then
        # 如果用户回车，则恢复最新备份
        restore_file=$(echo "$backups" | head -n 1)
      else
        # 否则恢复用户指定的备份
        restore_file=$(echo "$backups" | sed -n "${restore_choice}p")
      fi

      if [ -z "$restore_file" ]; then
        echo "无效的选择，恢复失败！"
        exit 1
      fi

      echo "正在恢复备份：$restore_file"

      # 解压备份文件
      tar -xvzf "$restore_file" -C /home/docker

      # 检查解压是否成功
      if [ $? -eq 0 ]; then
        echo "备份恢复成功！"
      else
        echo "备份恢复失败！"
        exit 1
      fi

      # 重启 cloudreve 容器
      docker start cloudreve
      echo "cloudreve 已重启"

      ;;


17)
  read -e -p "输入远程服务器IP: " useip
  read -e -p "输入远程服务器密码: " usepasswd

  # 创建并进入目录
  mkdir -p /home/docker
  cd /home/docker || exit 1

  # 下载脚本
  wget -q -O miniochuansong.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/miniochuansong.sh
  chmod +x miniochuansong.sh

  # 替换变量
  sed -i "s/vpsip/$useip/g" miniochuansong.sh
  sed -i "s/vps密码/$usepasswd/g" miniochuansong.sh

  # 获取本机 IP
  local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

  TMP_SCRIPT="/home/docker/beifen_tmp.sh"
  OBFUSCATED_SCRIPT="/home/docker/beifen_obf.sh"
  OUTPUT_BIN="/home/docker/miniochuansong.x"

  # 写入 IP 校验
  cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || exit 1
EOF

  # 拼接真实逻辑
  cat miniochuansong.sh >> "$TMP_SCRIPT"

  # 混淆 + 编译
  bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
  sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
  shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
  chmod +x "$OUTPUT_BIN"
  strip "$OUTPUT_BIN" >/dev/null 2>&1
  upx "$OUTPUT_BIN" >/dev/null 2>&1

  # 清理
  rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" miniochuansong.sh

  echo "------------------------"
  read -e -p "每几分钟运行一次（如 2）： " interval
  [ "$interval" -lt 1 ] && interval=1

  CRON_CMD="*/$interval * * * * flock -n /tmp/miniochuansong.lock $OUTPUT_BIN"

  if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
    echo "任务已存在，跳过添加"
  else
    (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
    echo "已设置：每 $interval 分钟运行（自动防重复执行）"
  fi
  ;;















        98)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          # 创建并进入备份目录
          mkdir -p /home/论坛备份
          cd /home/论坛备份 || exit 1

          # 下载备份脚本（统一文件名）
          wget -q -O discoursebeifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/discoursebeifenv.sh
          chmod +x discoursebeifen.sh

          # 替换变量
          sed -i "s/vpsip/$useip/g" discoursebeifen.sh
          sed -i "s/vps密码/$usepasswd/g" discoursebeifen.sh

          # 获取本机 IP（用于限制执行）
          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/论坛备份/beifen_tmp.sh"
          OBFUSCATED_SCRIPT="/home/论坛备份/beifen_obf.sh"
          OUTPUT_BIN="/home/论坛备份/discoursebeifen.x"

          # 写入 IP 校验头
          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          # 拼接真实备份逻辑
          cat discoursebeifen.sh >> "$TMP_SCRIPT"

          # 混淆 + 编译
          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          # 清理中间文件
          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" discoursebeifen.sh

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          read -e -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              read -e -p "几点备份（0-23）: " hour
              read -e -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              read -e -p "每天几点备份（0-23）: " hour
              read -e -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              read -e -p "每几天备份一次（如：2 表示每2天）: " interval
              read -e -p "几点（0-23）: " hour
              read -e -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
                echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
              fi
              ;;
            *)
              echo "无效输入"
              ;;
          esac
          ;;



        99)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          # 创建并进入备份目录
          mkdir -p /home/论坛备份
          cd /home/论坛备份 || exit 1

          # 下载备份脚本（统一文件名）
          wget -q -O discoursebeifen1.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/discoursebeifenj.sh
          chmod +x discoursebeifen1.sh

          # 替换变量
          sed -i "s/vpsip/$useip/g" discoursebeifen1.sh
          sed -i "s/vps密码/$usepasswd/g" discoursebeifen1.sh

          # 获取本机 IP（用于限制执行）
          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/home/论坛备份/beifen_tmp.sh"
          OBFUSCATED_SCRIPT="/home/论坛备份/beifen_obf.sh"
          OUTPUT_BIN="/home/论坛备份/discoursebeifen1.x"

          # 写入 IP 校验头
          cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

          # 拼接真实备份逻辑
          cat discoursebeifen1.sh >> "$TMP_SCRIPT"

          # 混淆 + 编译
          bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
          sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
          shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
          chmod +x "$OUTPUT_BIN"
          strip "$OUTPUT_BIN" >/dev/null 2>&1
          upx "$OUTPUT_BIN" >/dev/null 2>&1

          # 清理中间文件
          rm -f "$TMP_SCRIPT" "$OBFUSCATED_SCRIPT" discoursebeifen1.sh

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          read -e -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              read -e -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              read -e -p "几点备份（0-23）: " hour
              read -e -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              read -e -p "每天几点备份（0-23）: " hour
              read -e -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              read -e -p "每几天备份一次（如：2 表示每2天）: " interval
              read -e -p "几点（0-23）: " hour
              read -e -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour */$interval * * $OUTPUT_BIN") | crontab -
                echo "已设置每${interval}天 ${hour}点${minute}分实施备份"
              fi
              ;;
            *)
              echo "无效输入"
              ;;
          esac
          ;;


999)
    echo "------------------------"
    echo "检查并解压 .tar.gz 文件..."

    # 设置待检测的目录和解压目标目录
    home_dir="/home"
    dest_dir="/var"

    # 查找 home 目录下的所有 .tar.gz 文件
    tar_files=$(ls -t $home_dir/*.tar.gz)

    # 如果没有找到任何备份文件
    if [ -z "$tar_files" ]; then
        echo "没有找到 .tar.gz 文件，无法解压！"
        exit 1
    fi

    echo "备份文件列表："
    echo "------------------------"
    i=1
    for file in $tar_files; do
        echo "$i. $file"
        i=$((i+1))
    done

    # 提示用户选择备份文件（默认为最新备份）
    read -e -p "请输入要解压的备份编号（回车解压最新）： " restore_choice

    if [ -z "$restore_choice" ]; then
        # 如果用户回车，则解压最新的文件
        restore_file=$(echo "$tar_files" | head -n 1 | xargs basename)
    else
        # 否则恢复用户指定的备份
        restore_file=$(echo "$tar_files" | sed -n "${restore_choice}p" | xargs basename)
    fi

    if [ -z "$restore_file" ]; then
        echo "无效的选择，解压失败！"
        exit 1
    fi

    echo "正在解压备份：$restore_file"

    # 解压文件到 /var 目录
    tar -xvzf "$home_dir/$restore_file" -C $dest_dir

    # 检查解压是否成功
    if [ $? -eq 0 ]; then
        echo "文件解压成功！"
    else
        echo "文件解压失败！"
        exit 1
    fi
    ;;




  100)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    mkdir -p /home/quanbubeifen_build
    cd /home/quanbubeifen_build || exit 1

    wget -q -O quanbubeifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/quanbubeifen.sh
    chmod +x quanbubeifen.sh

    sed -i "s/vpsip/$useip/g" quanbubeifen.sh
    sed -i "s/vps密码/$usepasswd/g" quanbubeifen.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/quanbubeifen_build/tmp.sh"
    OBFUSCATED_SCRIPT="/home/quanbubeifen_build/obf.sh"
    OUTPUT_BIN="/home/quanbubeifen.x"

    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    cat quanbubeifen.sh >> "$TMP_SCRIPT"

    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -rf /home/quanbubeifen_build

    # -------- 定时任务：每几分钟运行一次（防重复） --------

    echo "------------------------"
    read -e -p "每几分钟运行一次（如 1 / 5 / 10）: " interval

    LOCK_FILE="/tmp/quanbubeifen.lock"

    (crontab -l 2>/dev/null | grep -v "$OUTPUT_BIN"; \
     echo "*/$interval * * * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -

    # -------- 目录变更即时监控 --------

    if ! command -v inotifywait >/dev/null 2>&1; then
      if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update && apt-get install -y inotify-tools
      elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y inotify-tools
      fi
    fi

# 创建监控脚本（最终位置）
cat > /home/jiankong.sh << 'EOF'
#!/bin/bash

WATCH_DIR="/home/密码"

echo "[$(date)] 监控启动" >> "$LOG_FILE"

inotifywait -m \
  -e close_write,create,move \
  --format '%e %f' \
  "$WATCH_DIR" | while read event file; do


    # 防止频繁触发
    sleep 2

    /home/quanbubeifen.x
    /home/quanbubeifen2.x
done
EOF

chmod +x /home/jiankong.sh

# systemd 服务
cat > /etc/systemd/system/quanbubeifen-watch.service << EOF
[Unit]
Description=目录监控即时传送 (/home/密码)
After=network.target

[Service]
ExecStart=/home/jiankong.sh
Restart=always
User=root
WorkingDirectory=/root
StandardOutput=journal
StandardError=journal
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable quanbubeifen-watch
systemctl restart quanbubeifen-watch

echo "--------------------------------"
echo "✔ 执行文件：/home/quanbubeifen.x"
echo "✔ 监控脚本：/home/jiankong.sh"
echo "✔ 监控目录：/home/密码"
echo "✔ 定时任务：每 $interval 分钟（防重复）"
echo "✔ 变更即刻传送"
    ;;



200)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    mkdir -p /home/quanbubeifen_build
    cd /home/quanbubeifen_build || exit 1

    # 下载远程脚本并保存为本地文件
    wget -q -O quanbubeifen2.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/quanbubeifen2.sh
    chmod +x quanbubeifen2.sh

    # 替换远程 IP 和密码
    sed -i "s/vpsip/$useip/g" quanbubeifen2.sh
    sed -i "s/vps密码/$usepasswd/g" quanbubeifen2.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/quanbubeifen_build/tmp.sh"
    OBFUSCATED_SCRIPT="/home/quanbubeifen_build/obf.sh"
    OUTPUT_BIN="/home/quanbubeifen2.x"   # 修改本地生成执行文件名

    cat > "$TMP_SCRIPT" <<EOF
#!/bin/bash
IP=\$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')
[[ "\$IP" == "$local_ip" ]] || { echo "IP not allowed: \$IP"; exit 1; }
EOF

    # 这里必须改为下载的最新文件名
    cat quanbubeifen2.sh >> "$TMP_SCRIPT"

    bash-obfuscate "$TMP_SCRIPT" -o "$OBFUSCATED_SCRIPT"
    sed -i '1s|^|#!/bin/bash\n|' "$OBFUSCATED_SCRIPT"
    shc -r -f "$OBFUSCATED_SCRIPT" -o "$OUTPUT_BIN"
    chmod +x "$OUTPUT_BIN"
    strip "$OUTPUT_BIN" >/dev/null 2>&1
    upx "$OUTPUT_BIN" >/dev/null 2>&1

    rm -rf /home/quanbubeifen_build

    # -------- 定时任务：每几分钟运行一次（防重复） --------

    echo "------------------------"
    read -e -p "每几分钟运行一次（如 1 / 5 / 10）: " interval

    LOCK_FILE="/tmp/quanbubeifen.lock"

    (crontab -l 2>/dev/null | grep -v "$OUTPUT_BIN"; \
     echo "*/$interval * * * * flock -n $LOCK_FILE $OUTPUT_BIN") | crontab -

    # -------- 目录变更即时监控 --------

    if ! command -v inotifywait >/dev/null 2>&1; then
      if grep -qi "ubuntu\|debian" /etc/os-release; then
        apt-get update && apt-get install -y inotify-tools
      elif grep -qi "centos\|redhat" /etc/os-release; then
        yum install -y inotify-tools
      fi
    fi

# 创建监控脚本（最终位置）
cat > /home/jiankong.sh << 'EOF'
#!/bin/bash

WATCH_DIR="/home/密码"

echo "[$(date)] 监控启动" >> "$LOG_FILE"

inotifywait -m \
  -e close_write,create,move \
  --format '%e %f' \
  "$WATCH_DIR" | while read event file; do


    # 防止频繁触发
    sleep 2

    /home/quanbubeifen.x
    /home/quanbubeifen2.x
done
EOF

    chmod +x /home/jiankong.sh

# systemd 服务
cat > /etc/systemd/system/quanbubeifen-watch.service << EOF
[Unit]
Description=目录监控即时传送 (/home/密码)
After=network.target

[Service]
ExecStart=/home/jiankong.sh
Restart=always
User=root
WorkingDirectory=/root
StandardOutput=journal
StandardError=journal
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable quanbubeifen-watch
    systemctl restart quanbubeifen-watch

    echo "--------------------------------"
    echo "✔ 执行文件：/home/quanbubeifen2.x"
    echo "✔ 监控脚本：/home/jiankong.sh"
    echo "✔ 监控目录：/home/密码"
    echo "✔ 定时任务：每 $interval 分钟（防重复）"
    echo "✔ 变更即刻传送"
    ;;





















































        *)
          echo "操作取消"
    ;;
esac









