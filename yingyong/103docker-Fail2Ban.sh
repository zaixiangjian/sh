#!/bin/bash

# Fail2Ban SSH防暴力破解独立管理脚本
# 从 /root/kejilion.sh 的 103 号功能拆分，未修改原脚本。

gl_bai="[0m"
gl_hong="[31m"
gl_lv="[32m"
gl_huang="[33m"
gl_kjlan="[36m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${gl_hong}请使用 root 用户运行。${gl_bai}"
    exit 1
fi

    fail2ban_ensure_python3() {
        echo "正在检查 Python 3..."
        if command -v python3 >/dev/null 2>&1; then
            echo -e "${gl_lv}Python 3已安装：$(python3 --version 2>&1)${gl_bai}"
            return 0
        fi

        echo "Python 3未安装，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null 2>&1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y python3 >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y python3 >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1 && apk add --no-cache python3 >/dev/null 2>&1
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install python3 >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm python >/dev/null 2>&1
        else
            echo -e "${gl_hong}Python 3安装失败：当前系统未检测到支持的包管理器${gl_bai}"
            return 1
        fi

        if command -v python3 >/dev/null 2>&1; then
            echo -e "${gl_lv}Python 3安装完成：$(python3 --version 2>&1)${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}Python 3安装失败${gl_bai}"
            return 1
        fi
    }


fail2ban_duration_to_seconds() {
    local value="$1"
    value=$(echo "${value:-}" | tr '[:upper:]' '[:lower:]' | xargs)
    [ -z "$value" ] && { echo 0; return; }
    case "$value" in
        -1|perm|permanent|永久) echo -1; return ;;
    esac
    if echo "$value" | grep -Eq '^[0-9]+$'; then
        echo "$value"
        return
    fi
    local num unit
    num=$(echo "$value" | sed -E 's/^([0-9]+).*/\1/')
    unit=$(echo "$value" | sed -E 's/^[0-9]+//')
    [ -z "$num" ] && { echo 0; return; }
    case "$unit" in
        s|sec|secs|second|seconds) echo "$num" ;;
        m|min|mins|minute|minutes) echo $((num * 60)) ;;
        h|hour|hours) echo $((num * 3600)) ;;
        d|day|days) echo $((num * 86400)) ;;
        w|week|weeks) echo $((num * 604800)) ;;
        *) echo 0 ;;
    esac
}

fail2ban_get_config_value() {
    local key="$1"
    local value=""
    for conf in /home/docker/fail2ban/config/fail2ban/jail.d/sshd.local /home/docker/fail2ban/config/fail2ban/jail.local; do
        if [ -f "$conf" ]; then
            value=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
            [ -n "$value" ] && { echo "$value"; return; }
        fi
    done
    echo ""
}

fail2ban_format_epoch() {
    local epoch="$1"
    if [ -z "$epoch" ] || ! echo "$epoch" | grep -Eq '^[0-9]+$'; then
        echo "-"
        return
    fi
    date -d "@$epoch" '+%m月%d日' 2>/dev/null || echo "-"
}

fail2ban_prepare_ban_events() {
    local out_file="$1"
    : > "$out_file"
    local tmp_lines
    tmp_lines=$(mktemp)

    for log_file in /home/docker/fail2ban/log/fail2ban.log* /home/docker/fail2ban/config/log/fail2ban/fail2ban.log*; do
        [ -e "$log_file" ] || continue
        case "$log_file" in
            *.gz) zgrep -h ' Ban ' "$log_file" 2>/dev/null >> "$tmp_lines" || true ;;
            *) grep -h ' Ban ' "$log_file" 2>/dev/null >> "$tmp_lines" || true ;;
        esac
    done

    if [ ! -s "$tmp_lines" ] && docker inspect fail2ban >/dev/null 2>&1; then
        docker logs fail2ban 2>&1 | grep ' Ban ' >> "$tmp_lines" || true
    fi

    sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}).* Ban[[:space:]]+([0-9A-Fa-f:.]+).*/\3 \1 \2/p' "$tmp_lines" |
    while read -r ip day time_text; do
        epoch=$(date -d "$day $time_text" '+%s' 2>/dev/null || true)
        [ -n "$epoch" ] && echo "$ip $epoch"
    done | sort -k1,1 -k2,2n > "$out_file"

    rm -f "$tmp_lines"
}

fail2ban_get_ip_ban_times() {
    local ip="$1"
    local plain_status="$2"
    local ban_events_file="$3"
    local bantime bantime_seconds ban_epoch unban_epoch

    if [ "$plain_status" != "已封禁" ]; then
        echo "- -"
        return
    fi

    bantime=$(fail2ban_get_config_value bantime)
    bantime_seconds=$(fail2ban_duration_to_seconds "${bantime:-}")
    ban_epoch=$(awk -v qip="$ip" '$1 == qip { last=$2 } END { print last }' "$ban_events_file" 2>/dev/null)

    if [ -z "$ban_epoch" ]; then
        echo "- 未知"
        return
    fi

    if [ "$bantime_seconds" = "-1" ]; then
        echo "$(fail2ban_format_epoch "$ban_epoch") 永久"
        return
    fi

    if [ "$bantime_seconds" -gt 0 ] 2>/dev/null; then
        unban_epoch=$((ban_epoch + bantime_seconds))
        echo "$(fail2ban_format_epoch "$ban_epoch") $(fail2ban_format_epoch "$unban_epoch")"
    else
        echo "$(fail2ban_format_epoch "$ban_epoch") 未知"
    fi
}

while true; do
    clear
    echo -e "▶️ Fail2Ban SSH防暴力破解"
    echo -e "${gl_kjlan}------------------------"

    fail2ban_conf="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"

    if [ -f "$fail2ban_conf" ]; then
        echo -e "${gl_lv}已配置${gl_bai}"
        echo -e "${gl_lv}Fail2Ban SSH防暴力破解已配置完成${gl_bai}"

        conf_ssh_port=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
        conf_maxretry=$(grep -E '^[[:space:]]*maxretry[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
        conf_findtime=$(grep -E '^[[:space:]]*findtime[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
        conf_bantime=$(grep -E '^[[:space:]]*bantime[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')

        echo "SSH端口: ${conf_ssh_port:-未知}"
        echo "失败次数: ${conf_maxretry:-未知}"
        echo "统计窗口: ${conf_findtime:-未知}"
        echo "封禁时长: ${conf_bantime:-未知}"
        echo "配置文件: $fail2ban_conf"
        echo "查看状态: docker exec fail2ban fail2ban-client status sshd"

        if docker inspect fail2ban &>/dev/null; then
            container_status=$(docker inspect -f '{{.State.Status}}' fail2ban 2>/dev/null)

            if [ "$container_status" = "running" ]; then
                if docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                    echo -e "Fail2Ban状态: ${gl_lv}运行正常${gl_bai}"
                else
                    echo -e "Fail2Ban状态: ${gl_hong}异常${gl_bai}"
                fi
            else
                echo -e "Fail2Ban容器: ${gl_hong}${container_status:-不存在}${gl_bai}"
            fi
        fi

        echo -e "${gl_kjlan}------------------------${gl_bai}"
    fi

    echo -e "${gl_lv}================================${gl_bai}"
    echo "定时任务ssh登录成功通知"
    echo "电报通知"
    tg_cron=$(crontab -l 2>/dev/null | grep 'ssh-login-telegram.sh' | grep -v '^#' | head -n1)
    if [ -n "$tg_cron" ]; then
        echo -e "${gl_lv}${tg_cron}${gl_bai}"
    else
        echo -e "${gl_lv}暂无${gl_bai}"
    fi
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    echo "邮件Resend通知"
    mail_resend_cron=$(crontab -l 2>/dev/null | grep 'ssh-Resend-email-smtp.sh' | grep -v '^#' | head -n1)
    [ -n "$mail_resend_cron" ] && echo -e "${gl_lv}${mail_resend_cron}${gl_bai}" || echo -e "${gl_lv}暂无${gl_bai}"
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    echo "邮件SMTP通知"
    mail_smtp_cron=$(crontab -l 2>/dev/null | grep 'ssh-smtp-email-smtp.sh' | grep -v '^#' | head -n1)
    [ -n "$mail_smtp_cron" ] && echo -e "${gl_lv}${mail_smtp_cron}${gl_bai}" || echo -e "${gl_lv}暂无${gl_bai}"
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    echo "其他API邮件通知"
    mail_qita_cron=$(crontab -l 2>/dev/null | grep 'ssh-qita-email-smtp.sh' | grep -v '^#' | head -n1)
    [ -n "$mail_qita_cron" ] && echo -e "${gl_lv}${mail_qita_cron}${gl_bai}" || echo -e "${gl_lv}暂无${gl_bai}"
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    echo -e "${gl_huang}即时通知保护${gl_bai}"
    if grep -q '/home/docker/fail2ban/notify/ssh-login-pam-alert.sh' /etc/pam.d/sshd 2>/dev/null; then
        echo -e "${gl_lv}已开启${gl_bai}"
    else
        echo -e "${gl_hong}未启用${gl_bai}"
    fi
    echo -e "${gl_kjlan}------------------------${gl_bai}"
    echo -e "${gl_huang}白名单是否通知${gl_bai}"
    if [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ]; then
        echo -e "${gl_hong}不通知${gl_bai}"
    else
        echo -e "${gl_lv}通知${gl_bai}"
    fi
    echo -e "${gl_lv}================================${gl_bai}"

    echo -e "${gl_kjlan}1.   ${gl_bai}使用 Docker 安装到 /home/docker/fail2ban"
    echo -e "${gl_kjlan}2.   ${gl_bai}更新"
    echo -e "${gl_kjlan}3.   ${gl_bai}配置 SSH 防暴力破解"
    echo -e "${gl_lv}4.   查看成功统计 TOP50${gl_bai}"
    echo -e "${gl_hong}5.   查看失败统计 TOP50${gl_bai}"
    echo -e "${gl_lv}6.   查看/管理白名单${gl_bai}"
    echo -e "${gl_hong}7.   查看封禁的IP${gl_bai}"
    echo -e "${gl_kjlan}8.   ${gl_bai}查看日志占用/手动清理"
    echo -e "${gl_kjlan}9.   ${gl_bai}卸载"
    echo -e "${gl_lv}999. 登录成功通知设置${gl_bai}"
    echo -e "${gl_kjlan}0.   ${gl_bai}返回上一级"
    echo -e "${gl_kjlan}------------------------${gl_bai}"

    read -e -p "请输入你的选择: " fail2ban_choice

    case $fail2ban_choice in

        1)
            clear

            if [ "$EUID" -ne 0 ]; then
                echo -e "${gl_hong}请使用 root 用户运行安装。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            if docker inspect fail2ban &>/dev/null; then
                echo -e "${gl_huang}检测到 Fail2Ban 已安装，改为执行更新并保留现有 SSH 防护配置...${gl_bai}"
                install_docker

                echo "拉取最新 Fail2Ban 镜像..."
                docker pull lscr.io/linuxserver/fail2ban:latest

                echo "停止旧容器..."
                docker rm -f fail2ban >/dev/null 2>&1 || true

                echo "保留现有 SSH 防护配置，避免需要重新配置..."
                mkdir -p /home/docker/fail2ban/config/fail2ban/jail.d
                mkdir -p /home/docker/fail2ban/config/fail2ban/filter.d
                mkdir -p /home/docker/fail2ban/config/fail2ban/action.d
                mkdir -p /home/docker/fail2ban/log

                echo "重新创建 Fail2Ban..."
                docker run -d \
                    --name=fail2ban \
                    --net=host \
                    --cap-add=NET_ADMIN \
                    --cap-add=NET_RAW \
                    -e PUID=0 \
                    -e PGID=0 \
                    -e TZ=Etc/UTC \
                    -e VERBOSITY=-v \
                    -v /home/docker/fail2ban/config:/config \
                    -v /home/docker/fail2ban/log:/config/log/fail2ban \
                    -v /var/log:/var/log:ro \
                    -v /run/log/journal:/run/log/journal:ro \
                    -v /var/log/journal:/var/log/journal:ro \
                    -v /etc/machine-id:/etc/machine-id:ro \
                    --restart unless-stopped \
                    --log-opt max-size=10m \
                    --log-opt max-file=3 \
                    lscr.io/linuxserver/fail2ban:latest

                sleep 5

                echo "------------------------"
                echo -e "${gl_lv}Fail2Ban 更新完成${gl_bai}"
                echo "原配置目录保留: /home/docker/fail2ban"

                if docker exec fail2ban fail2ban-client ping &>/dev/null; then
                    echo -e "Fail2Ban服务: ${gl_lv}正常${gl_bai}"
                else
                    echo -e "Fail2Ban服务: ${gl_hong}异常${gl_bai}"
                    echo "查看日志:"
                    echo "docker logs --tail 100 fail2ban"
                fi

                read -n1 -r -p "按任意键继续..."
                continue
            fi

            echo "▶️ 使用 Docker 安装 Fail2Ban 到 /home/docker/fail2ban ..."
            install_docker

            # Debian/Ubuntu 启用 rsyslog，让 SSH 日志持续写入 /var/log/auth.log，并限制 auth.log 大小
            if command -v apt &>/dev/null; then
                install rsyslog logrotate
                systemctl start rsyslog >/dev/null 2>&1 || true
                systemctl enable rsyslog >/dev/null 2>&1 || true
                touch /var/log/auth.log
                cat > /etc/logrotate.d/authlog-ssh <<EOF
/var/log/auth.log {
    daily
    rotate 7
    size 20M
    missingok
    notifempty
    compress
    delaycompress
    create 0640 syslog adm
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF
            fi

            mkdir -p /home/docker/fail2ban/config/fail2ban/jail.d
            mkdir -p /home/docker/fail2ban/config/fail2ban/filter.d
            mkdir -p /home/docker/fail2ban/config/fail2ban/action.d
            mkdir -p /home/docker/fail2ban/log

            install logrotate

            cat > /etc/logrotate.d/fail2ban-docker <<EOF
/home/docker/fail2ban/log/*.log /home/docker/fail2ban/log/*/*.log {
    daily
    rotate 7
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

            echo "清理可能导致配置冲突的旧自定义配置..."

            rm -f /home/docker/fail2ban/config/fail2ban/jail.d/sshd.conf
            rm -f /home/docker/fail2ban/config/fail2ban/jail.d/sshd.local

            if docker inspect fail2ban &>/dev/null; then
                echo -e "${gl_huang}检测到 fail2ban 容器已存在，删除旧容器后重新创建...${gl_bai}"
                docker rm -f fail2ban >/dev/null 2>&1 || true
            fi

            echo "创建 Fail2Ban Docker 容器..."

            docker run -d \
                --name=fail2ban \
                --net=host \
                --cap-add=NET_ADMIN \
                --cap-add=NET_RAW \
                -e PUID=0 \
                -e PGID=0 \
                -e TZ=Etc/UTC \
                -e VERBOSITY=-v \
                -v /home/docker/fail2ban/config:/config \
                -v /home/docker/fail2ban/log:/config/log/fail2ban \
                -v /var/log:/var/log:ro \
                -v /run/log/journal:/run/log/journal:ro \
                -v /var/log/journal:/var/log/journal:ro \
                -v /etc/machine-id:/etc/machine-id:ro \
                --restart unless-stopped \
                --log-opt max-size=10m \
                --log-opt max-file=3 \
                lscr.io/linuxserver/fail2ban:latest

            if [ $? -ne 0 ]; then
                echo -e "${gl_hong}Fail2Ban Docker 容器创建失败。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            sleep 5

            echo "------------------------"
            echo -e "${gl_lv}Docker Fail2Ban 安装完成${gl_bai}"
            echo "本地目录: /home/docker/fail2ban"
            echo "容器映射: /home/docker/fail2ban/config -> /config"
            echo "容器日志: /home/docker/fail2ban/log"
            echo "SSH日志: /var/log/auth.log 或 /var/log/secure（容器只读读取 /var/log）"
            echo "日志限制: auth.log 20M×7压缩，Fail2Ban日志 10M×7压缩，Docker日志 10M×3"
            echo "下一步: 进入 3 配置 SSH 防暴力破解"

            if docker exec fail2ban fail2ban-client ping &>/dev/null; then
                echo -e "Fail2Ban服务: ${gl_lv}正常${gl_bai}"
            else
                echo -e "Fail2Ban服务: ${gl_hong}尚未正常启动${gl_bai}"
                echo "可以查看:"
                echo "docker logs --tail 100 fail2ban"
            fi

            read -n1 -r -p "按任意键继续..."
            ;;

        2)
            clear

            if [ "$EUID" -ne 0 ]; then
                echo -e "${gl_hong}请使用 root 用户运行更新。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            echo "▶️ 更新 Fail2Ban Docker 镜像..."

            install_docker

            # Debian/Ubuntu 启用 rsyslog，让 SSH 日志持续写入 /var/log/auth.log，并限制 auth.log 大小
            if command -v apt &>/dev/null; then
                install rsyslog logrotate
                systemctl start rsyslog >/dev/null 2>&1 || true
                systemctl enable rsyslog >/dev/null 2>&1 || true
                touch /var/log/auth.log
                cat > /etc/logrotate.d/authlog-ssh <<EOF
/var/log/auth.log {
    daily
    rotate 7
    size 20M
    missingok
    notifempty
    compress
    delaycompress
    create 0640 syslog adm
    sharedscripts
    postrotate
        systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF
            fi

            mkdir -p /home/docker/fail2ban/config/fail2ban/jail.d
            mkdir -p /home/docker/fail2ban/config/fail2ban/filter.d
            mkdir -p /home/docker/fail2ban/config/fail2ban/action.d
            mkdir -p /home/docker/fail2ban/log

            install logrotate

            cat > /etc/logrotate.d/fail2ban-docker <<EOF
/home/docker/fail2ban/log/*.log /home/docker/fail2ban/log/*/*.log {
    daily
    rotate 7
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF

            echo "拉取最新 Fail2Ban 镜像..."

            docker pull lscr.io/linuxserver/fail2ban:latest

            echo "停止旧容器..."

            docker rm -f fail2ban >/dev/null 2>&1 || true

            echo "保留现有 SSH 防护配置，避免更新后需要重新配置..."

            echo "重新创建 Fail2Ban..."

            docker run -d \
                --name=fail2ban \
                --net=host \
                --cap-add=NET_ADMIN \
                --cap-add=NET_RAW \
                -e PUID=0 \
                -e PGID=0 \
                -e TZ=Etc/UTC \
                -e VERBOSITY=-v \
                -v /home/docker/fail2ban/config:/config \
                -v /home/docker/fail2ban/log:/config/log/fail2ban \
                -v /var/log:/var/log:ro \
                -v /run/log/journal:/run/log/journal:ro \
                -v /var/log/journal:/var/log/journal:ro \
                -v /etc/machine-id:/etc/machine-id:ro \
                --restart unless-stopped \
                --log-opt max-size=10m \
                --log-opt max-file=3 \
                lscr.io/linuxserver/fail2ban:latest

            sleep 5

            echo "------------------------"
            echo -e "${gl_lv}Fail2Ban 更新完成${gl_bai}"
            echo "原配置目录保留: /home/docker/fail2ban"

            if docker exec fail2ban fail2ban-client ping &>/dev/null; then
                echo -e "Fail2Ban服务: ${gl_lv}正常${gl_bai}"
            else
                echo -e "Fail2Ban服务: ${gl_hong}异常${gl_bai}"
                echo "查看日志:"
                echo "docker logs --tail 100 fail2ban"
            fi

            read -n1 -r -p "按任意键继续..."
            ;;

        3)
            clear

            if [ "$EUID" -ne 0 ]; then
                echo -e "${gl_hong}请使用 root 用户运行配置。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            if ! docker inspect fail2ban &>/dev/null; then
                echo -e "${gl_hong}未检测到 fail2ban 容器，请先选择 1 安装。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            echo "▶️ 配置 Fail2Ban SSH 防暴力破解..."
            echo "说明: SSH 登录失败次数过多会自动封禁来源 IP。"
            echo "------------------------"

            # 检测 SSH 端口
            detected_port=""

            if [ -f /etc/ssh/sshd_config ]; then
                detected_port=$(awk '
                    /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
                        port=$2
                    }
                    END {
                        print port
                    }
                ' /etc/ssh/sshd_config 2>/dev/null)
            fi

            if [ -z "$detected_port" ]; then
                detected_port=$(ss -ltnp 2>/dev/null | awk '
                    /sshd/ {
                        split($4,a,":")
                        print a[length(a)]
                        exit
                    }
                ')
            fi

            detected_port=${detected_port:-22}

            read -e -p "请输入SSH端口 [默认: ${detected_port}]: " ssh_port
            ssh_port=${ssh_port:-$detected_port}

            if ! echo "$ssh_port" | grep -Eq '^[0-9]+$' || \
               [ "$ssh_port" -lt 1 ] || \
               [ "$ssh_port" -gt 65535 ]; then

                echo -e "${gl_hong}端口无效，请输入 1-65535。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            read -e -p "失败多少次后封禁 [默认: 5]: " maxretry
            maxretry=${maxretry:-5}

            if ! echo "$maxretry" | grep -Eq '^[0-9]+$' || [ "$maxretry" -lt 1 ]; then
                echo -e "${gl_hong}次数无效，已使用默认 5。${gl_bai}"
                maxretry=5
            fi

            read -e -p "统计时间窗口，例如 10m/1h/1d [默认: 1d]: " findtime
            findtime=${findtime:-1d}

            read -e -p "封禁时长，例如 1d/12h/-1永久 [默认: 15d]: " bantime
            bantime=${bantime:-15d}

            # 获取当前服务器 IPv4
            current_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

            echo
            echo "当前服务器IP: ${current_ip:-未知}"

            read -e -p "额外需要白名单的IP，可留空: " extra_ignoreip

            # 生成白名单
            ignoreip="127.0.0.1/8 ::1"

            if [ -n "$current_ip" ]; then
                ignoreip="$ignoreip $current_ip"
            fi

            if [ -n "$extra_ignoreip" ]; then
                ignoreip="$ignoreip $extra_ignoreip"
            fi

            mkdir -p /home/docker/fail2ban/config/fail2ban/jail.d
            mkdir -p /home/docker/fail2ban/config/fail2ban/filter.d
            mkdir -p /home/docker/fail2ban/config/fail2ban/action.d

            # Docker 容器内不稳定使用 backend=systemd，统一转成文件日志读取。
            # 如果系统没有 /var/log/auth.log 或 /var/log/secure，就把 journalctl -u ssh 最近7天导出到本地文件给容器读取。
            log_source_desc=""
            logpath_line=""
            if [ -f /var/log/auth.log ]; then
                logpath_line="logpath = /var/log/auth.log"
                log_source_desc="/var/log/auth.log"
            elif [ -f /var/log/secure ]; then
                logpath_line="logpath = /var/log/secure"
                log_source_desc="/var/log/secure"
            else
                echo -e "${gl_hong}未检测到 /var/log/auth.log 或 /var/log/secure。${gl_bai}"
                echo "Debian/Ubuntu 请先确认 rsyslog 是否已生成 /var/log/auth.log："
                echo "systemctl status rsyslog && ls -l /var/log/auth.log"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            cat > /home/docker/fail2ban/config/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = ${ignoreip}
bantime = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend = auto
banaction = iptables-multiport
banaction_allports = iptables-allports
EOF

            # SSH Filter
            cat > /home/docker/fail2ban/config/fail2ban/filter.d/sshd.local <<'EOF'
[Definition]
failregex = ^.*sshd.*Failed password for .* from <HOST>(?: port \d+)?(?: ssh\d*)?.*$
            ^.*sshd.*Invalid user .* from <HOST>(?: port \d+)?.*$
            ^.*sshd.*authentication failure.*rhost=<HOST>.*$
ignoreregex =
EOF

            # 只启用 SSH
            cat > /home/docker/fail2ban/config/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
backend = auto
${logpath_line}
maxretry = ${maxretry}
findtime = ${findtime}
bantime = ${bantime}
ignoreip = ${ignoreip}
action = iptables-multiport[name=sshd, port="${ssh_port}", protocol=tcp]
EOF

            echo
            echo "正在重启 Fail2Ban..."

            docker restart fail2ban >/dev/null 2>&1

            sleep 5

            echo "------------------------"

            # 检查 Fail2Ban 主服务
            if ! docker exec fail2ban fail2ban-client ping &>/dev/null; then
                echo -e "${gl_hong}Fail2Ban 服务启动失败！${gl_bai}"
                echo
                echo "最近错误日志:"
                docker logs fail2ban 2>&1 | grep -iE "error|critical|failed|traceback|unable|permission" | tail -n 80
                echo "最近完整日志:"
                docker logs --tail 80 fail2ban
                echo
                echo "配置文件:"
                cat /home/docker/fail2ban/config/fail2ban/jail.d/sshd.local

                read -n1 -r -p "按任意键继续..."
                continue
            fi

            # 检查 SSH jail
            if docker exec fail2ban fail2ban-client status sshd &>/dev/null; then

                echo -e "${gl_lv}Fail2Ban SSH防暴力破解配置成功${gl_bai}"
                echo
                echo "SSH端口: ${ssh_port}"
                echo "失败次数: ${maxretry}"
                echo "统计窗口: ${findtime}"
                echo "封禁时长: ${bantime}"
                echo "白名单: ${ignoreip}"
                echo "日志来源: ${log_source_desc}"
                echo "配置文件: /home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
                echo
                echo "Fail2Ban状态:"
                docker exec fail2ban fail2ban-client status sshd

            else

                echo -e "${gl_hong}Fail2Ban服务运行，但 sshd jail 启动失败！${gl_bai}"
                echo
                docker logs --tail 50 fail2ban

            fi

            read -n1 -r -p "按任意键继续..."
            ;;

        4)
            while true; do
                clear
                echo "统计范围:"
                echo "1. 最近7天"
                echo "2. 最近15天"
                echo "3. 最近30天"
                echo "0. 返回上一级"
                read -e -p "请输入你的选择（回车默认1）: " stat_days_choice
                stat_days_choice=${stat_days_choice:-1}
                case "$stat_days_choice" in
                    1) stat_days="7" ;;
                    2) stat_days="15" ;;
                    3) stat_days="30" ;;
                    0) break ;;
                    *) echo "无效选择"; read -n1 -r -p "按任意键继续..."; continue ;;
                esac

                clear

                echo "▶️ SSH 登录成功来源统计 TOP 50"
                echo "说明: 只统计最近${stat_days}天 SSH 登录成功来源 IP，成功次数多的优先显示。"
                echo "------------------------"

                tmp_ssh_stats=$(mktemp)
                tmp_ssh_table=$(mktemp)

                if command -v journalctl &>/dev/null; then
                    journalctl -u ssh --since "${stat_days} days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi

                if [ ! -s "$tmp_ssh_stats" ] && command -v journalctl &>/dev/null; then
                    journalctl -u sshd --since "${stat_days} days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi

                fail2ban_conf="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
                whitelist=""
                if [ -f "$fail2ban_conf" ]; then
                    whitelist=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
                fi

                banned_ips=""
                tmp_ban_events=$(mktemp)
                fail2ban_prepare_ban_events "$tmp_ban_events"
                if docker inspect fail2ban &>/dev/null && \
                   docker exec fail2ban fail2ban-client ping &>/dev/null && \
                   docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                    banned_ips=$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
                    if [ -z "$banned_ips" ]; then
                        banned_ips=$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
                    fi
                fi

                awk '
                {
                    ip=""; type=""
                    if ($0 ~ /Accepted/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="ok"; break }
                    } else if ($0 ~ /Failed password/ || $0 ~ /Invalid user/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="fail"; break }
                    } else if ($0 ~ /authentication failure/) {
                        for (i=1; i<=NF; i++) if ($i ~ /^rhost=/) { ip=$i; sub(/^rhost=/, "", ip); type="fail"; break }
                    }
                    if (ip != "") {
                        gsub(/[^0-9A-Fa-f:.]/, "", ip)
                        if (type == "ok") success[ip]++
                        else if (type == "fail") failed[ip]++
                    }
                }
                END {
                    for (ip in success) {
                        if (success[ip] > 0) printf "%s %d %d %d\n", ip, success[ip]+0, failed[ip]+0, success[ip]+failed[ip]
                    }
                }' "$tmp_ssh_stats" | sort -k2,2nr -k4,4nr | head -50 > "$tmp_ssh_table"

                printf "%-20s %-8s %-8s %-8s %-8s %-15s %-15s\n" "IP" "成功" "失败" "总计" "状态" "封禁时间" "解封时间"
                echo "--------------------------------------------------------------------------------"

                if [ ! -s "$tmp_ssh_table" ]; then
                    echo -e "${gl_huang}最近${stat_days}天没有统计到 SSH 成功登录记录。${gl_bai}"
                else
                    while read -r stat_ip stat_ok stat_fail stat_total; do
                        if echo " $whitelist " | grep -Fqw -- "$stat_ip"; then
                            stat_status_plain="白名单"
                            stat_status="${gl_lv}白名单${gl_bai}"
                        elif echo " $banned_ips " | grep -Fqw -- "$stat_ip"; then
                            stat_status_plain="已封禁"
                            stat_status="${gl_hong}已封禁${gl_bai}"
                        else
                            stat_status_plain="未封禁"
                            stat_status="${gl_huang}未封禁${gl_bai}"
                        fi
                        read -r stat_ban_time stat_unban_time < <(fail2ban_get_ip_ban_times "$stat_ip" "$stat_status_plain" "$tmp_ban_events")
                        printf "%-20s %-8s %-8s %-8s %-18b %-15s %-15s\n" "$stat_ip" "${stat_ok}次" "${stat_fail}次" "${stat_total}次" "$stat_status" "$stat_ban_time" "$stat_unban_time"
                    done < "$tmp_ssh_table"
                fi

                rm -f "$tmp_ssh_stats" "$tmp_ssh_table" "$tmp_ban_events"

                echo "------------------------------------------------"
                echo "说明: 这是日志统计，不会修改或清除日志。"
                echo "日志保留时间取决于 systemd-journald 策略。"

                if docker inspect fail2ban &>/dev/null; then
                    if docker exec fail2ban fail2ban-client ping &>/dev/null; then
                        if docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                            echo "Fail2Ban容器状态:"
                            docker exec fail2ban fail2ban-client status sshd
                        else
                            echo -e "${gl_hong}Fail2Ban运行，但 sshd jail 未启动。${gl_bai}"
                        fi
                    else
                        echo -e "${gl_hong}Fail2Ban服务未正常运行。${gl_bai}"
                    fi
                fi

                read -n1 -r -p "按任意键继续..."
                break
            done
            ;;

        5)
            while true; do
                clear
                echo "统计范围:"
                echo "1. 最近7天"
                echo "2. 最近15天"
                echo "3. 最近30天"
                echo "0. 返回上一级"
                read -e -p "请输入你的选择（回车默认1）: " stat_days_choice
                stat_days_choice=${stat_days_choice:-1}
                case "$stat_days_choice" in
                    1) stat_days="7" ;;
                    2) stat_days="15" ;;
                    3) stat_days="30" ;;
                    0) break ;;
                    *) echo "无效选择"; read -n1 -r -p "按任意键继续..."; continue ;;
                esac

                clear

                echo "▶️ SSH 登录来源统计 TOP 50"
                echo "说明: 统计最近${stat_days}天 SSH 登录成功/失败来源 IP。"
                echo "------------------------"

                tmp_ssh_stats=$(mktemp)
                tmp_ssh_table=$(mktemp)

                if command -v journalctl &>/dev/null; then
                    journalctl -u ssh --since "${stat_days} days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi

                if [ ! -s "$tmp_ssh_stats" ] && command -v journalctl &>/dev/null; then
                    journalctl -u sshd --since "${stat_days} days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi

                fail2ban_conf="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
                whitelist=""
                if [ -f "$fail2ban_conf" ]; then
                    whitelist=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
                fi

                banned_ips=""
                tmp_ban_events=$(mktemp)
                fail2ban_prepare_ban_events "$tmp_ban_events"
                if docker inspect fail2ban &>/dev/null && \
                   docker exec fail2ban fail2ban-client ping &>/dev/null && \
                   docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                    banned_ips=$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
                    if [ -z "$banned_ips" ]; then
                        banned_ips=$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
                    fi
                fi

                awk '
                {
                    ip=""; type=""
                    if ($0 ~ /Accepted/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="ok"; break }
                    } else if ($0 ~ /Failed password/ || $0 ~ /Invalid user/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="fail"; break }
                    } else if ($0 ~ /authentication failure/) {
                        for (i=1; i<=NF; i++) if ($i ~ /^rhost=/) { ip=$i; sub(/^rhost=/, "", ip); type="fail"; break }
                    }
                    if (ip != "") {
                        gsub(/[^0-9A-Fa-f:.]/, "", ip)
                        if (type == "ok") success[ip]++
                        else if (type == "fail") failed[ip]++
                    }
                }
                END {
                    for (ip in failed) {
                        if (failed[ip] > 0) printf "%s %d %d %d\n", ip, success[ip]+0, failed[ip]+0, success[ip]+failed[ip]
                    }
                }' "$tmp_ssh_stats" | sort -k3,3nr -k4,4nr | head -50 > "$tmp_ssh_table"

                printf "%-20s %-8s %-8s %-8s %-8s %-15s %-15s\n" "IP" "成功" "失败" "总计" "状态" "封禁时间" "解封时间"
                echo "--------------------------------------------------------------------------------"

                if [ ! -s "$tmp_ssh_table" ]; then
                    echo -e "${gl_huang}最近${stat_days}天没有统计到 SSH 失败登录记录。${gl_bai}"
                else
                    while read -r stat_ip stat_ok stat_fail stat_total; do
                        if echo " $whitelist " | grep -Fqw -- "$stat_ip"; then
                            stat_status_plain="白名单"
                            stat_status="${gl_lv}白名单${gl_bai}"
                        elif echo " $banned_ips " | grep -Fqw -- "$stat_ip"; then
                            stat_status_plain="已封禁"
                            stat_status="${gl_hong}已封禁${gl_bai}"
                        else
                            stat_status_plain="未封禁"
                            stat_status="${gl_huang}未封禁${gl_bai}"
                        fi
                        read -r stat_ban_time stat_unban_time < <(fail2ban_get_ip_ban_times "$stat_ip" "$stat_status_plain" "$tmp_ban_events")
                        printf "%-20s %-8s %-8s %-8s %-18b %-15s %-15s\n" "$stat_ip" "${stat_ok}次" "${stat_fail}次" "${stat_total}次" "$stat_status" "$stat_ban_time" "$stat_unban_time"
                    done < "$tmp_ssh_table"
                fi

                rm -f "$tmp_ssh_stats" "$tmp_ssh_table" "$tmp_ban_events"

                echo "------------------------------------------------"
                echo "说明: 这是日志统计，不会修改或清除日志。"
                echo "日志保留时间取决于 systemd-journald 策略。"

                if docker inspect fail2ban &>/dev/null; then
                    if docker exec fail2ban fail2ban-client ping &>/dev/null; then
                        if docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                            echo "Fail2Ban容器状态:"
                            docker exec fail2ban fail2ban-client status sshd
                        else
                            echo -e "${gl_hong}Fail2Ban运行，但 sshd jail 未启动。${gl_bai}"
                        fi
                    else
                        echo -e "${gl_hong}Fail2Ban服务未正常运行。${gl_bai}"
                    fi
                fi

                read -n1 -r -p "按任意键继续..."
                break
            done
            ;;

        9)
            clear

            if [ "$EUID" -ne 0 ]; then
                echo -e "${gl_hong}请使用 root 用户运行卸载。${gl_bai}"
                read -n1 -r -p "按任意键继续..."
                continue
            fi

            read -e -p "确定卸载 Fail2Ban 并删除 /home/docker/fail2ban 吗？(Y/N): " confirm

            case "$confirm" in

                [Yy])
                    echo "正在清理 Fail2Ban 容器..."
                    docker rm -f fail2ban >/dev/null 2>&1 || true

                    echo "正在清理 SSH 登录即时通知 PAM 配置..."
                    if [ -f /etc/pam.d/sshd ]; then
                        if grep -q '/home/docker/fail2ban/notify/ssh-login-pam-alert.sh' /etc/pam.d/sshd; then
                            cp -a /etc/pam.d/sshd "/etc/pam.d/sshd.bak.remove-ssh-login-notify.$(date +%Y%m%d%H%M%S)"
                            sed -i '\|/home/docker/fail2ban/notify/ssh-login-pam-alert.sh|d' /etc/pam.d/sshd
                        fi
                    fi

                    echo "正在清理 SSH 登录成功通知定时任务..."
                    if command -v crontab >/dev/null 2>&1; then
                        tmp_cron=$(mktemp)
                        crontab -l 2>/dev/null                             | grep -v "ssh-Resend-email-smtp.sh"                             | grep -v "ssh-smtp-email-smtp.sh"                             | grep -v "ssh-login-telegram.sh"                             | grep -v "ssh-login-pam-alert.sh"                             | grep -v "^# ssh登录成功 Telegram 通知$"                             | grep -v "^# ssh登录成功 Resend 通知$"                             | grep -v "^# ssh登录成功 SMTP 通知$"                             | grep -v "^# ssh登录成功 其他API 通知$"                             | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$"                             > "$tmp_cron"
                        crontab "$tmp_cron" 2>/dev/null || true
                        rm -f "$tmp_cron"
                    fi

                    echo "正在清理通知锁和状态文件..."
                    rm -f /tmp/ssh-login-telegram.lock
                    rm -f /tmp/ssh-Resend-email-smtp.lock
                    rm -f /tmp/ssh-smtp-email-smtp.lock
                    rm -f /tmp/ssh-qita-email-smtp.lock
                    rm -f /tmp/ssh-login-pam-alert.lock

                    echo "正在删除本地目录和配置文件..."
                    rm -rf /home/docker/fail2ban
                    rm -f /etc/logrotate.d/fail2ban-docker
                    rm -f /etc/logrotate.d/authlog-ssh

                    echo -e "${gl_lv}Fail2Ban 已卸载，登录成功通知、即时通知、定时任务和 /home/docker/fail2ban 已全部清理。${gl_bai}"
                    ;;

                *)
                    echo "已取消卸载"
                    ;;

            esac

            read -n1 -r -p "按任意键继续..."
            ;;

        7)
            while true; do
                clear
                echo "▶️ 当前封禁的 IP"
                echo "------------------------"
                echo "有成功次数多优先显示"
                echo "其次"
                echo "失败多优先显示"
                echo "------------------------"

                banned_ips=""
                banned_display_ips=""
                fail2ban_conf="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
                whitelist=""
                if [ -f "$fail2ban_conf" ]; then
                    whitelist=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
                fi

                tmp_ssh_stats=$(mktemp)
                tmp_ip_stats=$(mktemp)
                tmp_banned_table=$(mktemp)
                tmp_banned_sorted=$(mktemp)
                tmp_ban_events=$(mktemp)
                fail2ban_prepare_ban_events "$tmp_ban_events"

                if command -v journalctl &>/dev/null; then
                    journalctl -u ssh --since "7 days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi
                if [ ! -s "$tmp_ssh_stats" ] && command -v journalctl &>/dev/null; then
                    journalctl -u sshd --since "7 days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi

                awk '
                {
                    ip=""; type=""
                    if ($0 ~ /Accepted/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="ok"; break }
                    } else if ($0 ~ /Failed password/ || $0 ~ /Invalid user/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="fail"; break }
                    } else if ($0 ~ /authentication failure/) {
                        for (i=1; i<=NF; i++) if ($i ~ /^rhost=/) { ip=$i; sub(/^rhost=/, "", ip); type="fail"; break }
                    }
                    if (ip != "") {
                        gsub(/[^0-9A-Fa-f:.]/, "", ip)
                        if (type == "ok") success[ip]++
                        else if (type == "fail") failed[ip]++
                    }
                }
                END {
                    for (ip in success) seen[ip]=1
                    for (ip in failed) seen[ip]=1
                    for (ip in seen) printf "%s %d %d %d\n", ip, success[ip]+0, failed[ip]+0, success[ip]+failed[ip]
                }' "$tmp_ssh_stats" > "$tmp_ip_stats"

                if ! docker inspect fail2ban &>/dev/null; then
                    echo -e "${gl_hong}未检测到 fail2ban 容器。${gl_bai}"
                elif ! docker exec fail2ban fail2ban-client ping &>/dev/null; then
                    echo -e "${gl_hong}Fail2Ban 服务未正常运行。${gl_bai}"
                elif ! docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                    echo -e "${gl_hong}sshd jail 未启动，请先选择 3 配置。${gl_bai}"
                else
                    banned_ips=$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
                    if [ -z "$banned_ips" ]; then
                        banned_ips=$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
                    fi

                    printf "%-20s %-8s %-8s %-8s %-15s %-15s\n" "IP" "成功" "失败" "总计" "封禁时间" "解封时间"
                    echo "--------------------------------------------------------------------------------"

                    if [ -z "$banned_ips" ]; then
                        echo "当前没有封禁IP"
                    else
                        for ip in $banned_ips; do
                            awk -v qip="$ip" '
                                $1 == qip { print $0; found=1 }
                                END { if (!found) print qip " 0 0 0" }
                            ' "$tmp_ip_stats" >> "$tmp_banned_table"
                        done
                        sort -k2,2nr -k3,3nr -k4,4nr "$tmp_banned_table" > "$tmp_banned_sorted"
                        i=1
                        while read -r stat_ip stat_ok stat_fail stat_total; do
                            read -r stat_ban_time stat_unban_time < <(fail2ban_get_ip_ban_times "$stat_ip" "已封禁" "$tmp_ban_events")
                            if [ "${stat_ok:-0}" -gt 0 ]; then
                                printf "${gl_hong}%s. %-17s %-8s %-8s %-8s %-15s %-15s${gl_bai}\n" "$i" "$stat_ip" "${stat_ok}次" "${stat_fail}次" "${stat_total}次" "$stat_ban_time" "$stat_unban_time"
                            else
                                printf "%s. %-17s %-8s %-8s %-8s %-15s %-15s\n" "$i" "$stat_ip" "${stat_ok}次" "${stat_fail}次" "${stat_total}次" "$stat_ban_time" "$stat_unban_time"
                            fi
                            banned_display_ips="$banned_display_ips $stat_ip"
                            i=$((i + 1))
                        done < "$tmp_banned_sorted"
                    fi
                fi

                rm -f "$tmp_ssh_stats" "$tmp_ip_stats" "$tmp_banned_table" "$tmp_banned_sorted" "$tmp_ban_events"

                echo "------------------------"
                echo "1. 添加封禁IP"
                echo "2. 删除封禁IP"
                echo "0. 退出"
                echo "------------------------"
                read -e -p "请输入你的选择: " banned_choice
                case "$banned_choice" in
                    1)
                        if ! docker inspect fail2ban &>/dev/null || \
                           ! docker exec fail2ban fail2ban-client ping &>/dev/null || \
                           ! docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                            echo -e "${gl_hong}Fail2Ban 或 sshd jail 未正常运行，无法添加封禁。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        read -e -p "请输入要添加封禁的IP: " add_ban_ip
                        if [ -z "$add_ban_ip" ]; then
                            echo "未输入IP"
                        elif echo " $whitelist " | grep -Fqw -- "$add_ban_ip"; then
                            echo -e "${gl_huang}此IP在白名单配置中，白名单优先，无法添加封禁: $add_ban_ip${gl_bai}"
                        else
                            docker exec fail2ban fail2ban-client set sshd banip "$add_ban_ip" >/dev/null 2>&1
                            if [ $? -eq 0 ]; then
                                echo -e "${gl_lv}已添加封禁: $add_ban_ip${gl_bai}"
                            else
                                echo -e "${gl_hong}添加封禁失败: $add_ban_ip${gl_bai}"
                            fi
                        fi
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    2)
                        if ! docker inspect fail2ban &>/dev/null || \
                           ! docker exec fail2ban fail2ban-client ping &>/dev/null || \
                           ! docker exec fail2ban fail2ban-client status sshd &>/dev/null; then
                            echo -e "${gl_hong}Fail2Ban 或 sshd jail 未正常运行，无法删除封禁。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        read -e -p "请输入要删除封禁的IP或序号: " del_ban_input
                        del_ban_ip=""
                        if echo "$del_ban_input" | grep -Eq '^[0-9]+$'; then
                            i=1
                            for ip in $banned_display_ips; do
                                if [ "$i" = "$del_ban_input" ]; then
                                    del_ban_ip="$ip"
                                    break
                                fi
                                i=$((i + 1))
                            done
                        else
                            del_ban_ip="$del_ban_input"
                        fi
                        if [ -z "$del_ban_ip" ]; then
                            echo "未找到该封禁IP"
                        else
                            docker exec fail2ban fail2ban-client set sshd unbanip "$del_ban_ip" >/dev/null 2>&1
                            if [ $? -eq 0 ]; then
                                echo -e "${gl_lv}已删除封禁: $del_ban_ip${gl_bai}"
                            else
                                echo -e "${gl_hong}删除封禁失败: $del_ban_ip${gl_bai}"
                            fi
                        fi
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    0) break ;;
                    *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                esac
            done
            ;;

        6)
            while true; do
                clear
                echo "▶️ Fail2Ban SSH 白名单"
                echo "------------------------"
                echo "成功多优先显示"
                echo "------------------------"
                fail2ban_conf="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
                fail2ban_default_conf="/home/docker/fail2ban/config/fail2ban/jail.local"
                if [ ! -f "$fail2ban_conf" ]; then
                    echo -e "${gl_hong}未找到配置文件，请先选择 3 配置 SSH 防暴力破解。${gl_bai}"
                    read -n1 -r -p "按任意键继续..."
                    break
                fi
                whitelist=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$fail2ban_conf" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
                whitelist=${whitelist:-127.0.0.1/8 ::1}
                whitelist_display_ips=""

                tmp_ssh_stats=$(mktemp)
                tmp_ip_stats=$(mktemp)
                tmp_whitelist_table=$(mktemp)
                tmp_whitelist_sorted=$(mktemp)

                if command -v journalctl &>/dev/null; then
                    journalctl -u ssh --since "7 days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi
                if [ ! -s "$tmp_ssh_stats" ] && command -v journalctl &>/dev/null; then
                    journalctl -u sshd --since "7 days ago" --no-pager 2>/dev/null \
                        | grep -E 'sshd.*(Accepted|Failed password|Invalid user|authentication failure)' \
                        > "$tmp_ssh_stats"
                fi

                awk '
                {
                    ip=""; type=""
                    if ($0 ~ /Accepted/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="ok"; break }
                    } else if ($0 ~ /Failed password/ || $0 ~ /Invalid user/) {
                        for (i=1; i<=NF; i++) if ($i == "from") { ip=$(i+1); type="fail"; break }
                    } else if ($0 ~ /authentication failure/) {
                        for (i=1; i<=NF; i++) if ($i ~ /^rhost=/) { ip=$i; sub(/^rhost=/, "", ip); type="fail"; break }
                    }
                    if (ip != "") {
                        gsub(/[^0-9A-Fa-f:.]/, "", ip)
                        if (type == "ok") success[ip]++
                        else if (type == "fail") failed[ip]++
                    }
                }
                END {
                    for (ip in success) seen[ip]=1
                    for (ip in failed) seen[ip]=1
                    for (ip in seen) printf "%s %d %d %d\n", ip, success[ip]+0, failed[ip]+0, success[ip]+failed[ip]
                }' "$tmp_ssh_stats" > "$tmp_ip_stats"

                for ip in $whitelist; do
                    awk -v qip="$ip" '
                        $1 == qip { print $0; found=1 }
                        END { if (!found) print qip " 0 0 0" }
                    ' "$tmp_ip_stats" >> "$tmp_whitelist_table"
                done
                sort -k2,2nr -k4,4nr "$tmp_whitelist_table" > "$tmp_whitelist_sorted"

                printf "%-20s %-8s %-8s %-8s\n" "IP" "成功" "失败" "总计"
                echo "------------------------------------------------"
                idx=1
                while read -r stat_ip stat_ok stat_fail stat_total; do
                    printf "%s. %-17s %-8s %-8s %-8s\n" "$idx" "$stat_ip" "${stat_ok}次" "${stat_fail}次" "${stat_total}次"
                    whitelist_display_ips="$whitelist_display_ips $stat_ip"
                    idx=$((idx + 1))
                done < "$tmp_whitelist_sorted"

                rm -f "$tmp_ssh_stats" "$tmp_ip_stats" "$tmp_whitelist_table" "$tmp_whitelist_sorted"

                echo "------------------------"
                echo "1. 添加白名单IP"
                echo "2. 删除白名单IP"
                echo "0. 退出"
                echo "------------------------"
                read -e -p "请输入你的选择: " whitelist_choice
                case "$whitelist_choice" in
                    1)
                        read -e -p "请输入要添加的白名单IP: " add_ip
                        if [ -z "$add_ip" ]; then
                            echo "未输入IP"
                        elif echo " $whitelist " | grep -Fqw -- "$add_ip"; then
                            echo "该IP已在白名单中"
                        else
                            whitelist="$whitelist $add_ip"
                            sed -i "s|^[[:space:]]*ignoreip[[:space:]]*=.*|ignoreip = $whitelist|" "$fail2ban_conf"
                            [ -f "$fail2ban_default_conf" ] && sed -i "s|^[[:space:]]*ignoreip[[:space:]]*=.*|ignoreip = $whitelist|" "$fail2ban_default_conf"
                            if docker inspect fail2ban &>/dev/null && docker exec fail2ban fail2ban-client ping &>/dev/null; then
                                docker exec fail2ban fail2ban-client set sshd unbanip "$add_ip" >/dev/null 2>&1 || true
                            fi
                            docker restart fail2ban >/dev/null 2>&1 || true
                            echo "已添加: $add_ip"
                            echo "如果该IP原来被封禁，已尝试自动解除封禁。"
                        fi
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    2)
                        read -e -p "请输入要删除的序号: " del_idx
                        if ! echo "$del_idx" | grep -Eq '^[0-9]+$'; then
                            echo "序号无效"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        new_whitelist=""
                        idx=1
                        deleted_ip=""
                        for ip in $whitelist_display_ips; do
                            if [ "$idx" = "$del_idx" ]; then
                                deleted_ip="$ip"
                            else
                                new_whitelist="$new_whitelist $ip"
                            fi
                            idx=$((idx + 1))
                        done
                        new_whitelist=$(echo "$new_whitelist" | xargs)
                        if [ -z "$deleted_ip" ]; then
                            echo "未找到该序号"
                        elif [ -z "$new_whitelist" ]; then
                            echo "白名单不能为空，已取消删除"
                        else
                            sed -i "s|^[[:space:]]*ignoreip[[:space:]]*=.*|ignoreip = $new_whitelist|" "$fail2ban_conf"
                            [ -f "$fail2ban_default_conf" ] && sed -i "s|^[[:space:]]*ignoreip[[:space:]]*=.*|ignoreip = $new_whitelist|" "$fail2ban_default_conf"
                            docker restart fail2ban >/dev/null 2>&1 || true
                            echo "已删除: $deleted_ip"
                        fi
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    0) break ;;
                    *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                esac
            done
            ;;

        8)
            while true; do
                clear
                echo "▶️ 日志占用/手动清理"
                echo "------------------------"
                echo "1. 查看 systemd-journald 日志占用"
                echo "2. 查看 systemd-journald 启动日志列表"
                echo "3. 查看 Fail2Ban 本地目录大小"
                echo "4. 查看 SSH 登录日志文件大小"
                echo "9. 手动清理 systemd-journald 日志（不修改默认策略）"
                echo "0. 退出"
                echo "------------------------"
                read -e -p "请输入你的选择: " log_size_choice
                case "$log_size_choice" in
                    1)
                        clear
                        echo "▶️ systemd-journald 日志占用"
                        echo "------------------------"
                        if command -v journalctl &>/dev/null; then
                            journalctl --disk-usage
                        else
                            echo -e "${gl_hong}当前系统未找到 journalctl。${gl_bai}"
                        fi
                        echo "------------------------"
                        echo "说明: 这是 systemd-journald 系统日志占用，不是 Fail2Ban 专属日志。"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    2)
                        clear
                        echo "▶️ systemd-journald 启动日志列表"
                        echo "------------------------"
                        if command -v journalctl &>/dev/null; then
                            journalctl --list-boots
                        else
                            echo -e "${gl_hong}当前系统未找到 journalctl。${gl_bai}"
                        fi
                        echo "------------------------"
                        echo "说明: 显示系统保存了哪些开机周期的 journal 日志。"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    3)
                        clear
                        echo "▶️ Fail2Ban 本地目录大小"
                        echo "------------------------"
                        if [ -d /home/docker/fail2ban ]; then
                            du -sh /home/docker/fail2ban 2>/dev/null
                            echo "------------------------"
                            du -h --max-depth=2 /home/docker/fail2ban 2>/dev/null | sort -hr | head -30
                        else
                            echo -e "${gl_huang}未找到目录: /home/docker/fail2ban${gl_bai}"
                        fi
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    4)
                        clear
                        echo "▶️ SSH 登录日志文件大小"
                        echo "------------------------"
                        found_log="false"
                        for log_file in /var/log/auth.log /var/log/auth.log.* /var/log/secure /var/log/secure.*; do
                            if [ -e "$log_file" ]; then
                                found_log="true"
                                du -h "$log_file" 2>/dev/null
                            fi
                        done
                        if [ "$found_log" != "true" ]; then
                            echo -e "${gl_huang}未找到 /var/log/auth.log 或 /var/log/secure 相关日志文件。${gl_bai}"
                        fi
                        echo "------------------------"
                        echo "说明: 这些是 SSH 登录成功/失败统计可能读取的本机日志文件。"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    9)
                        clear
                        echo "▶️ 手动清理 systemd-journald 日志"
                        echo "------------------------"
                        echo "说明: 只执行本次清理，不修改 /etc/systemd/journald.conf 默认策略。"
                        echo "清理目标: 保留最近7天，并尽量控制 journal 总占用不超过 200M。"
                        echo "影响范围: systemd-journald 系统日志，不是 Fail2Ban 专属日志。"
                        echo "------------------------"
                        if ! command -v journalctl &>/dev/null; then
                            echo -e "${gl_hong}当前系统未找到 journalctl。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        echo "清理前占用:"
                        journalctl --disk-usage
                        echo "------------------------"
                        read -e -p "确定执行本次 journal 日志清理吗？(Y/N): " clean_confirm
                        case "$clean_confirm" in
                            [Yy])
                                journalctl --vacuum-time=7d
                                journalctl --vacuum-size=200M
                                echo "------------------------"
                                echo "清理后占用:"
                                journalctl --disk-usage
                                echo -e "${gl_lv}清理完成，系统默认日志策略未修改。${gl_bai}"
                                ;;
                            *)
                                echo "已取消清理"
                                ;;
                        esac
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    0) break ;;
                    *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                esac
            done
            ;;

        999)
            while true; do
                clear
                echo "▶️ SSH 登录成功通知"
                echo -e "${gl_lv}================================${gl_bai}"
                echo "电报通知"
                tg_cron=$(crontab -l 2>/dev/null | grep 'ssh-login-telegram.sh' | grep -v '^#' | head -n1)
                if [ -n "$tg_cron" ]; then
                    echo -e "${gl_lv}${tg_cron}${gl_bai}"
                    tg_status="已添加"
                else
                    echo -e "${gl_lv}暂无${gl_bai}"
                    tg_status="暂无"
                fi
                echo -e "${gl_kjlan}------------------------${gl_bai}"
                echo "邮件Resend通知"
                mail_resend_cron=$(crontab -l 2>/dev/null | grep 'ssh-Resend-email-smtp.sh' | grep -v '^#' | head -n1)
                [ -n "$mail_resend_cron" ] && echo -e "${gl_lv}${mail_resend_cron}${gl_bai}" || echo -e "${gl_lv}暂无${gl_bai}"
                echo -e "${gl_kjlan}------------------------${gl_bai}"
                echo "邮件SMTP通知"
                mail_smtp_cron=$(crontab -l 2>/dev/null | grep 'ssh-smtp-email-smtp.sh' | grep -v '^#' | head -n1)
                [ -n "$mail_smtp_cron" ] && echo -e "${gl_lv}${mail_smtp_cron}${gl_bai}" || echo -e "${gl_lv}暂无${gl_bai}"
                echo -e "${gl_kjlan}------------------------${gl_bai}"
                echo "其他API邮件通知"
                mail_qita_cron=$(crontab -l 2>/dev/null | grep 'ssh-qita-email-smtp.sh' | grep -v '^#' | head -n1)
                [ -n "$mail_qita_cron" ] && echo -e "${gl_lv}${mail_qita_cron}${gl_bai}" || echo -e "${gl_lv}暂无${gl_bai}"
                if [ -n "$mail_resend_cron$mail_smtp_cron$mail_qita_cron" ]; then mail_status="已添加"; else mail_status="暂无"; fi
                echo -e "${gl_kjlan}------------------------${gl_bai}"
                echo -e "${gl_huang}即时通知保护${gl_bai}"
                if grep -q '/home/docker/fail2ban/notify/ssh-login-pam-alert.sh' /etc/pam.d/sshd 2>/dev/null; then
                    echo -e "${gl_lv}已开启${gl_bai}"
                    pam_status="已开启"
                else
                    echo -e "${gl_hong}未启用${gl_bai}"
                    pam_status="未启用"
                fi
                echo -e "${gl_kjlan}------------------------${gl_bai}"
                echo -e "${gl_huang}白名单是否通知${gl_bai}"
                if [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ]; then
                    echo -e "${gl_hong}不通知${gl_bai}"
                    whitelist_skip_status="已启用"
                    whitelist_skip_color="${gl_hong}"
                else
                    echo -e "${gl_lv}通知${gl_bai}"
                    whitelist_skip_status="未启用"
                    whitelist_skip_color="${gl_huang}"
                fi
                echo -e "${gl_lv}================================${gl_bai}"
                echo "1. 登录成功Telegram通知（${tg_status}）"
                echo "2. 登录成功邮件通知（${mail_status}）"
                echo -e "${gl_huang}3. 开启 SSH 登录即时通知保护（${pam_status}）${gl_bai}"
                echo -e "${gl_lv}4. 关闭 SSH 登录即时通知保护${gl_bai}"
                echo -e "${whitelist_skip_color}5. 白名单不通知（${whitelist_skip_status}）${gl_bai}"
                echo -e "${gl_lv}6. 关闭白名单不通知${gl_bai}"
                echo "7.发送测试消息"
                echo -e "${gl_hong}9. 删除全部通知任务${gl_bai}"
                echo "0. 返回"
                echo -e "${gl_kjlan}------------------------${gl_bai}"
                read -e -p "请输入你的选择: " ssh_notify_choice
                case "$ssh_notify_choice" in
                    1)
                        clear
                        echo "▶️ SSH 登录成功 Telegram 通知"
                        echo -e "${gl_lv}================================${gl_bai}"
                        echo "1. 添加 Telegram 通知"
                        echo "2. 删除 Telegram 通知"
                        echo "0. 返回"
                        echo -e "${gl_lv}================================${gl_bai}"
                        read -e -p "请输入你的选择: " ssh_tg_mode
                        case "$ssh_tg_mode" in
                            1)
            if [ -f /home/docker/fail2ban/notify/ssh-login-telegram.sh ] || crontab -l 2>/dev/null | grep -q 'ssh-login-telegram.sh'; then
                echo -e "${gl_huang}Telegram通知 当前任务已添加。${gl_bai}"
                read -e -p "输入 Y 确认覆盖，其他键取消: " overwrite_confirm
                case "$overwrite_confirm" in [Yy]) ;; *) echo "已取消"; read -n1 -r -p "按任意键继续..."; continue ;; esac
            fi
            read -e -p "请输入备注名称: " SSH_NOTIFY_REMARK
            read -e -p "请输入 Bot Token: " SSH_BOT_TOKEN
            SSH_BOT_TOKEN=$(echo "$SSH_BOT_TOKEN" | sed 's#https://api.telegram.org/bot##g' | sed 's#/sendMessage##g')
            read -e -p "请输入 Chat ID: " SSH_CHAT_ID
            mkdir -p /home/docker/fail2ban/notify
            cat > /home/docker/fail2ban/notify/ssh-login-telegram.sh <<EOF
#!/bin/bash
set -u
REMARK="${SSH_NOTIFY_REMARK}"
BOT_TOKEN="${SSH_BOT_TOKEN}"
CHAT_ID="${SSH_CHAT_ID}"
STATE_FILE="/home/docker/fail2ban/notify/ssh-login-telegram.state"
LOCK_FILE="/tmp/ssh-login-telegram.lock"
HOSTNAME=\$(hostname 2>/dev/null || echo unknown)
SERVER_IP=\$(curl -s -m 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print \$1}')
[ -f "\$STATE_FILE" ] || date +%s > "\$STATE_FILE"
LAST_TS=\$(cat "\$STATE_FILE" 2>/dev/null || date +%s)
NOW_TS=\$(date +%s)
if [ "\${1:-}" = "--test" ]; then
    USER="\${USER:-root}"
    IP="\${SSH_CLIENT:-}"; IP="\${IP%% *}"; [ -z "\$IP" ] && IP="127.0.0.1"
    IP_STATUS="测试"
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    TEXT="🔐 SSH登录成功提醒

这是一个SSH登录成功提醒测试消息

备注: \$REMARK
👤 用户: \${USER:-root}
🛡️ IP状态: \$IP_STATUS
🌐 IP: \$IP
⏰ 时间: \$TIME_TEXT"
    curl -s -m 15 "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" -d chat_id="\$CHAT_ID" --data-urlencode text="\$TEXT" >/dev/null 2>&1 || true
    exit 0
fi
(
flock -n 9 || exit 0
TMP_LOG=\$(mktemp)
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ssh --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    if [ ! -s "\$TMP_LOG" ]; then
        journalctl -u sshd --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    fi
fi
while IFS= read -r line; do
    USER=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="for") {print \$(i+1); exit}}')
    IP=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="from") {print \$(i+1); exit}}')
    PORT=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="port") {print \$(i+1); exit}}')
    PAM_STATE_FILE="/home/docker/fail2ban/notify/ssh-login-pam-alert.state"
    if [ -f "\$PAM_STATE_FILE" ]; then
        PAM_LAST_KEY=""
        PAM_LAST_TS="0"
        read -r PAM_LAST_KEY PAM_LAST_TS < "\$PAM_STATE_FILE" || true
        if [ "\${USER:-未知}|\${IP:-未知}" = "\$PAM_LAST_KEY" ] && [ \$((NOW_TS - \${PAM_LAST_TS:-0})) -lt 120 ]; then
            continue
        fi
    fi
    IP_STATUS="未封禁"
    FAIL2BAN_CONF="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
    if [ -n "\${IP:-}" ] && [ -f "\$FAIL2BAN_CONF" ]; then
        IGNORE_IPS=\$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "\$FAIL2BAN_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
        if echo " \$IGNORE_IPS " | grep -Fqw -- "\$IP"; then
            IP_STATUS="白名单"
        elif docker inspect fail2ban >/dev/null 2>&1 && docker exec fail2ban fail2ban-client status sshd >/dev/null 2>&1; then
            BANNED_IPS=\$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
            [ -z "\$BANNED_IPS" ] && BANNED_IPS=\$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
            if echo " \$BANNED_IPS " | grep -Fqw -- "\$IP"; then
                IP_STATUS="已封禁"
            fi
        fi
    fi
    if [ "\$IP_STATUS" = "白名单" ] && [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ]; then
        continue
    fi
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    TEXT="🔐 SSH登录成功提醒

备注: \$REMARK
👤 用户: \${USER:-未知}
🛡️ IP状态: \$IP_STATUS
🌐 IP: \${IP:-未知}
⏰ 时间: \$TIME_TEXT"
    curl -s -m 15 "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
      -d chat_id="\$CHAT_ID" \
      --data-urlencode text="\$TEXT" >/dev/null 2>&1 || true
    sleep 1
done < "\$TMP_LOG"
echo "\$NOW_TS" > "\$STATE_FILE"
rm -f "\$TMP_LOG"
) 9>"\$LOCK_FILE"
EOF
            chmod 700 /home/docker/fail2ban/notify/ssh-login-telegram.sh
            date +%s > /home/docker/fail2ban/notify/ssh-login-telegram.state
            ( crontab -l 2>/dev/null | grep -v "ssh-login-telegram.sh" | grep -v "^# ssh登录成功 Telegram 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$"; echo "# ssh登录成功 Telegram 通知"; echo "* * * * * /bin/bash /home/docker/fail2ban/notify/ssh-login-telegram.sh >/dev/null 2>&1" ) | crontab -
            echo -e "${gl_lv}SSH 登录成功 Telegram 通知已添加。${gl_bai}"
            echo "脚本: /home/docker/fail2ban/notify/ssh-login-telegram.sh"
            echo "频率: 每分钟检查一次，只通知安装后新登录记录。"
            read -n1 -r -p "按任意键继续..."
                                ;;
                            2)
                    read -e -p "确定删除 SSH 登录成功 Telegram 通知吗？(Y/N): " confirm_del_tg
                    case "$confirm_del_tg" in
                        [Yy])
                            crontab -l 2>/dev/null | grep -v "ssh-login-telegram.sh" | grep -v "^# ssh登录成功 Telegram 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$" | crontab -
                            rm -f /home/docker/fail2ban/notify/ssh-login-telegram.sh
                            rm -f /home/docker/fail2ban/notify/ssh-login-telegram.state
                            echo -e "${gl_lv}SSH 登录成功 Telegram 通知已删除，相关定时任务已清理。${gl_bai}"
                            ;;
                        *) echo "已取消删除" ;;
                    esac
                    read -n1 -r -p "按任意键继续..."
                                ;;
                            0) ;;
                            *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                        esac
                        ;;
                    2)
                        clear
                        echo "▶️ SSH 登录成功邮件通知"
                        echo -e "${gl_lv}================================${gl_bai}"
                        echo "1. 使用 Resend API 发信"
                        echo "2. 使用 SMTP 发信（部分VPS可能不支持）"
                        echo "3. 使用 其他 API 发信"
                        echo "4. 删除邮件通知"
                        echo "0. 返回"
                        echo -e "${gl_lv}================================${gl_bai}"
                        read -e -p "请输入你的选择: " ssh_mail_mode
                        case "$ssh_mail_mode" in
                            1)
                    if [ -f /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh ] || crontab -l 2>/dev/null | grep -q 'ssh-Resend-email-smtp.sh'; then
                        echo -e "${gl_huang}Resend邮件通知 当前任务已添加。${gl_bai}"
                        read -e -p "输入 Y 确认覆盖，其他键取消: " overwrite_confirm
                        case "$overwrite_confirm" in [Yy]) ;; *) echo "已取消"; read -n1 -r -p "按任意键继续..."; continue ;; esac
                    fi
                    read -e -p "请输入备注名称: " SSH_NOTIFY_REMARK
                    read -e -p "请输入 Resend API Key: " SSH_RESEND_KEY
                    read -e -p "请输入发件邮箱(From): " SSH_FROM_EMAIL
                    read -e -p "请输入收件邮箱(To): " SSH_TO_EMAIL
                    mkdir -p /home/docker/fail2ban/notify
                    cat > /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh <<EOF
#!/bin/bash
set -u
REMARK="${SSH_NOTIFY_REMARK}"
RESEND_KEY="${SSH_RESEND_KEY}"
FROM_EMAIL="${SSH_FROM_EMAIL}"
TO_EMAIL="${SSH_TO_EMAIL}"
STATE_FILE="/home/docker/fail2ban/notify/ssh-Resend-email-smtp.state"
LOCK_FILE="/tmp/ssh-Resend-email-smtp.lock"
HOSTNAME=\$(hostname 2>/dev/null || echo unknown)
SERVER_IP=\$(curl -s -m 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print \$1}')
if [ "\${1:-}" = "--test" ]; then
    USER="\${USER:-root}"
    IP="\${SSH_CLIENT:-}"; IP="\${IP%% *}"; [ -z "\$IP" ] && IP="127.0.0.1"
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    BODY="🔐 SSH登录成功提醒

这是一个SSH登录成功提醒测试邮件

备注: \$REMARK
👤 用户: \${USER:-root}
🛡️ IP状态: 测试
🌐 IP: \$IP
⏰ 时间: \$TIME_TEXT"
    curl -s -m 15 https://api.resend.com/emails \
      -H "Authorization: Bearer \$RESEND_KEY" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "from=\$FROM_EMAIL" \
      --data-urlencode "to=\$TO_EMAIL" \
      --data-urlencode "subject=[\$REMARK] [Resend API]SSH登录成功提醒测试邮件 \$IP \$(date '+%Y/%m/%d %H:%M:%S')" \
      --data-urlencode "text=\$BODY" >/dev/null 2>&1 || true
    exit 0
fi
[ -f "\$STATE_FILE" ] || date +%s > "\$STATE_FILE"
LAST_TS=\$(cat "\$STATE_FILE" 2>/dev/null || date +%s)
NOW_TS=\$(date +%s)
(
flock -n 9 || exit 0
TMP_LOG=\$(mktemp)
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ssh --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    if [ ! -s "\$TMP_LOG" ]; then
        journalctl -u sshd --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    fi
fi
while IFS= read -r line; do
    USER=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="for") {print \$(i+1); exit}}')
    IP=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="from") {print \$(i+1); exit}}')
    PORT=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="port") {print \$(i+1); exit}}')
    PAM_STATE_FILE="/home/docker/fail2ban/notify/ssh-login-pam-alert.state"
    if [ -f "\$PAM_STATE_FILE" ]; then
        PAM_LAST_KEY=""
        PAM_LAST_TS="0"
        read -r PAM_LAST_KEY PAM_LAST_TS < "\$PAM_STATE_FILE" || true
        if [ "\${USER:-未知}|\${IP:-未知}" = "\$PAM_LAST_KEY" ] && [ \$((NOW_TS - \${PAM_LAST_TS:-0})) -lt 120 ]; then
            continue
        fi
    fi
    IP_STATUS="未封禁"
    FAIL2BAN_CONF="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
    if [ -n "\${IP:-}" ] && [ -f "\$FAIL2BAN_CONF" ]; then
        IGNORE_IPS=\$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "\$FAIL2BAN_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
        if echo " \$IGNORE_IPS " | grep -Fqw -- "\$IP"; then
            IP_STATUS="白名单"
        elif docker inspect fail2ban >/dev/null 2>&1 && docker exec fail2ban fail2ban-client status sshd >/dev/null 2>&1; then
            BANNED_IPS=\$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
            [ -z "\$BANNED_IPS" ] && BANNED_IPS=\$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
            if echo " \$BANNED_IPS " | grep -Fqw -- "\$IP"; then
                IP_STATUS="已封禁"
            fi
        fi
    fi
    if [ "\$IP_STATUS" = "白名单" ] && [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ]; then
        continue
    fi
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    BODY="🔐 SSH登录成功提醒

备注: \$REMARK
👤 用户: \${USER:-未知}
🛡️ IP状态: \$IP_STATUS
🌐 IP: \${IP:-未知}
⏰ 时间: \$TIME_TEXT"
    curl -s -m 15 https://api.resend.com/emails \
      -H "Authorization: Bearer \$RESEND_KEY" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "from=\$FROM_EMAIL" \
      --data-urlencode "to=\$TO_EMAIL" \
      --data-urlencode "subject=[\$REMARK] [Resend API]SSH登录成功提醒 \${IP:-未知} \$(date '+%Y/%m/%d %H:%M:%S')" \
      --data-urlencode "text=\$BODY" >/dev/null 2>&1 || true
    sleep 1
done < "\$TMP_LOG"
echo "\$NOW_TS" > "\$STATE_FILE"
rm -f "\$TMP_LOG"
) 9>"\$LOCK_FILE"
EOF
                    chmod 700 /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh
                    date +%s > /home/docker/fail2ban/notify/ssh-Resend-email-smtp.state
                    ( crontab -l 2>/dev/null | grep -v "ssh-Resend-email-smtp.sh" | grep -v "^# ssh登录成功 Resend 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$"; echo "# ssh登录成功 Resend 通知"; echo "* * * * * /bin/bash /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh >/dev/null 2>&1" ) | crontab -
                    echo -e "${gl_lv}SSH 登录成功 Resend 邮件通知已添加。${gl_bai}"
                    echo "脚本: /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh"
                    echo "频率: 每分钟检查一次，只通知安装后新登录记录。"
                    read -n1 -r -p "按任意键继续..."
                                ;;
                            2)
                    if [ -f /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh ] || crontab -l 2>/dev/null | grep -q 'ssh-smtp-email-smtp.sh'; then
                        echo -e "${gl_huang}SMTP邮件通知 当前任务已添加。${gl_bai}"
                        read -e -p "输入 Y 确认覆盖，其他键取消: " overwrite_confirm
                        case "$overwrite_confirm" in [Yy]) ;; *) echo "已取消"; read -n1 -r -p "按任意键继续..."; continue ;; esac
                    fi
                    fail2ban_ensure_python3 || { read -n1 -r -p "按任意键继续..."; continue; }
                    read -e -p "请输入备注名称: " SSH_NOTIFY_REMARK
                    read -e -p "请输入 SMTP服务器: " SSH_SMTP_HOST
                    read -e -p "请输入 SMTP端口465或者587 [默认: 587]: " SSH_SMTP_PORT
                    SSH_SMTP_PORT=${SSH_SMTP_PORT:-587}
                    read -e -p "是否启用SSL? 465端口通常选Y，587通常选N (Y/N) [默认: N]: " SSH_SMTP_SSL
                    SSH_SMTP_SSL=${SSH_SMTP_SSL:-N}
                    read -e -p "请输入 SMTP用户名: " SSH_SMTP_USER
                    read -s -p "请输入 SMTP密码/授权码: " SSH_SMTP_PASS
                    echo
                    read -e -p "请输入发件邮箱(From): " SSH_FROM_EMAIL
                    read -e -p "请输入收件邮箱(To): " SSH_TO_EMAIL
                    mkdir -p /home/docker/fail2ban/notify
                    cat > /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh <<EOF
#!/bin/bash
set -u
REMARK="${SSH_NOTIFY_REMARK}"
SMTP_HOST="${SSH_SMTP_HOST}"
SMTP_PORT="${SSH_SMTP_PORT}"
SMTP_SSL="${SSH_SMTP_SSL}"
SMTP_USER="${SSH_SMTP_USER}"
SMTP_PASS="${SSH_SMTP_PASS}"
FROM_EMAIL="${SSH_FROM_EMAIL}"
TO_EMAIL="${SSH_TO_EMAIL}"
STATE_FILE="/home/docker/fail2ban/notify/ssh-smtp-email-smtp.state"
LOCK_FILE="/tmp/ssh-smtp-email-smtp.lock"
HOSTNAME=\$(hostname 2>/dev/null || echo unknown)
SERVER_IP=\$(curl -s -m 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print \$1}')
if [ "\${1:-}" = "--test" ]; then
    USER="\${USER:-root}"
    IP="\${SSH_CLIENT:-}"; IP="\${IP%% *}"; [ -z "\$IP" ] && IP="127.0.0.1"
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    BODY="🔐 SSH登录成功提醒

这是一个SSH登录成功提醒测试邮件

备注: \$REMARK
👤 用户: \${USER:-root}
🛡️ IP状态: 测试
🌐 IP: \$IP
⏰ 时间: \$TIME_TEXT"
    export SMTP_HOST SMTP_PORT SMTP_SSL SMTP_USER SMTP_PASS FROM_EMAIL TO_EMAIL
    SMTP_SUBJECT="[\$REMARK] [SMTP]SSH登录成功提醒测试邮件 \$IP \$(date '+%Y/%m/%d %H:%M:%S')" SMTP_BODY="\$BODY" python3 - <<'PYEOF' >/dev/null 2>&1 || true
import os, smtplib, ssl
from email.message import EmailMessage
msg = EmailMessage()
msg['From'] = os.environ['FROM_EMAIL']
msg['To'] = os.environ['TO_EMAIL']
msg['Subject'] = os.environ.get('SMTP_SUBJECT', 'SSH 登录成功测试消息')
msg.set_content(os.environ.get('SMTP_BODY', ''))
host=os.environ['SMTP_HOST']; port=int(os.environ.get('SMTP_PORT','587'))
use_ssl=os.environ.get('SMTP_SSL','N').lower().startswith('y')
user=os.environ.get('SMTP_USER',''); password=os.environ.get('SMTP_PASS','')
if use_ssl:
    server=smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context())
else:
    server=smtplib.SMTP(host, port, timeout=20)
    server.ehlo()
    if port != 25:
        server.starttls(context=ssl.create_default_context())
        server.ehlo()
if user:
    server.login(user, password)
server.send_message(msg)
server.quit()
PYEOF
    exit 0
fi
[ -f "\$STATE_FILE" ] || date +%s > "\$STATE_FILE"
LAST_TS=\$(cat "\$STATE_FILE" 2>/dev/null || date +%s)
NOW_TS=\$(date +%s)
(
flock -n 9 || exit 0
TMP_LOG=\$(mktemp)
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ssh --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    if [ ! -s "\$TMP_LOG" ]; then
        journalctl -u sshd --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    fi
fi
while IFS= read -r line; do
    USER=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="for") {print \$(i+1); exit}}')
    IP=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="from") {print \$(i+1); exit}}')
    PORT=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="port") {print \$(i+1); exit}}')
    PAM_STATE_FILE="/home/docker/fail2ban/notify/ssh-login-pam-alert.state"
    if [ -f "\$PAM_STATE_FILE" ]; then
        PAM_LAST_KEY=""
        PAM_LAST_TS="0"
        read -r PAM_LAST_KEY PAM_LAST_TS < "\$PAM_STATE_FILE" || true
        if [ "\${USER:-未知}|\${IP:-未知}" = "\$PAM_LAST_KEY" ] && [ \$((NOW_TS - \${PAM_LAST_TS:-0})) -lt 120 ]; then
            continue
        fi
    fi
    IP_STATUS="未封禁"
    FAIL2BAN_CONF="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
    if [ -n "\${IP:-}" ] && [ -f "\$FAIL2BAN_CONF" ]; then
        IGNORE_IPS=\$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "\$FAIL2BAN_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
        if echo " \$IGNORE_IPS " | grep -Fqw -- "\$IP"; then
            IP_STATUS="白名单"
        elif docker inspect fail2ban >/dev/null 2>&1 && docker exec fail2ban fail2ban-client status sshd >/dev/null 2>&1; then
            BANNED_IPS=\$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
            [ -z "\$BANNED_IPS" ] && BANNED_IPS=\$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
            if echo " \$BANNED_IPS " | grep -Fqw -- "\$IP"; then
                IP_STATUS="已封禁"
            fi
        fi
    fi
    if [ "\$IP_STATUS" = "白名单" ] && [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ]; then
        continue
    fi
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    BODY="🔐 SSH登录成功提醒

备注: \$REMARK
👤 用户: \${USER:-未知}
🛡️ IP状态: \$IP_STATUS
🌐 IP: \${IP:-未知}
⏰ 时间: \$TIME_TEXT"
    export SMTP_HOST SMTP_PORT SMTP_SSL SMTP_USER SMTP_PASS FROM_EMAIL TO_EMAIL
    SMTP_SUBJECT="[\$REMARK] [SMTP]SSH登录成功提醒 \${IP:-未知} \$(date '+%Y/%m/%d %H:%M:%S')" SMTP_BODY="\$BODY" python3 - <<'PYEOF' || true
import os, smtplib, ssl
from email.message import EmailMessage
msg = EmailMessage()
msg['From'] = os.environ['FROM_EMAIL']
msg['To'] = os.environ['TO_EMAIL']
msg['Subject'] = os.environ.get('SMTP_SUBJECT', 'SSH 登录成功通知')
msg.set_content(os.environ.get('SMTP_BODY', ''))
host=os.environ['SMTP_HOST']; port=int(os.environ.get('SMTP_PORT','587'))
use_ssl=os.environ.get('SMTP_SSL','N').lower().startswith('y')
user=os.environ.get('SMTP_USER',''); password=os.environ.get('SMTP_PASS','')
if use_ssl:
    server=smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context())
else:
    server=smtplib.SMTP(host, port, timeout=20)
    server.ehlo()
    if port != 25:
        server.starttls(context=ssl.create_default_context())
        server.ehlo()
if user:
    server.login(user, password)
server.send_message(msg)
server.quit()
PYEOF
    sleep 1
done < "\$TMP_LOG"
echo "\$NOW_TS" > "\$STATE_FILE"
rm -f "\$TMP_LOG"
) 9>"\$LOCK_FILE"
EOF
                    chmod 700 /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh
                    date +%s > /home/docker/fail2ban/notify/ssh-smtp-email-smtp.state
                    ( crontab -l 2>/dev/null | grep -v "ssh-smtp-email-smtp.sh" | grep -v "^# ssh登录成功 SMTP 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$"; echo "# ssh登录成功 SMTP 通知"; echo "* * * * * /bin/bash /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh >/dev/null 2>&1" ) | crontab -
                    echo -e "${gl_lv}SSH 登录成功 SMTP 邮件通知已添加。${gl_bai}"
                    echo "脚本: /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh"
                    echo "频率: 每分钟检查一次，只通知安装后新登录记录。"
                    read -n1 -r -p "按任意键继续..."
                                ;;
                            3)
                    if [ -f /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh ] || crontab -l 2>/dev/null | grep -q 'ssh-qita-email-smtp.sh'; then
                        echo -e "${gl_huang}其他API邮件通知 当前任务已添加。${gl_bai}"
                        read -e -p "输入 Y 确认覆盖，其他键取消: " overwrite_confirm
                        case "$overwrite_confirm" in [Yy]) ;; *) echo "已取消"; read -n1 -r -p "按任意键继续..."; continue ;; esac
                    fi
                    read -e -p "请输入备注名称: " SSH_NOTIFY_REMARK
                    read -e -p "请输入 API地址: " SSH_API_URL
                    read -e -p "请输入 API Key: " SSH_API_KEY
                    read -e -p "请输入请求头（回车默认Authorization: Bearer）: " SSH_API_HEADER
                    SSH_API_HEADER=${SSH_API_HEADER:-Authorization: Bearer}
                    read -e -p "请输入发件邮箱(From): " SSH_FROM_EMAIL
                    read -e -p "请输入收件邮箱(To): " SSH_TO_EMAIL
                    mkdir -p /home/docker/fail2ban/notify
                    cat > /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh <<EOF
#!/bin/bash
set -u
REMARK="${SSH_NOTIFY_REMARK}"
API_URL="${SSH_API_URL}"
API_KEY="${SSH_API_KEY}"
API_HEADER="${SSH_API_HEADER}"
API_HEADER="${API_HEADER}"
FROM_EMAIL="${SSH_FROM_EMAIL}"
TO_EMAIL="${SSH_TO_EMAIL}"
STATE_FILE="/home/docker/fail2ban/notify/ssh-qita-email-smtp.state"
LOCK_FILE="/tmp/ssh-qita-email-smtp.lock"
if [ "\${1:-}" = "--test" ]; then
    USER="\${USER:-root}"
    IP="\${SSH_CLIENT:-}"; IP="\${IP%% *}"; [ -z "\$IP" ] && IP="127.0.0.1"
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    BODY="🔐 SSH登录成功提醒

这是一个SSH登录成功提醒测试邮件

备注: \$REMARK
👤 用户: \${USER:-root}
🛡️ IP状态: 测试
🌐 IP: \$IP
⏰ 时间: \$TIME_TEXT"
    curl -s -m 15 "\$API_URL" -H "Authorization: Bearer \$API_KEY" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "from=\$FROM_EMAIL" --data-urlencode "to=\$TO_EMAIL" --data-urlencode "subject=[\$REMARK] [Resend API]SSH登录成功提醒测试邮件 \$IP \$(date '+%Y/%m/%d %H:%M:%S')" --data-urlencode "text=\$BODY" >/dev/null 2>&1 || true
    exit 0
fi
[ -f "\$STATE_FILE" ] || date +%s > "\$STATE_FILE"
LAST_TS=\$(cat "\$STATE_FILE" 2>/dev/null || date +%s)
NOW_TS=\$(date +%s)
(
flock -n 9 || exit 0
TMP_LOG=\$(mktemp)
if command -v journalctl >/dev/null 2>&1; then
    journalctl -u ssh --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
    [ ! -s "\$TMP_LOG" ] && journalctl -u sshd --since "@\$LAST_TS" --until "@\$NOW_TS" --no-pager 2>/dev/null | grep 'sshd.*Accepted' > "\$TMP_LOG" || true
fi
while IFS= read -r line; do
    USER=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="for") {print \$(i+1); exit}}')
    IP=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="from") {print \$(i+1); exit}}')
    PAM_STATE_FILE="/home/docker/fail2ban/notify/ssh-login-pam-alert.state"
    if [ -f "\$PAM_STATE_FILE" ]; then read -r PAM_LAST_KEY PAM_LAST_TS < "\$PAM_STATE_FILE" || true; [ "\${USER:-未知}|\${IP:-未知}" = "\${PAM_LAST_KEY:-}" ] && [ \$((NOW_TS - \${PAM_LAST_TS:-0})) -lt 120 ] && continue; fi
    IP_STATUS="未封禁"
    FAIL2BAN_CONF="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
    if [ -n "\${IP:-}" ] && [ -f "\$FAIL2BAN_CONF" ]; then IGNORE_IPS=\$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "\$FAIL2BAN_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs); echo " \$IGNORE_IPS " | grep -Fqw -- "\$IP" && IP_STATUS="白名单"; fi
    [ "\$IP_STATUS" = "白名单" ] && [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ] && continue
    TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
    BODY="🔐 SSH登录成功提醒

备注: \$REMARK
👤 用户: \${USER:-未知}
🛡️ IP状态: \$IP_STATUS
🌐 IP: \${IP:-未知}
⏰ 时间: \$TIME_TEXT"
    curl -s -m 15 "\$API_URL" -H "Authorization: Bearer \$API_KEY" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "from=\$FROM_EMAIL" --data-urlencode "to=\$TO_EMAIL" --data-urlencode "subject=[\$REMARK] [Resend API]SSH登录成功提醒 \${IP:-未知} \$(date '+%Y/%m/%d %H:%M:%S')" --data-urlencode "text=\$BODY" >/dev/null 2>&1 || true
done < "\$TMP_LOG"
echo "\$NOW_TS" > "\$STATE_FILE"
rm -f "\$TMP_LOG"
) 9>"\$LOCK_FILE"
EOF
                    chmod 700 /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh
                    date +%s > /home/docker/fail2ban/notify/ssh-qita-email-smtp.state
                    ( crontab -l 2>/dev/null | grep -v "ssh-qita-email-smtp.sh" | grep -v "^# ssh登录成功 其他API 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$"; echo "# ssh登录成功 其他API 通知"; echo "* * * * * /bin/bash /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh >/dev/null 2>&1" ) | crontab -
                    echo -e "${gl_lv}SSH 登录成功 其他API邮件通知已添加。${gl_bai}"
                    echo -e "${gl_hong}请测试发信，不是所有邮件 API 都兼容Authorization: Bearer${gl_bai}"
                    read -n1 -r -p "按任意键继续..."
                                ;;
                            4)
                    clear
                    echo "▶️ 删除 SSH 登录成功邮件通知"
                    echo "================================"
                    echo "1. Resend API 发信"
                    echo "2. SMTP 发信"
                    echo "3. 其他 API 发信"
                    echo "4. 删除全部"
                    echo "0. 返回上一级"
                    echo "================================"
                    read -e -p "输入要删除的序号: " del_mail_opt
                    case "$del_mail_opt" in
                        1)
                            read -e -p "确定删除 Resend API 邮件通知吗？(Y/N): " confirm_del_mail
                            case "$confirm_del_mail" in
                                [Yy]) crontab -l 2>/dev/null | grep -v "ssh-Resend-email-smtp.sh" | grep -v "^# ssh登录成功 Resend 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$" | crontab -; rm -f /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh /home/docker/fail2ban/notify/ssh-Resend-email-smtp.state; echo -e "${gl_lv}Resend邮件通知已删除${gl_bai}" ;;
                                *) echo "已取消删除" ;;
                            esac
                            ;;
                        2)
                            read -e -p "确定删除 SMTP 邮件通知吗？(Y/N): " confirm_del_mail
                            case "$confirm_del_mail" in
                                [Yy]) crontab -l 2>/dev/null | grep -v "ssh-smtp-email-smtp.sh" | grep -v "^# ssh登录成功 SMTP 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$" | crontab -; rm -f /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh /home/docker/fail2ban/notify/ssh-smtp-email-smtp.state; echo -e "${gl_lv}SMTP邮件通知已删除${gl_bai}" ;;
                                *) echo "已取消删除" ;;
                            esac
                            ;;
                        3)
                            read -e -p "确定删除 其他API 邮件通知吗？(Y/N): " confirm_del_mail
                            case "$confirm_del_mail" in
                                [Yy]) crontab -l 2>/dev/null | grep -v "ssh-qita-email-smtp.sh" | grep -v "^# ssh登录成功 其他API 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$" | crontab -; rm -f /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh /home/docker/fail2ban/notify/ssh-qita-email-smtp.state; echo -e "${gl_lv}其他API邮件通知已删除${gl_bai}" ;;
                                *) echo "已取消删除" ;;
                            esac
                            ;;
                        4)
                            read -e -p "确定删除全部 SSH 登录成功邮件通知吗？(Y/N): " confirm_del_mail
                            case "$confirm_del_mail" in
                                [Yy]) crontab -l 2>/dev/null | grep -v "ssh-Resend-email-smtp.sh" | grep -v "ssh-smtp-email-smtp.sh" | grep -v "ssh-qita-email-smtp.sh" | grep -v "^# ssh登录成功 其他API 通知$" | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$" | crontab -; rm -f /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh /home/docker/fail2ban/notify/ssh-Resend-email-smtp.state /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh /home/docker/fail2ban/notify/ssh-smtp-email-smtp.state /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh /home/docker/fail2ban/notify/ssh-qita-email-smtp.state; echo -e "${gl_lv}全部邮件通知已删除${gl_bai}" ;;
                                *) echo "已取消删除" ;;
                            esac
                            ;;
                        0) ;;
                        *) echo "无效选择" ;;
                    esac
                    read -n1 -r -p "按任意键继续..."
                                ;;
                            0) ;;
                            *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                        esac
                        ;;
                    3)
                        clear
                        echo "▶️ 开启 SSH 登录即时通知保护"
                        echo "------------------------"
                        echo "说明: 使用 PAM 在 SSH 登录成功时立即触发通知。"
                        echo "不会替代每分钟定时检查，只是提高异常登录通知及时性。"
                        echo "如果通知配置不存在，请先添加 Telegram 或邮件通知。"
                        echo "------------------------"
                        if [ "$EUID" -ne 0 ]; then
                            echo -e "${gl_hong}请使用 root 用户开启。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        mkdir -p /home/docker/fail2ban/notify
                        cat > /home/docker/fail2ban/notify/ssh-login-pam-alert.sh <<'EOF'
#!/bin/bash
# SSH 登录成功即时通知；由 pam_exec 触发，立即后台发送，主进程快速退出避免影响登录。
(
    sleep 1
    USER_NAME="${PAM_USER:-未知}"
    LOGIN_IP="${PAM_RHOST:-未知}"
    LOCK_FILE="/tmp/ssh-login-pam-alert.lock"
    STATE_FILE="/home/docker/fail2ban/notify/ssh-login-pam-alert.state"
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    NOW_TS=$(date +%s)
    EVENT_KEY="${USER_NAME}|${LOGIN_IP}"
    LAST_KEY=""
    LAST_TS="0"
    if [ -f "$STATE_FILE" ]; then
        read -r LAST_KEY LAST_TS < "$STATE_FILE" || true
    fi
    if [ "$EVENT_KEY" = "$LAST_KEY" ] && [ $((NOW_TS - ${LAST_TS:-0})) -lt 120 ]; then
        exit 0
    fi
    echo "$EVENT_KEY $NOW_TS" > "$STATE_FILE"
    TIME_TEXT=$(date '+%Y/%m/%d %H:%M:%S')
    FAIL2BAN_CONF="/home/docker/fail2ban/config/fail2ban/jail.d/sshd.local"
    IP_STATUS="未封禁"
    if [ -n "$LOGIN_IP" ] && [ "$LOGIN_IP" != "未知" ] && [ -f "$FAIL2BAN_CONF" ]; then
        IGNORE_IPS=$(grep -E '^[[:space:]]*ignoreip[[:space:]]*=' "$FAIL2BAN_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- | xargs)
        if echo " $IGNORE_IPS " | grep -Fqw -- "$LOGIN_IP"; then
            IP_STATUS="白名单"
        elif command -v docker >/dev/null 2>&1 && docker inspect fail2ban >/dev/null 2>&1 && docker exec fail2ban fail2ban-client status sshd >/dev/null 2>&1; then
            BANNED_IPS=$(docker exec fail2ban fail2ban-client get sshd banip 2>/dev/null || true)
            [ -z "$BANNED_IPS" ] && BANNED_IPS=$(docker exec fail2ban fail2ban-client status sshd 2>/dev/null | sed -n 's/^.*Banned IP list:[[:space:]]*//p')
            if echo " $BANNED_IPS " | grep -Fqw -- "$LOGIN_IP"; then
                IP_STATUS="已封禁"
            fi
        fi
    fi
    if [ "$IP_STATUS" = "白名单" ] && [ -f "/home/docker/fail2ban/notify/skip-whitelist-login.enabled" ]; then
        exit 0
    fi
    get_var() {
        local file="$1" key="$2"
        grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
    }
    TG_SCRIPT="/home/docker/fail2ban/notify/ssh-login-telegram.sh"
    if [ -f "$TG_SCRIPT" ]; then
        REMARK=$(get_var "$TG_SCRIPT" "REMARK")
        BOT_TOKEN=$(get_var "$TG_SCRIPT" "BOT_TOKEN")
        CHAT_ID=$(get_var "$TG_SCRIPT" "CHAT_ID")
        if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
            TEXT="🔐 SSH登录成功提醒

备注: ${REMARK:-未设置}
👤 用户: ${USER_NAME}
🛡️ IP状态: ${IP_STATUS}
🌐 IP: ${LOGIN_IP}
⏰ 时间: ${TIME_TEXT}"
            curl -s -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d chat_id="$CHAT_ID" \
                --data-urlencode text="$TEXT" >/dev/null 2>&1 || true
        fi
    fi
    RESEND_SCRIPT="/home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh"
    if [ -f "$RESEND_SCRIPT" ]; then
        REMARK=$(get_var "$RESEND_SCRIPT" "REMARK")
        RESEND_KEY=$(get_var "$RESEND_SCRIPT" "RESEND_KEY")
        FROM_EMAIL=$(get_var "$RESEND_SCRIPT" "FROM_EMAIL")
        TO_EMAIL=$(get_var "$RESEND_SCRIPT" "TO_EMAIL")
        if [ -n "$RESEND_KEY" ] && [ -n "$FROM_EMAIL" ] && [ -n "$TO_EMAIL" ]; then
            BODY="🔐 SSH登录成功提醒

备注: ${REMARK:-未设置}
👤 用户: ${USER_NAME}
🛡️ IP状态: ${IP_STATUS}
🌐 IP: ${LOGIN_IP}
⏰ 时间: ${TIME_TEXT}"
            curl -s -m 10 https://api.resend.com/emails \
              -H "Authorization: Bearer ${RESEND_KEY}" \
              -H "Content-Type: application/x-www-form-urlencoded" \
              --data-urlencode "from=${FROM_EMAIL}" \
              --data-urlencode "to=${TO_EMAIL}" \
              --data-urlencode "subject=[${REMARK:-SSH}] [Resend API]SSH登录成功提醒 ${LOGIN_IP} ${TIME_TEXT}" \
              --data-urlencode "text=${BODY}" >/dev/null 2>&1 || true
        fi
    fi
    SMTP_SCRIPT="/home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh"
    if [ -f "$SMTP_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
        export REMARK=$(get_var "$SMTP_SCRIPT" "REMARK")
        export SMTP_HOST=$(get_var "$SMTP_SCRIPT" "SMTP_HOST")
        export SMTP_PORT=$(get_var "$SMTP_SCRIPT" "SMTP_PORT")
        export SMTP_SSL=$(get_var "$SMTP_SCRIPT" "SMTP_SSL")
        export SMTP_USER=$(get_var "$SMTP_SCRIPT" "SMTP_USER")
        export SMTP_PASS=$(get_var "$SMTP_SCRIPT" "SMTP_PASS")
        export FROM_EMAIL=$(get_var "$SMTP_SCRIPT" "FROM_EMAIL")
        export TO_EMAIL=$(get_var "$SMTP_SCRIPT" "TO_EMAIL")
        export SMTP_SUBJECT="[${REMARK:-SSH}] [SMTP]SSH登录成功提醒 ${LOGIN_IP} ${TIME_TEXT}"
        export SMTP_BODY="🔐 SSH登录成功提醒

备注: ${REMARK:-未设置}
👤 用户: ${USER_NAME}
🛡️ IP状态: ${IP_STATUS}
🌐 IP: ${LOGIN_IP}
⏰ 时间: ${TIME_TEXT}"
        if [ -n "$SMTP_HOST" ] && [ -n "$FROM_EMAIL" ] && [ -n "$TO_EMAIL" ]; then
            timeout 15 python3 - <<'PYEOF' >/dev/null 2>&1 || true
import os, smtplib, ssl
from email.message import EmailMessage
msg = EmailMessage()
msg['From'] = os.environ['FROM_EMAIL']
msg['To'] = os.environ['TO_EMAIL']
msg['Subject'] = os.environ.get('SMTP_SUBJECT', 'SSH登录成功提醒')
msg.set_content(os.environ.get('SMTP_BODY', ''))
host=os.environ['SMTP_HOST']; port=int(os.environ.get('SMTP_PORT','587'))
use_ssl=os.environ.get('SMTP_SSL','N').lower().startswith('y')
user=os.environ.get('SMTP_USER',''); password=os.environ.get('SMTP_PASS','')
if use_ssl:
    server=smtplib.SMTP_SSL(host, port, timeout=10, context=ssl.create_default_context())
else:
    server=smtplib.SMTP(host, port, timeout=10)
    server.ehlo()
    if port != 25:
        server.starttls(context=ssl.create_default_context())
        server.ehlo()
if user:
    server.login(user, password)
server.send_message(msg)
server.quit()
PYEOF
        fi
    fi
) >/dev/null 2>&1 &
exit 0
EOF
                        chmod 700 /home/docker/fail2ban/notify/ssh-login-pam-alert.sh
                        if [ ! -f /etc/pam.d/sshd ]; then
                            echo -e "${gl_hong}未找到 /etc/pam.d/sshd，无法开启。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        cp -a /etc/pam.d/sshd "/etc/pam.d/sshd.bak.ssh-login-notify.$(date +%Y%m%d%H%M%S)"
                        if ! grep -q '/home/docker/fail2ban/notify/ssh-login-pam-alert.sh' /etc/pam.d/sshd; then
                            echo "session optional pam_exec.so quiet /home/docker/fail2ban/notify/ssh-login-pam-alert.sh" >> /etc/pam.d/sshd
                        fi
                        echo -e "${gl_lv}SSH 登录即时通知保护已开启。${gl_bai}"
                        echo "PAM配置: /etc/pam.d/sshd"
                        echo "即时脚本: /home/docker/fail2ban/notify/ssh-login-pam-alert.sh"
                        echo "说明: 如果登录异常，可用快照恢复，或删除 /etc/pam.d/sshd 中 pam_exec 对应行。"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    4)
                        clear
                        echo "▶️ 关闭 SSH 登录即时通知保护"
                        echo "------------------------"
                        if [ "$EUID" -ne 0 ]; then
                            echo -e "${gl_hong}请使用 root 用户关闭。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            continue
                        fi
                        if [ -f /etc/pam.d/sshd ]; then
                            cp -a /etc/pam.d/sshd "/etc/pam.d/sshd.bak.remove-ssh-login-notify.$(date +%Y%m%d%H%M%S)"
                            sed -i '\|/home/docker/fail2ban/notify/ssh-login-pam-alert.sh|d' /etc/pam.d/sshd
                        fi
                        rm -f /home/docker/fail2ban/notify/ssh-login-pam-alert.sh
                        echo -e "${gl_lv}SSH 登录即时通知保护已关闭。${gl_bai}"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    5)
                        mkdir -p /home/docker/fail2ban/notify
                        touch /home/docker/fail2ban/notify/skip-whitelist-login.enabled
                        echo -e "${gl_hong}已启用：白名单IP登录不发送通知。${gl_bai}"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    6)
                        rm -f /home/docker/fail2ban/notify/skip-whitelist-login.enabled
                        echo -e "${gl_lv}已关闭：白名单IP登录也会发送通知。${gl_bai}"
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    7)
                        clear
                        echo "▶️ 发送 SSH 登录成功通知测试消息"
                        echo "------------------------"
                        sent_any=0
                        if [ -x /home/docker/fail2ban/notify/ssh-login-telegram.sh ]; then
                            echo "发送 Telegram 测试消息..."
                            /bin/bash /home/docker/fail2ban/notify/ssh-login-telegram.sh --test >/dev/null 2>&1 || true
                            sent_any=1
                        fi
                        if [ -x /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh ]; then
                            echo "发送 Resend 邮件测试消息..."
                            /bin/bash /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh --test >/dev/null 2>&1 || true
                            sent_any=1
                        fi
                        if [ -x /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh ]; then
                            echo "发送 SMTP 邮件测试消息..."
                            /bin/bash /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh --test >/dev/null 2>&1 || true
                            sent_any=1
                        fi
                        if [ -x /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh ]; then
                            echo "发送 其他API 邮件测试消息..."
                            /bin/bash /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh --test >/dev/null 2>&1 || true
                            sent_any=1
                        fi
                        if [ "$sent_any" = "0" ]; then
                            echo "暂无已添加的通知配置，已跳过。"
                        else
                            echo "测试消息已触发，请检查对应 Telegram/邮箱。"
                        fi
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    9)
                        clear
                        echo "▶️ 删除全部 SSH 登录成功通知任务"
                        echo "------------------------"
                        read -e -p "确定删除 Telegram/邮件/即时通知/PAM配置/白名单不通知开关吗？(Y/N): " confirm_del_all_notify
                        case "$confirm_del_all_notify" in
                            [Yy])
                                if command -v crontab >/dev/null 2>&1; then
                                    crontab -l 2>/dev/null                                         | grep -v "ssh-login-telegram.sh"                                         | grep -v "ssh-Resend-email-smtp.sh"                                         | grep -v "ssh-smtp-email-smtp.sh"                                         | grep -v "ssh-qita-email-smtp.sh"                                         | grep -v "ssh-login-pam-alert.sh"                                         | grep -v "^# ssh登录成功 Telegram 通知$"                                         | grep -v "^# ssh登录成功 Resend 通知$"                                         | grep -v "^# ssh登录成功 SMTP 通知$"                                         | grep -v "^# ssh登录成功 其他API 通知$"                                         | grep -v "^# ssh登录成功通知（邮件Telegram通知一起不要分开）$"                                         | crontab -
                                fi
                                if [ -f /etc/pam.d/sshd ]; then
                                    if grep -q '/home/docker/fail2ban/notify/ssh-login-pam-alert.sh' /etc/pam.d/sshd; then
                                        cp -a /etc/pam.d/sshd "/etc/pam.d/sshd.bak.remove-ssh-login-notify.$(date +%Y%m%d%H%M%S)"
                                        sed -i '\|/home/docker/fail2ban/notify/ssh-login-pam-alert.sh|d' /etc/pam.d/sshd
                                    fi
                                fi
                                rm -f /home/docker/fail2ban/notify/ssh-login-telegram.sh
                                rm -f /home/docker/fail2ban/notify/ssh-login-telegram.state
                                rm -f /home/docker/fail2ban/notify/ssh-Resend-email-smtp.sh
                                rm -f /home/docker/fail2ban/notify/ssh-Resend-email-smtp.state
                                rm -f /home/docker/fail2ban/notify/ssh-smtp-email-smtp.sh
                                rm -f /home/docker/fail2ban/notify/ssh-smtp-email-smtp.state
                                rm -f /home/docker/fail2ban/notify/ssh-qita-email-smtp.sh
                                rm -f /home/docker/fail2ban/notify/ssh-qita-email-smtp.state
                                rm -f /home/docker/fail2ban/notify/ssh-login-pam-alert.sh
                                rm -f /home/docker/fail2ban/notify/ssh-login-pam-alert.state
                                rm -f /home/docker/fail2ban/notify/skip-whitelist-login.enabled
                                rm -f /tmp/ssh-login-telegram.lock
                                rm -f /tmp/ssh-Resend-email-smtp.lock
                                rm -f /tmp/ssh-smtp-email-smtp.lock
                                rm -f /tmp/ssh-qita-email-smtp.lock
                                rm -f /tmp/ssh-login-pam-alert.lock
                                echo -e "${gl_lv}全部 SSH 登录成功通知任务已删除。${gl_bai}"
                                ;;
                            *)
                                echo "已取消删除"
                                ;;
                        esac
                        read -n1 -r -p "按任意键继续..."
                        ;;
                    0) break ;;
                    *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                esac
            done
            ;;

        0)
            break
            ;;

        *)
            echo "无效选择，请重新输入。"
            read -n1 -r -p "按任意键继续..."
            ;;

    esac

done


exit 0
