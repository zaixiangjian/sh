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
      echo "------------------------"
      echo "7. 恢复 Vaultwarden 数据备份"
      echo "8. Vaultwarden数据备份+自动监控文件变更备份传送"
      echo "9. 密码传送备份"
      echo "------------------------"
      echo "10. 图床备份"
      echo "------------------------"
      echo "11. 网盘传送"
      echo "12. 自定义目录传送修改/root/.zixuanmulu.conf目录文件"
      echo "13. 在github修改目录https://github.com/zaixiangjian/sh/blob/main/zixuanmulu2.sh"
      echo "------------------------"
      echo "14.外部网盘传送数据备份+自动监控文件变更备份传送"
      echo "15.网盘数据恢复"
      echo "------------------------"
      echo "98.V 论坛备份"
      echo "99.J 论坛备份"
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


          # 新增：选择间隔天数传送
          read -e -p "每几天传送一次（如：2 表示每2天）: " interval
          read -e -p "每天几点传送（0-23）: " chuan_hour
          read -e -p "每天几分传送（0-59）: " chuan_min

          if crontab -l 2>/dev/null | grep -q "$OUTPUT_BIN"; then
            echo "传送任务 $OUTPUT_BIN 已存在，跳过添加。"
          else
            # 如果用户设置了间隔天数，则使用类似 "*/N" 的格式
            if [[ -n "$interval" && "$interval" =~ ^[0-9]+$ ]]; then
              (crontab -l 2>/dev/null; echo "$chuan_min $chuan_hour */$interval * * $OUTPUT_BIN") | crontab -
              echo "已设置每${interval}天 ${chuan_hour}点${chuan_min}分进行传送"
            else
              (crontab -l 2>/dev/null; echo "$chuan_min $chuan_hour * * * $OUTPUT_BIN") | crontab -
              echo "已设置每天 ${chuan_hour}点${chuan_min}分自动传送"
            fi
          fi
          ;;





    7)
      echo "------------------------"
      echo "恢复 Vaultwarden 数据库备份..."
      
      # 停止 Vaultwarden 容器
      docker stop vaultwarden
      echo "Vaultwarden 已停止"

      # 列出 /home/密码 目录中的所有备份文件
      backup_dir="/home/密码"
      backups=$(ls -t $backup_dir/mima_*.tar.gz)

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

      # 重启 Vaultwarden 容器
      docker start vaultwarden
      echo "Vaultwarden 已重启"

      ;;





  8)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    mkdir -p /home/docker/vaultwarden
    cd /home/docker/vaultwarden || exit 1

    wget -q -O beifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/mimabeifen.sh
    chmod +x beifen.sh

    sed -i "s/vpsip/$useip/g" beifen.sh
    sed -i "s/vps密码/$usepasswd/g" beifen.sh

    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/docker/vaultwarden/beifen_tmp.sh"
    OBFUSCATED_SCRIPT="/home/docker/vaultwarden/beifen_obf.sh"
    OUTPUT_BIN="/home/docker/vaultwarden/beifen.x"

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
    cat > /home/docker/vaultwarden/jiankong.sh << 'EOF'
#!/bin/bash

# 设置监控的数据库文件
WATCH_FILES="/home/docker/vaultwarden/data/db.sqlite3 /home/docker/vaultwarden/data/db.sqlite3-shm /home/docker/vaultwarden/data/db.sqlite3-wal"

# 使用 inotifywait 监控数据库文件的变化
inotifywait -m -e modify,create,delete $WATCH_FILES |
while read path action file; do
    echo "Change detected in file: $file (Action: $action)"
    
    
    
    
    
    # 在文件变化时运行备份脚本
    /home/docker/vaultwarden/beifen.x
done
EOF

    chmod +x /home/docker/vaultwarden/jiankong.sh

    # 创建 systemd 服务文件
    cat > /etc/systemd/system/vaultwarden-watch.service << EOF
[Unit]
Description=Vaultwarden 数据库监控备份
After=network.target

[Service]
Type=simple
ExecStart=/home/docker/vaultwarden/jiankong.sh
Restart=always
User=root
WorkingDirectory=/home/docker/vaultwarden/

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















9)
    read -e -p "输入远程服务器IP: " useip
    read -e -p "输入远程服务器密码: " usepasswd

    mkdir -p /home/docker/vaultwarden
    cd /home/docker/vaultwarden || exit 1

    # 下载 mimachuansong.sh
    wget -q -O mimachuansong.sh https://raw.githubusercontent.com/zaixiangjian/sh/main/mimachuansong.sh
    chmod +x mimachuansong.sh

    # 替换远程服务器IP和密码
    sed -i "s/vpsip/$useip/g" mimachuansong.sh
    sed -i "s/vps密码/$usepasswd/g" mimachuansong.sh

    # 获取本地IP，用于限制执行
    local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

    TMP_SCRIPT="/home/docker/vaultwarden/mimachuansong_tmp.sh"
    OBFUSCATED_SCRIPT="/home/docker/vaultwarden/mimachuansong_obf.sh"
    OUTPUT_BIN="/home/docker/vaultwarden/mimachuansong.x"

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

    # ----------- Vaultwarden 监控服务安装启动 -------------
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

    # 创建 mimachuansong.sh 监控脚本
    cat > /home/docker/vaultwarden/mimachuansong.sh << 'EOF'
#!/bin/bash

# 设置监控的数据库文件
WATCH_FILES="/home/docker/vaultwarden/data/db.sqlite3 /home/docker/vaultwarden/data/db.sqlite3-shm /home/docker/vaultwarden/data/db.sqlite3-wal"
# 使用 inotifywait 监控数据库文件的变化
inotifywait -m -e modify,create,delete $WATCH_FILES |
while read path action file; do
    echo "Change detected in file: $file (Action: $action)"
    /home/docker/vaultwarden/mimachuansong.x
done
EOF

    chmod +x /home/docker/vaultwarden/mimachuansong.sh

    # 创建 systemd 服务文件，使用新名字避免冲突
    SERVICE_NAME="vaultwarden-mimachuansong.service"

    cat > /etc/systemd/system/$SERVICE_NAME << EOF
[Unit]
Description=Vaultwarden 数据库监控备份 (mimachuansong)
After=network.target

[Service]
Type=simple
ExecStart=/home/docker/vaultwarden/mimachuansong.sh
Restart=always
User=root
WorkingDirectory=/home/docker/vaultwarden/

[Install]
WantedBy=multi-user.target
EOF

    # 启用并启动服务
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl restart $SERVICE_NAME

    echo "Vaultwarden 监控服务已启动并设为开机自启，服务名: $SERVICE_NAME"
    systemctl status $SERVICE_NAME --no-pager
    ;;






































        10)
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





11)
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



        12)
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





        13)
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



14)
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



    15)
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






























































        *)
          echo "操作取消"
    ;;
esac









