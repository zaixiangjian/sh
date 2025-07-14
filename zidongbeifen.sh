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
          apt-get update && apt-get install -y sshpass
        elif grep -qi "centos\|redhat" /etc/os-release; then
          yum install -y sshpass
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

      crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x" | nl | while read -r line; do
        num=$(echo "$line" | awk '{print $1}')
        content=$(echo "$line" | cut -d' ' -f2-)
        if echo "$content" | grep -q "beifen.x"; then
          echo "$num. 备份任务: $content"
        elif echo "$content" | grep -q "chuansong.x"; then
          echo "$num. 传送任务: $content"
        fi
      done

      echo "------------------------"
      echo "1. 添加备份任务"
      echo "2. 添加传送任务"
      echo "3. 删除备份/传送任务"
      echo "4. 测试某个备份任务"
      echo "5. 测试某个传送任务"
      read -e -p "请选择操作编号: " action

      case $action in
        1)
          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          mkdir -p /root/beifen
          cd /root/beifen || exit 1

          wget -q -O beifen.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/beifen.sh
          chmod +x beifen.sh

          sed -i "s/vpsip/$useip/g" beifen.sh
          sed -i "s/vps密码/$usepasswd/g" beifen.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/root/beifen/beifen_tmp.sh"
          OBFUSCATED_SCRIPT="/root/beifen/beifen_obf.sh"
          OUTPUT_BIN="/root/beifen/beifen.x"

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
          mkdir -p /root/beifen
          cd /root/beifen || exit 1

          wget -q -O chuansong.sh ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/chuansong.sh
          chmod +x chuansong.sh

          read -e -p "输入远程服务器IP: " useip
          read -e -p "输入远程服务器密码: " usepasswd

          sed -i "s/vpsip/$useip/g" chuansong.sh
          sed -i "s/vps密码/$usepasswd/g" chuansong.sh

          local_ip=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || echo '0.0.0.0')

          TMP_SCRIPT="/root/beifen/chuansong_tmp.sh"
          OBFUSCATED_SCRIPT="/root/beifen/chuansong_obf.sh"
          OUTPUT_BIN="/root/beifen/chuansong.x"

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
          crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x" | nl

          read -e -p "请输入要删除的任务编号: " del_num

          task_line=$(crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x" | sed -n "${del_num}p")

          crontab -l 2>/dev/null | grep -v -E "beifen.x|chuansong.x" > /tmp/tmp_cron
          crontab -l 2>/dev/null | grep -E "beifen.x|chuansong.x" | sed "${del_num}d" >> /tmp/tmp_cron
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
        *)
          echo "操作取消"
          ;;
      esac

      ;;


	34)
	  root_use
	  send_stats "LDNMP环境还原"
	  echo "可用的站点备份"
	  echo "-------------------------"
	  ls -lt /home/*.gz | awk '{print $NF}'
	  echo ""
	  read -e -p  "回车键还原最新的备份，输入备份文件名还原指定的备份，输入0退出：" filename

	  if [ "$filename" == "0" ]; then
		  break_end
		  linux_ldnmp
	  fi

	  # 如果用户没有输入文件名，使用最新的压缩包
	  if [ -z "$filename" ]; then
		  filename=$(ls -t /home/*.tar.gz | head -1)
	  fi

	  if [ -n "$filename" ]; then
		  cd /home/web/ > /dev/null 2>&1
		  docker compose down > /dev/null 2>&1
		  rm -rf /home/web > /dev/null 2>&1

		  echo -e "${gl_huang}正在解压 $filename ...${gl_bai}"
		  cd /home/ && tar -xzf "$filename"

		  check_port
		  install_dependency
		  install_docker
		  install_certbot
		  install_ldnmp
	  else
		  echo "没有找到压缩包。"
	  fi

	  ;;

	35)
	  send_stats "LDNMP环境防御"
	  while true; do
		if docker inspect fail2ban &>/dev/null ; then

			  clear
			  echo "服务器防御程序已启动"
			  echo "------------------------"
			  echo "1. 开启SSH防暴力破解              2. 关闭SSH防暴力破解"
			  echo "3. 开启网站保护                   4. 关闭网站保护"
			  echo "------------------------"
			  echo "5. 查看SSH拦截记录                6. 查看网站拦截记录"
			  echo "7. 查看防御规则列表               8. 查看日志实时监控"
			  echo "------------------------"
			  echo "11. 配置拦截参数"
			  echo "------------------------"
			  echo "21. cloudflare模式                22. 高负载开启5秒盾"
			  echo "------------------------"
			  echo "9. 卸载防御程序"
			  echo "------------------------"
			  echo "0. 退出"
			  echo "------------------------"
			  read -e -p "请输入你的选择: " sub_choice
			  case $sub_choice in
				  1)
					  sed -i 's/false/true/g' /path/to/fail2ban/config/fail2ban/jail.d/alpine-ssh.conf
					  sed -i 's/false/true/g' /path/to/fail2ban/config/fail2ban/jail.d/linux-ssh.conf
					  sed -i 's/false/true/g' /path/to/fail2ban/config/fail2ban/jail.d/centos-ssh.conf
					  f2b_status
					  ;;
				  2)
					  sed -i 's/true/false/g' /path/to/fail2ban/config/fail2ban/jail.d/alpine-ssh.conf
					  sed -i 's/true/false/g' /path/to/fail2ban/config/fail2ban/jail.d/linux-ssh.conf
					  sed -i 's/true/false/g' /path/to/fail2ban/config/fail2ban/jail.d/centos-ssh.conf
					  f2b_status
					  ;;
				  3)
					  sed -i 's/false/true/g' /path/to/fail2ban/config/fail2ban/jail.d/nginx-docker-cc.conf
					  f2b_status
					  ;;
				  4)
					  sed -i 's/true/false/g' /path/to/fail2ban/config/fail2ban/jail.d/nginx-docker-cc.conf
					  f2b_status
					  ;;
				  5)
					  echo "------------------------"
					  f2b_sshd
					  echo "------------------------"
					  ;;
				  6)

					  echo "------------------------"
					  xxx=fail2ban-nginx-cc
					  f2b_status_xxx
					  echo "------------------------"
					  xxx=docker-nginx-bad-request
					  f2b_status_xxx
					  echo "------------------------"
					  xxx=docker-nginx-botsearch
					  f2b_status_xxx
					  echo "------------------------"
					  xxx=docker-nginx-http-auth
					  f2b_status_xxx
					  echo "------------------------"
					  xxx=docker-nginx-limit-req
					  f2b_status_xxx
					  echo "------------------------"
					  xxx=docker-php-url-fopen
					  f2b_status_xxx
					  echo "------------------------"

					  ;;

				  7)
					  docker exec -it fail2ban fail2ban-client status
					  ;;
				  8)
					  tail -f /path/to/fail2ban/config/log/fail2ban/fail2ban.log

					  ;;
				  9)
					  docker rm -f fail2ban
					  rm -rf /path/to/fail2ban
					  crontab -l | grep -v "CF-Under-Attack.sh" | crontab - 2>/dev/null
					  echo "Fail2Ban防御程序已卸载"
					  break
					  ;;

				  11)
					  install nano
					  nano /path/to/fail2ban/config/fail2ban/jail.d/nginx-docker-cc.conf
					  f2b_status

					  break
					  ;;
				  21)
					  send_stats "cloudflare模式"
					  echo "到cf后台右上角我的个人资料，选择左侧API令牌，获取Global API Key"
					  echo "https://dash.cloudflare.com/login"
					  read -e -p "输入CF的账号: " cfuser
					  read -e -p "输入CF的Global API Key: " cftoken

					  wget -O /home/web/conf.d/default.conf ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/nginx/main/default11.conf
					  docker restart nginx

					  cd /path/to/fail2ban/config/fail2ban/jail.d/
					  curl -sS -O ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/config/main/fail2ban/nginx-docker-cc.conf

					  cd /path/to/fail2ban/config/fail2ban/action.d
					  curl -sS -O ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/config/main/fail2ban/cloudflare-docker.conf

					  sed -i "@outlook.com/$cfuser/g" /path/to/fail2ban/config/fail2ban/action.d/cloudflare-docker.conf
					  sed -i "s/APIKEY00000/$cftoken/g" /path/to/fail2ban/config/fail2ban/action.d/cloudflare-docker.conf
					  f2b_status

					  echo "已配置cloudflare模式，可在cf后台，站点-安全性-事件中查看拦截记录"
					  ;;

				  22)
					  send_stats "高负载开启5秒盾"
					  echo -e "${gl_huang}网站每5分钟自动检测，当达检测到高负载会自动开盾，低负载也会自动关闭5秒盾。${gl_bai}"
					  echo "--------------"
					  echo "获取CF参数: "
					  echo -e "到cf后台右上角我的个人资料，选择左侧API令牌，获取${gl_huang}Global API Key${gl_bai}"
					  echo -e "到cf后台域名概要页面右下方获取${gl_huang}区域ID${gl_bai}"
					  echo "https://dash.cloudflare.com/login"
					  echo "--------------"
					  read -e -p "输入CF的账号: " cfuser
					  read -e -p "输入CF的Global API Key: " cftoken
					  read -e -p "输入CF中域名的区域ID: " cfzonID

					  cd ~
					  install jq bc
					  check_crontab_installed
					  curl -sS -O ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/CF-Under-Attack.sh
					  chmod +x CF-Under-Attack.sh
					  sed -i "s/AAAA/$cfuser/g" ~/CF-Under-Attack.sh
					  sed -i "s/BBBB/$cftoken/g" ~/CF-Under-Attack.sh
					  sed -i "s/CCCC/$cfzonID/g" ~/CF-Under-Attack.sh

					  cron_job="*/5 * * * * ~/CF-Under-Attack.sh"

					  existing_cron=$(crontab -l 2>/dev/null | grep -F "$cron_job")

					  if [ -z "$existing_cron" ]; then
						  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
						  echo "高负载自动开盾脚本已添加"
					  else
						  echo "自动开盾脚本已存在，无需添加"
					  fi

					  ;;
				  0)
					  break
					  ;;
				  *)
					  echo "无效的选择，请重新输入。"
					  ;;
			  esac
		elif [ -x "$(command -v fail2ban-client)" ] ; then
			clear
			echo "卸载旧版fail2ban"
			read -e -p "确定继续吗？(Y/N): " choice
			case "$choice" in
			  [Yy])
				remove fail2ban
				rm -rf /etc/fail2ban
				echo "Fail2Ban防御程序已卸载"
				;;
			  [Nn])
				echo "已取消"
				;;
			  *)
				echo "无效的选择，请输入 Y 或 N。"
				;;
			esac

		else
			clear
			install_docker


			wget -O /home/web/nginx.conf ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/nginx/main/nginx10.conf
			wget -O /home/web/conf.d/default.conf ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/nginx/main/default10.conf
			default_server_ssl
			nginx_upgrade

			f2b_install_sshd
			cd /path/to/fail2ban/config/fail2ban/filter.d
			curl -sS -O ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/fail2ban-nginx-cc.conf
			cd /path/to/fail2ban/config/fail2ban/jail.d/
			curl -sS -O ${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/config/main/fail2ban/nginx-docker-cc.conf
			sed -i "/cloudflare/d" /path/to/fail2ban/config/fail2ban/jail.d/nginx-docker-cc.conf

			f2b_status
			cd ~

			echo "防御程序已开启"
		fi
	  break_end
	  done

		;;
