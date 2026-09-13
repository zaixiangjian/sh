#!/bin/bash

# Google监控系统独立管理脚本
# 从 /root/kejilion.sh 的 96 号功能拆分，未修改原脚本。

gl_bai="[0m"
gl_hong="[31m"
gl_lv="[32m"
gl_huang="[33m"
gl_kjlan="[36m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${gl_hong}请使用 root 用户运行。${gl_bai}"
    exit 1
fi

    google_confirm_overwrite() {
        local name="$1"
        local path="$2"
        local cron_pattern="$3"
        if [ -f "$path" ] || crontab -l 2>/dev/null | grep -q "$cron_pattern"; then
            echo -e "${gl_huang}${name} 当前任务已添加。${gl_bai}"
            read -e -p "输入 Y 确认覆盖，其他键取消: " overwrite_confirm
            case "$overwrite_confirm" in
                [Yy]) return 0 ;;
                *) echo "已取消"; read -n1 -r -p "按任意键继续..."; return 1 ;;
            esac
        fi
        return 0
    }

    google_ensure_python3() {
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



    google_ensure_chromium() {
        echo "正在检查 Chromium/Chrome..."
        if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
            echo -e "${gl_lv}Chromium/Chrome已安装${gl_bai}"
            return 0
        fi
        echo "Chromium/Chrome未安装，正在安装..."
        if command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 && (DEBIAN_FRONTEND=noninteractive apt-get install -y chromium >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y chromium-browser >/dev/null 2>&1)
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y chromium >/dev/null 2>&1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y chromium >/dev/null 2>&1
        elif command -v apk >/dev/null 2>&1; then
            apk update >/dev/null 2>&1 && apk add --no-cache chromium >/dev/null 2>&1
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install chromium >/dev/null 2>&1
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm chromium >/dev/null 2>&1
        else
            echo -e "${gl_hong}Chromium/Chrome安装失败：当前系统未检测到支持的包管理器${gl_bai}"
            return 1
        fi
        if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
            echo -e "${gl_lv}Chromium/Chrome安装完成${gl_bai}"
            return 0
        else
            echo -e "${gl_hong}Chromium/Chrome安装失败${gl_bai}"
            return 1
        fi
    }

    google_ensure_maps_deps() {
        google_ensure_python3 || return 1
        google_ensure_chromium || return 1
    }
    google_jwd_read_common() {
        read -e -p "通知显示地区例如：美国西雅图
请输入通知显示地区（回车默认美国）: " TARGET_REGION
        TARGET_REGION=${TARGET_REGION:-美国}
        echo "https://www.google.com/maps/"
        echo "请使用上方链接获取的经纬度"
        read -e -p "@后面的数字或者纯数字
（例如: @47.4691604,-122.3398184,9）: " MAPS_INPUT
        BASE_COORDS=$(echo "$MAPS_INPUT" | grep -oE '@?-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?(,[0-9]+z?)?' | head -n1 | sed 's/^@//' | sed 's/z$//')
        BASE_COORDS=${BASE_COORDS:-$MAPS_INPUT}
        read -e -p "允许偏移距离公里数 [默认: 100公里]: " OFFSET_KM
        OFFSET_KM=${OFFSET_KM:-100}
        read -e -p "固定每日几点通知00/8/12/20一次（北京时间回车默认8点）: " DAILY_HOUR
        DAILY_HOUR=${DAILY_HOUR:-8}
        DAILY_HOUR=$(printf "%02d" "$DAILY_HOUR" 2>/dev/null || echo "08")
        read -p "请输入备注名称: " REMARK
    }

    google_jwd_daily_hour() {
        local file="$1"
        if [ -f "$file" ]; then
            grep -E '^DAILY_HOUR=' "$file" 2>/dev/null | head -n1 | cut -d= -f2 | tr -d '"'
        fi
    }

    while true; do
        clear
        echo "=================================="
        echo "▶️ Google监控系统安装"
        echo "=================================="
        echo "电报通知"
        google_tg_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-telegram.sh' | grep -v '^#' | head -n1)
        [ -n "$google_tg_cron" ] && echo "$google_tg_cron" || echo "暂无"
        echo "-----------------------------------------------------------"
        echo "邮件Resend通知"
        google_resend_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-Resend-email.sh' | grep -v '^#' | head -n1)
        [ -n "$google_resend_cron" ] && echo "$google_resend_cron" || echo "暂无"
        echo "------------------------"
        echo "邮件SMTP通知"
        google_smtp_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-smtp-email.sh' | grep -v '^#' | head -n1)
        [ -n "$google_smtp_cron" ] && echo "$google_smtp_cron" || echo "暂无"
        echo "------------------------"
        echo "其他API邮件通知"
        google_qita_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-qita-email.sh' | grep -v '^#' | head -n1)
        [ -n "$google_qita_cron" ] && echo "$google_qita_cron" || echo "暂无"
        echo -e "${gl_hong}==================================${gl_bai}"
        echo -e "${gl_hong}经纬度检测位置变更通知，每天固定通知一次${gl_bai}"
        echo -e "${gl_hong}==================================${gl_bai}"
        echo -e "${gl_hong}经纬度电报通知${gl_bai}"
        google_jwd_tg_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-jingweidu-telegram.sh' | grep -v '^#')
        [ -n "$google_jwd_tg_cron" ] && echo "$google_jwd_tg_cron" || echo -e "${gl_hong}暂无${gl_bai}"
        google_jwd_tg_hour=$(google_jwd_daily_hour /home/jiancegoogle-jingweidu-telegram.sh)
        [ -n "$google_jwd_tg_hour" ] && echo -e "固定每日通知:${gl_lv}${google_jwd_tg_hour}点${gl_bai}"
        echo "------------------------------------------------------------"
        echo -e "${gl_hong}经纬度邮件Resend通知${gl_bai}"
        google_jwd_resend_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-jingweidu-Resend-email.sh' | grep -v '^#')
        [ -n "$google_jwd_resend_cron" ] && echo "$google_jwd_resend_cron" || echo -e "${gl_hong}暂无${gl_bai}"
        google_jwd_resend_hour=$(google_jwd_daily_hour /home/jiancegoogle-jingweidu-Resend-email.sh)
        [ -n "$google_jwd_resend_hour" ] && echo -e "固定每日通知:${gl_lv}${google_jwd_resend_hour}点${gl_bai}"
        echo "------------------------------------------------------------"
        echo -e "${gl_hong}经纬度邮件SMTP通知${gl_bai}"
        google_jwd_smtp_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-jingweidu-smtp-email.sh' | grep -v '^#')
        [ -n "$google_jwd_smtp_cron" ] && echo "$google_jwd_smtp_cron" || echo -e "${gl_hong}暂无${gl_bai}"
        google_jwd_smtp_hour=$(google_jwd_daily_hour /home/jiancegoogle-jingweidu-smtp-email.sh)
        [ -n "$google_jwd_smtp_hour" ] && echo -e "固定每日通知:${gl_lv}${google_jwd_smtp_hour}点${gl_bai}"
        echo "------------------------------------------------------------"
        echo -e "${gl_hong}经纬度API邮件通知${gl_bai}"
        google_jwd_qita_cron=$(crontab -l 2>/dev/null | grep '/home/jiancegoogle-jingweidu-qita-email.sh' | grep -v '^#')
        [ -n "$google_jwd_qita_cron" ] && echo "$google_jwd_qita_cron" || echo -e "${gl_hong}暂无${gl_bai}"
        google_jwd_qita_hour=$(google_jwd_daily_hour /home/jiancegoogle-jingweidu-qita-email.sh)
        [ -n "$google_jwd_qita_hour" ] && echo -e "固定每日通知:${gl_lv}${google_jwd_qita_hour}点${gl_bai}"
        echo -e "${gl_hong}==================================${gl_bai}"
        echo "=================================="
        echo "1. Telegram 通知（1小时一次）"
        echo "2. 邮件通知（2小时一次）"
        echo "3. 卸载"
        echo "4. 发送测试消息"
        echo "5. 经纬度Telegram 通知（每小时第5分钟）"
        echo "6. 经纬度邮件通知（大概2小时左右一次）"
        echo "7. 卸载经纬度通知"
        echo "8. 发送经纬度测试消息"
        echo "0) 返回"
        echo "=================================="
        read -p "请输入选项: " opt
        case "$opt" in
            1)
                while true; do
                    clear
                    echo "▶️ Google监控系统安装"
                    echo "================================"
                    echo "1. 添加 Telegram 通知"
                    echo "2. 删除 Telegram 通知"
                    echo "0. 返回"
                    echo "================================"
                    read -e -p "请输入你的选择: " tg_opt
                    case "$tg_opt" in
                        1)
                            google_confirm_overwrite "Telegram通知" "/home/jiancegoogle-telegram.sh" "jiancegoogle-telegram.sh" || continue
                            read -p "请输入备注名称: " REMARK
                            read -p "请输入 Bot Token: " BOT_TOKEN
                            BOT_TOKEN=$(echo "$BOT_TOKEN" | sed 's#https://api.telegram.org/bot##g' | sed 's#/sendMessage##g')
                            read -p "请输入 Chat ID: " CHAT_ID
                            cat > /home/jiancegoogle-telegram.sh <<EOF
#!/bin/bash
URL="https://www.youtube.com/red"
HTML=\$(curl -L -s -m 15 -A "Mozilla/5.0" -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" "\$URL")
check_youtube_premium_region() {
    echo "\$HTML" | grep -qiE "not available in your country|在你所在的国家/地区尚未推出|YouTube Premium is not available in your country|This service isn't available in your country" && return 0
    REGION=\$(printf '%s' "\$HTML" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"|"GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}' | tail -n1)
    PREMIUM_AVAILABLE_COUNTRIES="DZ AS AR AW AU AT AZ BH BD BY BE BM BO BA BR BG KH CA KY CL CO CR HR CY CZ DK DO EC EG SV EE FI FR GF PF GE DE GH GR GP GU GT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KW LA LV LB LY LI LT LU MY MT MX MA NP NL NZ NI NG MK MP NO OM PK PA PG PY PE PH PL PT PR QA RE RO SA SN RS SG SK SI ZA KR ES LK SE CH TW TZ TH TN TR TC VI UG AE GB US UY VE VN YE ZW"
    if [ -n "\$REGION" ] && ! echo " \$PREMIUM_AVAILABLE_COUNTRIES " | grep -qw "\$REGION"; then
        return 0
    fi
    return 1
}
check_youtube_premium_region
DETECTED=\$?
if [ "\${1:-}" = "--test" ] || [ \$DETECTED -eq 0 ]; then
if [ "\${1:-}" = "--test" ]; then
TEXT="🏷 节点：${REMARK}

这是一个区域监控告警测试消息

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具"
else
TEXT="❗️可能送中了❗️🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具"
fi
curl -s -m 10 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" -d chat_id="${CHAT_ID}" --data-urlencode text="\$TEXT" >/dev/null 2>&1
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-telegram.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-telegram.sh" | grep -v "^# Google监控 Telegram通知$"; echo "# Google监控 Telegram通知"; echo "0 * * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-telegram.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ Telegram通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        2)
                            read -e -p "确定删除 Google监控 Telegram 通知吗？(Y/N): " confirm_del_tg
                            case "$confirm_del_tg" in
                                [Yy])
                                    crontab -l 2>/dev/null | grep -v "jiancegoogle-telegram.sh" | grep -v "^# Google监控 Telegram通知$" | crontab -
                                    rm -f /home/jiancegoogle-telegram.sh
                                    echo "✅ Telegram通知已删除"
                                    ;;
                                *) echo "已取消删除" ;;
                            esac
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        0) break ;;
                        *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                    esac
                done
                ;;
            2)
                while true; do
                    clear
                    echo "▶️ Google监控系统安装"
                    echo "================================"
                    echo "1. 使用 Resend API 发信"
                    echo "2. 使用 SMTP 发信（部分VPS可能不支持）"
                    echo "3. 使用 其他 API 发信"
                    echo "4. 删除邮件通知"
                    echo "0. 返回"
                    echo "================================"
                    read -e -p "请输入你的选择: " mail_opt
                    case "$mail_opt" in
                        1)
                            google_confirm_overwrite "Resend邮件通知" "/home/jiancegoogle-Resend-email.sh" "jiancegoogle-Resend-email.sh" || continue
                            read -p "请输入备注名称: " REMARK
                            read -p "请输入 Resend API Key: " RESEND_KEY
                            read -p "请输入发件邮箱(From): " FROM_EMAIL
                            read -p "请输入收件邮箱(To): " TO_EMAIL
                            cat > /home/jiancegoogle-Resend-email.sh <<EOF
#!/bin/bash
URL="https://www.youtube.com/red"
HTML=\$(curl -L -s -m 15 -A "Mozilla/5.0" -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" "\$URL")
check_youtube_premium_region() {
    echo "\$HTML" | grep -qiE "not available in your country|在你所在的国家/地区尚未推出|YouTube Premium is not available in your country|This service isn't available in your country" && return 0
    REGION=\$(printf '%s' "\$HTML" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"|"GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}' | tail -n1)
    PREMIUM_AVAILABLE_COUNTRIES="DZ AS AR AW AU AT AZ BH BD BY BE BM BO BA BR BG KH CA KY CL CO CR HR CY CZ DK DO EC EG SV EE FI FR GF PF GE DE GH GR GP GU GT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KW LA LV LB LY LI LT LU MY MT MX MA NP NL NZ NI NG MK MP NO OM PK PA PG PY PE PH PL PT PR QA RE RO SA SN RS SG SK SI ZA KR ES LK SE CH TW TZ TH TN TR TC VI UG AE GB US UY VE VN YE ZW"
    if [ -n "\$REGION" ] && ! echo " \$PREMIUM_AVAILABLE_COUNTRIES " | grep -qw "\$REGION"; then
        return 0
    fi
    return 1
}
check_youtube_premium_region
DETECTED=\$?
if [ "\${1:-}" = "--test" ] || [ \$DETECTED -eq 0 ]; then
if [ "\${1:-}" = "--test" ]; then
TEST_TIME=\$(date '+%Y%m%d-%H%M%S')
BODY="🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具
测试时间: \${TEST_TIME}"
SUBJECT="[${REMARK}] [Resend API]区域监控告警测试邮件 \$(date '+%Y/%m/%d %H:%M:%S')"
else
BODY="❗️可能送中了❗️🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具"
SUBJECT="❗️可能送中了❗️[${REMARK}]⚠️ [Resend API] ❌YouTube 区域监控告警❌ \$(date '+%Y/%m/%d %H:%M:%S')"
fi
curl -s -m 15 https://api.resend.com/emails -H "Authorization: Bearer ${RESEND_KEY}" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "from=${FROM_EMAIL}" --data-urlencode "to=${TO_EMAIL}" --data-urlencode "subject=\$SUBJECT" --data-urlencode "text=\$BODY" >/dev/null 2>&1
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-Resend-email.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-Resend-email.sh" | grep -v "^# Google监控 Resend邮件通知$"; echo "# Google监控 Resend邮件通知"; echo "0 */2 * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-Resend-email.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ Resend邮件通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        2)
                            google_ensure_python3 || { read -n1 -r -p "按任意键继续..."; continue; }
                            google_confirm_overwrite "SMTP邮件通知" "/home/jiancegoogle-smtp-email.sh" "jiancegoogle-smtp-email.sh" || continue
                            read -p "请输入备注名称: " REMARK
                            read -p "请输入 SMTP服务器: " SMTP_HOST
                            read -p "请输入 SMTP端口465或者587 [默认: 587]: " SMTP_PORT
                            SMTP_PORT=${SMTP_PORT:-587}
                            read -p "是否启用SSL? 465端口通常选Y，587通常选N (Y/N) [默认: N]: " SMTP_SSL
                            SMTP_SSL=${SMTP_SSL:-N}
                            read -p "请输入 SMTP用户名: " SMTP_USER
                            read -s -p "请输入 SMTP密码/授权码: " SMTP_PASS; echo
                            read -p "请输入发件邮箱(From): " FROM_EMAIL
                            read -p "请输入收件邮箱(To): " TO_EMAIL
                            cat > /home/jiancegoogle-smtp-email.sh <<EOF
#!/bin/bash
URL="https://www.youtube.com/red"
HTML=\$(curl -L -s -m 15 -A "Mozilla/5.0" -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" "\$URL")
check_youtube_premium_region() {
    echo "\$HTML" | grep -qiE "not available in your country|在你所在的国家/地区尚未推出|YouTube Premium is not available in your country|This service isn't available in your country" && return 0
    REGION=\$(printf '%s' "\$HTML" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"|"GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}' | tail -n1)
    PREMIUM_AVAILABLE_COUNTRIES="DZ AS AR AW AU AT AZ BH BD BY BE BM BO BA BR BG KH CA KY CL CO CR HR CY CZ DK DO EC EG SV EE FI FR GF PF GE DE GH GR GP GU GT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KW LA LV LB LY LI LT LU MY MT MX MA NP NL NZ NI NG MK MP NO OM PK PA PG PY PE PH PL PT PR QA RE RO SA SN RS SG SK SI ZA KR ES LK SE CH TW TZ TH TN TR TC VI UG AE GB US UY VE VN YE ZW"
    if [ -n "\$REGION" ] && ! echo " \$PREMIUM_AVAILABLE_COUNTRIES " | grep -qw "\$REGION"; then
        return 0
    fi
    return 1
}
check_youtube_premium_region
DETECTED=\$?
if [ "\${1:-}" = "--test" ] || [ \$DETECTED -eq 0 ]; then
export SMTP_HOST="${SMTP_HOST}" SMTP_PORT="${SMTP_PORT}" SMTP_SSL="${SMTP_SSL}" SMTP_USER="${SMTP_USER}" SMTP_PASS="${SMTP_PASS}" FROM_EMAIL="${FROM_EMAIL}" TO_EMAIL="${TO_EMAIL}"
if [ "\${1:-}" = "--test" ]; then
TEST_TIME=\$(date '+%Y%m%d-%H%M%S')
export SMTP_SUBJECT="[${REMARK}] [SMTP]区域监控告警测试邮件 \$(date '+%Y/%m/%d %H:%M:%S')"
export SMTP_BODY="🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具
测试时间: \${TEST_TIME}"
else
export SMTP_SUBJECT="❗️可能送中了❗️[${REMARK}]⚠️ [SMTP] ❌YouTube 区域监控告警❌ \$(date '+%Y/%m/%d %H:%M:%S')"
export SMTP_BODY="❗️可能送中了❗️🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具"
fi
python3 - <<'PYEOF' >/dev/null 2>&1 || true
import os, smtplib, ssl
from email.message import EmailMessage
msg=EmailMessage(); msg['From']=os.environ['FROM_EMAIL']; msg['To']=os.environ['TO_EMAIL']; msg['Subject']=os.environ.get('SMTP_SUBJECT','YouTube 区域监控告警'); msg.set_content(os.environ.get('SMTP_BODY',''))
host=os.environ['SMTP_HOST']; port=int(os.environ.get('SMTP_PORT','587')); use_ssl=os.environ.get('SMTP_SSL','N').lower().startswith('y')
server=smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context()) if use_ssl else smtplib.SMTP(host, port, timeout=20)
if not use_ssl:
    server.ehlo()
    if port != 25: server.starttls(context=ssl.create_default_context()); server.ehlo()
if os.environ.get('SMTP_USER'): server.login(os.environ.get('SMTP_USER'), os.environ.get('SMTP_PASS',''))
server.send_message(msg); server.quit()
PYEOF
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-smtp-email.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-smtp-email.sh" | grep -v "^# Google监控 SMTP邮件通知$"; echo "# Google监控 SMTP邮件通知"; echo "0 */2 * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-smtp-email.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ SMTP邮件通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        3)
                            google_confirm_overwrite "其他API邮件通知" "/home/jiancegoogle-qita-email.sh" "jiancegoogle-qita-email.sh" || continue
                            read -p "请输入备注名称: " REMARK
                            read -p "请输入 API地址: " API_URL
                            read -p "请输入 API Key: " API_KEY
                            read -p "请输入请求头（回车默认Authorization: Bearer）: " API_HEADER
                            if [ -z "$API_HEADER" ]; then API_HEADER="Authorization: Bearer"; fi
                            read -p "请输入发件邮箱(From): " FROM_EMAIL
                            read -p "请输入收件邮箱(To): " TO_EMAIL
                            cat > /home/jiancegoogle-qita-email.sh <<EOF
#!/bin/bash
URL="https://www.youtube.com/red"
HTML=\$(curl -L -s -m 15 -A "Mozilla/5.0" -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8" "\$URL")
check_youtube_premium_region() {
    echo "\$HTML" | grep -qiE "not available in your country|在你所在的国家/地区尚未推出|YouTube Premium is not available in your country|This service isn't available in your country" && return 0
    REGION=\$(printf '%s' "\$HTML" | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"|"GL":"[A-Z]{2}"' | head -n1 | grep -oE '[A-Z]{2}' | tail -n1)
    PREMIUM_AVAILABLE_COUNTRIES="DZ AS AR AW AU AT AZ BH BD BY BE BM BO BA BR BG KH CA KY CL CO CR HR CY CZ DK DO EC EG SV EE FI FR GF PF GE DE GH GR GP GU GT HN HK HU IS IN ID IQ IE IL IT JM JP JO KZ KE KW LA LV LB LY LI LT LU MY MT MX MA NP NL NZ NI NG MK MP NO OM PK PA PG PY PE PH PL PT PR QA RE RO SA SN RS SG SK SI ZA KR ES LK SE CH TW TZ TH TN TR TC VI UG AE GB US UY VE VN YE ZW"
    if [ -n "\$REGION" ] && ! echo " \$PREMIUM_AVAILABLE_COUNTRIES " | grep -qw "\$REGION"; then
        return 0
    fi
    return 1
}
check_youtube_premium_region
DETECTED=\$?
if [ "\${1:-}" = "--test" ] || [ \$DETECTED -eq 0 ]; then
if [ "\${1:-}" = "--test" ]; then
TEST_TIME=\$(date '+%Y%m%d-%H%M%S')
BODY="🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具
测试时间: \${TEST_TIME}"
SUBJECT="[${REMARK}] [其他 API]区域监控告警测试邮件 \$(date '+%Y/%m/%d %H:%M:%S')"
else
BODY="❗️可能送中了❗️🏷 节点：${REMARK}

⚠️ YouTube Premium 区域限制触发
https://www.youtube.com/red

❌可能送中了❗️更多详情查看❌
https://www.google.com/search?q=家具"
SUBJECT="❗️可能送中了❗️[${REMARK}]⚠️ [其他 API] ❌YouTube 区域监控告警❌ \$(date '+%Y/%m/%d %H:%M:%S')"
fi
curl -s -m 15 "${API_URL}" -H "${API_HEADER} ${API_KEY}" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "from=${FROM_EMAIL}" --data-urlencode "to=${TO_EMAIL}" --data-urlencode "subject=\$SUBJECT" --data-urlencode "text=\$BODY" >/dev/null 2>&1
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-qita-email.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-qita-email.sh" | grep -v "^# Google监控 其他API邮件通知$"; echo "# Google监控 其他API邮件通知"; echo "0 */2 * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-qita-email.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ 其他API邮件通知安装完成"
                            echo -e "${gl_hong}请测试发信，不是所有邮件 API 都兼容 Authorization: Bearer/form 表单。${gl_bai}"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        4)
                            clear
                            echo "▶️ 删除 Google监控邮件通知"
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
                                        [Yy]) crontab -l 2>/dev/null | grep -v "jiancegoogle-Resend-email.sh" | grep -v "^# Google监控 Resend邮件通知$" | crontab -; rm -f /home/jiancegoogle-Resend-email.sh; echo "✅ Resend邮件通知已删除" ;;
                                        *) echo "已取消删除" ;;
                                    esac
                                    ;;
                                2)
                                    read -e -p "确定删除 SMTP 邮件通知吗？(Y/N): " confirm_del_mail
                                    case "$confirm_del_mail" in
                                        [Yy]) crontab -l 2>/dev/null | grep -v "jiancegoogle-smtp-email.sh" | grep -v "^# Google监控 SMTP邮件通知$" | crontab -; rm -f /home/jiancegoogle-smtp-email.sh; echo "✅ SMTP邮件通知已删除" ;;
                                        *) echo "已取消删除" ;;
                                    esac
                                    ;;
                                3)
                                    read -e -p "确定删除 其他API 邮件通知吗？(Y/N): " confirm_del_mail
                                    case "$confirm_del_mail" in
                                        [Yy]) crontab -l 2>/dev/null | grep -v "jiancegoogle-qita-email.sh" | grep -v "^# Google监控 其他API邮件通知$" | crontab -; rm -f /home/jiancegoogle-qita-email.sh; echo "✅ 其他API邮件通知已删除" ;;
                                        *) echo "已取消删除" ;;
                                    esac
                                    ;;
                                4)
                                    read -e -p "确定删除全部 Google监控邮件通知吗？(Y/N): " confirm_del_mail
                                    case "$confirm_del_mail" in
                                        [Yy]) crontab -l 2>/dev/null | grep -v "jiancegoogle-Resend-email.sh" | grep -v "jiancegoogle-smtp-email.sh" | grep -v "jiancegoogle-qita-email.sh" | grep -v "^# Google监控 Resend邮件通知$" | grep -v "^# Google监控 SMTP邮件通知$" | grep -v "^# Google监控 其他API邮件通知$" | crontab -; rm -f /home/jiancegoogle-Resend-email.sh /home/jiancegoogle-smtp-email.sh /home/jiancegoogle-qita-email.sh /home/jiancegoogleemail.sh; echo "✅ 全部邮件通知已删除" ;;
                                        *) echo "已取消删除" ;;
                                    esac
                                    ;;
                                0) ;;
                                *) echo "无效选择" ;;
                            esac
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        0) break ;;
                        *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                    esac
                done
                ;;
            3)
                clear
                echo "▶️ 卸载 Google监控通知"
                echo "------------------------"
                read -e -p "确定删除 Google监控 Telegram/邮件通知、脚本和定时任务吗？(Y/N): " confirm_google_uninstall
                case "$confirm_google_uninstall" in
                    [Yy])
                        crontab -l 2>/dev/null | grep -v "jiancegoogle-telegram.sh" | grep -v "jiancegoogle-Resend-email.sh" | grep -v "jiancegoogle-smtp-email.sh" | grep -v "jiancegoogle-qita-email.sh" | grep -v "jiancegoogleemail.sh" | grep -v "^# Google监控" | crontab -
                        rm -f /home/jiancegoogle-telegram.sh /home/jiancegoogle-Resend-email.sh /home/jiancegoogle-smtp-email.sh /home/jiancegoogle-qita-email.sh /home/jiancegoogleemail.sh
                        echo "✅ Google监控通知已卸载，脚本和定时任务已删除"
                        ;;
                    *) echo "已取消卸载" ;;
                esac
                read -n1 -r -p "按任意键继续..."
                ;;
            4)
                clear
                echo "▶️ 发送 Google监控测试消息"
                echo "------------------------"
                sent_any=0
                if [ -x /home/jiancegoogle-telegram.sh ]; then
                    echo "发送 Telegram 测试消息..."
                    /bin/bash /home/jiancegoogle-telegram.sh --test >/dev/null 2>&1 || true
                    sent_any=1
                fi
                if [ -x /home/jiancegoogle-Resend-email.sh ]; then
                    echo "发送 Resend 邮件测试消息..."
                    /bin/bash /home/jiancegoogle-Resend-email.sh --test >/dev/null 2>&1 || true
                    sent_any=1
                fi
                if [ -x /home/jiancegoogle-smtp-email.sh ]; then
                    echo "发送 SMTP 邮件测试消息..."
                    /bin/bash /home/jiancegoogle-smtp-email.sh --test >/dev/null 2>&1 || true
                    sent_any=1
                fi
                if [ -x /home/jiancegoogle-qita-email.sh ]; then
                    echo "发送 其他API 邮件测试消息..."
                    /bin/bash /home/jiancegoogle-qita-email.sh --test >/dev/null 2>&1 || true
                    sent_any=1
                fi
                if [ "$sent_any" = "0" ]; then
                    echo "暂无已添加的通知配置，已跳过。"
                else
                    echo "测试消息已触发，请检查对应 Telegram/邮箱。"
                fi
                read -n1 -r -p "按任意键继续..."
                ;;

            5)
                while true; do
                    clear
                    echo "▶️ Google监控系统安装"
                    echo "================================"
                    echo "1. 经纬度 Telegram 通知"
                    echo "2. 删除 Telegram 通知"
                    echo "0. 返回"
                    echo "================================"
                    read -e -p "请输入选项: " jwd_tg_opt
                    case "$jwd_tg_opt" in
                        1)
                            google_ensure_maps_deps || { read -n1 -r -p "按任意键继续..."; continue; }
                            google_confirm_overwrite "经纬度Telegram通知" "/home/jiancegoogle-jingweidu-telegram.sh" "jiancegoogle-jingweidu-telegram.sh" || continue
                            google_jwd_read_common
                            read -p "请输入 Bot Token: " BOT_TOKEN
                            BOT_TOKEN=$(echo "$BOT_TOKEN" | sed 's#https://api.telegram.org/bot##g' | sed 's#/sendMessage##g')
                            read -p "请输入 Chat ID: " CHAT_ID
                            cat > /home/jiancegoogle-jingweidu-telegram.sh <<EOF
#!/bin/bash
REMARK="${REMARK}"
TARGET_REGION="${TARGET_REGION}"
BASE_COORDS="${BASE_COORDS}"
OFFSET_KM="${OFFSET_KM}"
DAILY_HOUR="${DAILY_HOUR}"
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
STATE_FILE="/home/jiancegoogle-jingweidu-telegram.state"
get_maps_coords() {
    BROWSER=""
    for b in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "\$b" >/dev/null 2>&1; then BROWSER=\$(command -v "\$b"); break; fi
    done
    [ -z "\$BROWSER" ] && return 1
    r=\$RANDOM; PORT=\$((40000 + r - r / 20000 * 20000))
    PROFILE=\$(mktemp -d)
    "\$BROWSER" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --window-size=1280,800 --lang=en-US --remote-debugging-address=127.0.0.1 --remote-debugging-port="\$PORT" --user-data-dir="\$PROFILE" "https://www.google.com/maps/" >/tmp/google-maps-jwd.log 2>&1 &
    BROWSER_PID=\$!
    COORDS=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        COORDS=\$(python3 - "\$PORT" <<'PYEOF' 2>/dev/null
import json, re, sys, urllib.request
port=sys.argv[1]
try:
    pages=json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2).read().decode())
except Exception:
    sys.exit(0)
for p in pages:
    url=p.get('url','')
    if 'google.com/maps' in url:
        m=re.search(r'/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(\d+(?:\.\d+)?z?)', url)
        if m:
            print(f"{m.group(1)},{m.group(2)},{m.group(3).rstrip('z')}")
            break
PYEOF
)
        [ -n "\$COORDS" ] && break
        sleep 1
    done
    kill "\$BROWSER_PID" >/dev/null 2>&1 || true
    wait "\$BROWSER_PID" 2>/dev/null || true
    sleep 1
    rm -rf "\$PROFILE" >/dev/null 2>&1 || true
    [ -n "\$COORDS" ] && { echo "\$COORDS"; return 0; }
    return 1
}
CURRENT_COORDS=\$(get_maps_coords)
[ -z "\$CURRENT_COORDS" ] && CURRENT_COORDS="未知"
BASE_LAT=\$(echo "\$BASE_COORDS" | cut -d, -f1)
BASE_LON=\$(echo "\$BASE_COORDS" | cut -d, -f2)
CURRENT_LAT=\$(echo "\$CURRENT_COORDS" | cut -d, -f1)
CURRENT_LON=\$(echo "\$CURRENT_COORDS" | cut -d, -f2)
DISTANCE_KM=\$(python3 - "\$BASE_LAT" "\$BASE_LON" "\$CURRENT_LAT" "\$CURRENT_LON" <<'PYEOF' 2>/dev/null
import math, sys
try:
    lat1, lon1, lat2, lon2 = map(float, sys.argv[1:5])
    r=6371.0
    p1=math.radians(lat1); p2=math.radians(lat2)
    dphi=math.radians(lat2-lat1); dl=math.radians(lon2-lon1)
    a=math.sin(dphi/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    print(int(round(r*2*math.atan2(math.sqrt(a), math.sqrt(1-a)))))
except Exception:
    print("未知")
PYEOF
)
STATUS="正常"
if [ "\$DISTANCE_KM" = "未知" ] || [ "\$CURRENT_COORDS" = "未知" ]; then
    STATUS="异常"
elif [ "\$DISTANCE_KM" -gt "\$OFFSET_KM" ] 2>/dev/null; then
    STATUS="异常"
fi
TODAY=\$(TZ=Asia/Shanghai date +%F)
BJ_HOUR=\$(TZ=Asia/Shanghai date +%H)
SEND=0
if [ "\${1:-}" = "--test" ]; then SEND=1; STATUS="正常"; elif [ "\$STATUS" = "异常" ]; then SEND=1; elif [ "\$BJ_HOUR" = "\$DAILY_HOUR" ] && [ "\$(cat "\$STATE_FILE" 2>/dev/null)" != "\$TODAY" ]; then SEND=1; fi
if [ "\$SEND" = "1" ]; then
if [ "\$STATUS" = "异常" ]; then
TEXT="⚠️可能送中了🏷 节点：\$REMARK

当前 Google Maps 

检测地区：用户指定经纬度异常

目标地区：\$TARGET_REGION      状态：异常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
⚠️可能送中了，更多详情查看
https://www.google.com/search?q=家具"
else
TEXT="🌍Google Maps 地区检测日报🏷 节点：\$REMARK

当前 Google Maps 

检测地区：\$TARGET_REGION

目标地区：\$TARGET_REGION      状态：正常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
更多详情查看
https://www.google.com/search?q=家具"
fi
curl -s -m 10 "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" -d chat_id="\$CHAT_ID" --data-urlencode text="\$TEXT" >/dev/null 2>&1 || true
[ "\$STATUS" = "正常" ] && [ "\${1:-}" != "--test" ] && echo "\$TODAY" > "\$STATE_FILE"
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-jingweidu-telegram.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-telegram.sh" | grep -v "^# Google经纬度监控 Telegram通知$" | grep -v "^# Google经纬度监控 Telegram日报$"; echo "# Google经纬度监控 Telegram通知"; echo "5 * * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-telegram.sh' >/dev/null 2>&1"; echo "# Google经纬度监控 Telegram日报"; echo "0 ${DAILY_HOUR} * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-telegram.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ 经纬度Telegram通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        2)
                            read -e -p "确定删除 经纬度 Telegram 通知吗？(Y/N): " confirm_del_jwd_tg
                            case "$confirm_del_jwd_tg" in
                                [Yy]) crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-telegram.sh" | grep -v "^# Google经纬度监控 Telegram通知$" | grep -v "^# Google经纬度监控 Telegram日报$" | crontab -; rm -f /home/jiancegoogle-jingweidu-telegram.sh /home/jiancegoogle-jingweidu-telegram.state; echo "✅ 经纬度Telegram通知已删除" ;;
                                *) echo "已取消删除" ;;
                            esac
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        0) break ;;
                        *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                    esac
                done
                ;;
            6)
                while true; do
                    clear
                    echo "▶️ Google监控系统安装"
                    echo "================================"
                    echo "1. 经纬度 Resend API 发信（每2小时第 10 分钟）"
                    echo "2. 经纬度 SMTP 发信（部分VPS可能不支持）（每2小时第 15 分钟）"
                    echo "3. 经纬度 其他 API 发信（每2小时第 20 分钟）"
                    echo "4. 删除邮件通知"
                    echo "0. 返回"
                    echo "================================"
                    read -e -p "请输入选项: " jwd_mail_opt
                    case "$jwd_mail_opt" in
                        1)
                            google_ensure_maps_deps || { read -n1 -r -p "按任意键继续..."; continue; }
                            google_confirm_overwrite "经纬度Resend邮件通知" "/home/jiancegoogle-jingweidu-Resend-email.sh" "jiancegoogle-jingweidu-Resend-email.sh" || continue
                            google_jwd_read_common
                            read -p "请输入 Resend API Key: " RESEND_KEY
                            read -p "请输入发件邮箱(From): " FROM_EMAIL
                            read -p "请输入收件邮箱(To): " TO_EMAIL
                            cat > /home/jiancegoogle-jingweidu-Resend-email.sh <<EOF
#!/bin/bash
REMARK="${REMARK}"
TARGET_REGION="${TARGET_REGION}"
BASE_COORDS="${BASE_COORDS}"
OFFSET_KM="${OFFSET_KM}"
DAILY_HOUR="${DAILY_HOUR}"
STATE_FILE="/home/jiancegoogle-jingweidu-Resend-email.state"
get_maps_coords() {
    BROWSER=""
    for b in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "\$b" >/dev/null 2>&1; then BROWSER=\$(command -v "\$b"); break; fi
    done
    [ -z "\$BROWSER" ] && return 1
    r=\$RANDOM; PORT=\$((40000 + r - r / 20000 * 20000))
    PROFILE=\$(mktemp -d)
    "\$BROWSER" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --window-size=1280,800 --lang=en-US --remote-debugging-address=127.0.0.1 --remote-debugging-port="\$PORT" --user-data-dir="\$PROFILE" "https://www.google.com/maps/" >/tmp/google-maps-jwd.log 2>&1 &
    BROWSER_PID=\$!
    COORDS=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        COORDS=\$(python3 - "\$PORT" <<'PYEOF' 2>/dev/null
import json, re, sys, urllib.request
port=sys.argv[1]
try:
    pages=json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2).read().decode())
except Exception:
    sys.exit(0)
for p in pages:
    url=p.get('url','')
    if 'google.com/maps' in url:
        m=re.search(r'/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(\d+(?:\.\d+)?z?)', url)
        if m:
            print(f"{m.group(1)},{m.group(2)},{m.group(3).rstrip('z')}")
            break
PYEOF
)
        [ -n "\$COORDS" ] && break
        sleep 1
    done
    kill "\$BROWSER_PID" >/dev/null 2>&1 || true
    wait "\$BROWSER_PID" 2>/dev/null || true
    sleep 1
    rm -rf "\$PROFILE" >/dev/null 2>&1 || true
    [ -n "\$COORDS" ] && { echo "\$COORDS"; return 0; }
    return 1
}
CURRENT_COORDS=\$(get_maps_coords)
[ -z "\$CURRENT_COORDS" ] && CURRENT_COORDS="未知"
BASE_LAT=\$(echo "\$BASE_COORDS" | cut -d, -f1)
BASE_LON=\$(echo "\$BASE_COORDS" | cut -d, -f2)
CURRENT_LAT=\$(echo "\$CURRENT_COORDS" | cut -d, -f1)
CURRENT_LON=\$(echo "\$CURRENT_COORDS" | cut -d, -f2)
DISTANCE_KM=\$(python3 - "\$BASE_LAT" "\$BASE_LON" "\$CURRENT_LAT" "\$CURRENT_LON" <<'PYEOF' 2>/dev/null
import math, sys
try:
    lat1, lon1, lat2, lon2 = map(float, sys.argv[1:5])
    r=6371.0
    p1=math.radians(lat1); p2=math.radians(lat2)
    dphi=math.radians(lat2-lat1); dl=math.radians(lon2-lon1)
    a=math.sin(dphi/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    print(int(round(r*2*math.atan2(math.sqrt(a), math.sqrt(1-a)))))
except Exception:
    print("未知")
PYEOF
)
STATUS="正常"
if [ "\$DISTANCE_KM" = "未知" ] || [ "\$CURRENT_COORDS" = "未知" ]; then
    STATUS="异常"
elif [ "\$DISTANCE_KM" -gt "\$OFFSET_KM" ] 2>/dev/null; then
    STATUS="异常"
fi
TODAY=\$(TZ=Asia/Shanghai date +%F); BJ_HOUR=\$(TZ=Asia/Shanghai date +%H); SEND=0
if [ "\${1:-}" = "--test" ]; then SEND=1; STATUS="正常"; elif [ "\$STATUS" = "异常" ]; then SEND=1; elif [ "\$BJ_HOUR" = "\$DAILY_HOUR" ] && [ "\$(cat "\$STATE_FILE" 2>/dev/null)" != "\$TODAY" ]; then SEND=1; fi
if [ "\$SEND" = "1" ]; then
TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
if [ "\$STATUS" = "异常" ]; then
SUBJECT="⚠️可能送中了🏷 节点：[\$REMARK] [Resend] \$TIME_TEXT"
BODY="⚠️可能送中了🏷 节点：[\$REMARK] [Resend] \$TIME_TEXT

当前 Google Maps 

检测地区：用户指定经纬度异常

目标地区：\$TARGET_REGION      状态：异常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
⚠️可能送中了，更多详情查看
https://www.google.com/search?q=家具"
else
SUBJECT="🌍Google Maps 地区检测日报 节点：[\$REMARK] [Resend] \$TIME_TEXT"
BODY="🌍Google Maps 地区检测日报 节点：[\$REMARK] [Resend] \$TIME_TEXT

当前 Google Maps 

检测地区：\$TARGET_REGION

目标地区：\$TARGET_REGION      状态：正常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
更多详情查看
https://www.google.com/search?q=家具"
fi
curl -s -m 15 https://api.resend.com/emails -H "Authorization: Bearer ${RESEND_KEY}" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "from=${FROM_EMAIL}" --data-urlencode "to=${TO_EMAIL}" --data-urlencode "subject=\$SUBJECT" --data-urlencode "text=\$BODY" >/dev/null 2>&1 || true
[ "\$STATUS" = "正常" ] && [ "\${1:-}" != "--test" ] && echo "\$TODAY" > "\$STATE_FILE"
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-jingweidu-Resend-email.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-Resend-email.sh" | grep -v "^# Google经纬度监控 Resend邮件通知$" | grep -v "^# Google经纬度监控 Resend邮件日报$"; echo "# Google经纬度监控 Resend邮件通知"; echo "10 */2 * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-Resend-email.sh' >/dev/null 2>&1"; echo "# Google经纬度监控 Resend邮件日报"; echo "0 ${DAILY_HOUR} * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-Resend-email.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ 经纬度Resend邮件通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        2)
                            google_ensure_maps_deps || { read -n1 -r -p "按任意键继续..."; continue; }
                            google_confirm_overwrite "经纬度SMTP邮件通知" "/home/jiancegoogle-jingweidu-smtp-email.sh" "jiancegoogle-jingweidu-smtp-email.sh" || continue
                            google_jwd_read_common
                            read -p "请输入 SMTP服务器: " SMTP_HOST
                            read -p "请输入 SMTP端口465或者587 [默认: 587]: " SMTP_PORT
                            SMTP_PORT=${SMTP_PORT:-587}
                            read -p "是否启用SSL? 465端口通常选Y，587通常选N (Y/N) [默认: N]: " SMTP_SSL
                            SMTP_SSL=${SMTP_SSL:-N}
                            read -p "请输入 SMTP用户名: " SMTP_USER
                            read -s -p "请输入 SMTP密码/授权码: " SMTP_PASS; echo
                            read -p "请输入发件邮箱(From): " FROM_EMAIL
                            read -p "请输入收件邮箱(To): " TO_EMAIL
                            cat > /home/jiancegoogle-jingweidu-smtp-email.sh <<EOF
#!/bin/bash
REMARK="${REMARK}"; TARGET_REGION="${TARGET_REGION}"; BASE_COORDS="${BASE_COORDS}"; OFFSET_KM="${OFFSET_KM}"; DAILY_HOUR="${DAILY_HOUR}"
SMTP_HOST="${SMTP_HOST}"; SMTP_PORT="${SMTP_PORT}"; SMTP_SSL="${SMTP_SSL}"; SMTP_USER="${SMTP_USER}"; SMTP_PASS="${SMTP_PASS}"; FROM_EMAIL="${FROM_EMAIL}"; TO_EMAIL="${TO_EMAIL}"
STATE_FILE="/home/jiancegoogle-jingweidu-smtp-email.state"
get_maps_coords() {
    BROWSER=""
    for b in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "\$b" >/dev/null 2>&1; then BROWSER=\$(command -v "\$b"); break; fi
    done
    [ -z "\$BROWSER" ] && return 1
    r=\$RANDOM; PORT=\$((40000 + r - r / 20000 * 20000))
    PROFILE=\$(mktemp -d)
    "\$BROWSER" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --window-size=1280,800 --lang=en-US --remote-debugging-address=127.0.0.1 --remote-debugging-port="\$PORT" --user-data-dir="\$PROFILE" "https://www.google.com/maps/" >/tmp/google-maps-jwd.log 2>&1 &
    BROWSER_PID=\$!
    COORDS=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        COORDS=\$(python3 - "\$PORT" <<'PYEOF' 2>/dev/null
import json, re, sys, urllib.request
port=sys.argv[1]
try:
    pages=json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2).read().decode())
except Exception:
    sys.exit(0)
for p in pages:
    url=p.get('url','')
    if 'google.com/maps' in url:
        m=re.search(r'/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(\d+(?:\.\d+)?z?)', url)
        if m:
            print(f"{m.group(1)},{m.group(2)},{m.group(3).rstrip('z')}")
            break
PYEOF
)
        [ -n "\$COORDS" ] && break
        sleep 1
    done
    kill "\$BROWSER_PID" >/dev/null 2>&1 || true
    wait "\$BROWSER_PID" 2>/dev/null || true
    sleep 1
    rm -rf "\$PROFILE" >/dev/null 2>&1 || true
    [ -n "\$COORDS" ] && { echo "\$COORDS"; return 0; }
    return 1
}
CURRENT_COORDS=\$(get_maps_coords)
[ -z "\$CURRENT_COORDS" ] && CURRENT_COORDS="未知"
BASE_LAT=\$(echo "\$BASE_COORDS" | cut -d, -f1)
BASE_LON=\$(echo "\$BASE_COORDS" | cut -d, -f2)
CURRENT_LAT=\$(echo "\$CURRENT_COORDS" | cut -d, -f1)
CURRENT_LON=\$(echo "\$CURRENT_COORDS" | cut -d, -f2)
DISTANCE_KM=\$(python3 - "\$BASE_LAT" "\$BASE_LON" "\$CURRENT_LAT" "\$CURRENT_LON" <<'PYEOF' 2>/dev/null
import math, sys
try:
    lat1, lon1, lat2, lon2 = map(float, sys.argv[1:5])
    r=6371.0
    p1=math.radians(lat1); p2=math.radians(lat2)
    dphi=math.radians(lat2-lat1); dl=math.radians(lon2-lon1)
    a=math.sin(dphi/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    print(int(round(r*2*math.atan2(math.sqrt(a), math.sqrt(1-a)))))
except Exception:
    print("未知")
PYEOF
)
STATUS="正常"
if [ "\$DISTANCE_KM" = "未知" ] || [ "\$CURRENT_COORDS" = "未知" ]; then
    STATUS="异常"
elif [ "\$DISTANCE_KM" -gt "\$OFFSET_KM" ] 2>/dev/null; then
    STATUS="异常"
fi
TODAY=\$(TZ=Asia/Shanghai date +%F); BJ_HOUR=\$(TZ=Asia/Shanghai date +%H); SEND=0
if [ "\${1:-}" = "--test" ]; then SEND=1; STATUS="正常"; elif [ "\$STATUS" = "异常" ]; then SEND=1; elif [ "\$BJ_HOUR" = "\$DAILY_HOUR" ] && [ "\$(cat "\$STATE_FILE" 2>/dev/null)" != "\$TODAY" ]; then SEND=1; fi
if [ "\$SEND" = "1" ]; then
TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
if [ "\$STATUS" = "异常" ]; then
SMTP_SUBJECT="⚠️可能送中了🏷 节点：[\$REMARK] [SMTP] \$TIME_TEXT"
SMTP_BODY="⚠️可能送中了🏷 节点：[\$REMARK] [SMTP] \$TIME_TEXT

当前 Google Maps 

检测地区：用户指定经纬度异常

目标地区：\$TARGET_REGION      状态：异常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
⚠️可能送中了，更多详情查看
https://www.google.com/search?q=家具"
else
SMTP_SUBJECT="🌍Google Maps 地区检测日报 节点：[\$REMARK] [SMTP] \$TIME_TEXT"
SMTP_BODY="🌍Google Maps 地区检测日报 节点：[\$REMARK] [SMTP] \$TIME_TEXT

当前 Google Maps 

检测地区：\$TARGET_REGION

目标地区：\$TARGET_REGION      状态：正常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
更多详情查看
https://www.google.com/search?q=家具"
fi
export SMTP_HOST SMTP_PORT SMTP_SSL SMTP_USER SMTP_PASS FROM_EMAIL TO_EMAIL SMTP_SUBJECT SMTP_BODY
python3 - <<'PYEOF' >/dev/null 2>&1 || true
import os, smtplib, ssl
from email.message import EmailMessage
msg=EmailMessage(); msg['From']=os.environ['FROM_EMAIL']; msg['To']=os.environ['TO_EMAIL']; msg['Subject']=os.environ.get('SMTP_SUBJECT','Google Maps 地区检测'); msg.set_content(os.environ.get('SMTP_BODY',''))
host=os.environ['SMTP_HOST']; port=int(os.environ.get('SMTP_PORT','587')); use_ssl=os.environ.get('SMTP_SSL','N').lower().startswith('y')
server=smtplib.SMTP_SSL(host, port, timeout=20, context=ssl.create_default_context()) if use_ssl else smtplib.SMTP(host, port, timeout=20)
if not use_ssl:
    server.ehlo()
    if port != 25: server.starttls(context=ssl.create_default_context()); server.ehlo()
if os.environ.get('SMTP_USER'): server.login(os.environ.get('SMTP_USER'), os.environ.get('SMTP_PASS',''))
server.send_message(msg); server.quit()
PYEOF
[ "\$STATUS" = "正常" ] && [ "\${1:-}" != "--test" ] && echo "\$TODAY" > "\$STATE_FILE"
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-jingweidu-smtp-email.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-smtp-email.sh" | grep -v "^# Google经纬度监控 SMTP邮件通知$" | grep -v "^# Google经纬度监控 SMTP邮件日报$"; echo "# Google经纬度监控 SMTP邮件通知"; echo "15 */2 * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-smtp-email.sh' >/dev/null 2>&1"; echo "# Google经纬度监控 SMTP邮件日报"; echo "0 ${DAILY_HOUR} * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-smtp-email.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ 经纬度SMTP邮件通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        3)
                            google_ensure_maps_deps || { read -n1 -r -p "按任意键继续..."; continue; }
                            google_confirm_overwrite "经纬度其他API邮件通知" "/home/jiancegoogle-jingweidu-qita-email.sh" "jiancegoogle-jingweidu-qita-email.sh" || continue
                            google_jwd_read_common
                            read -p "请输入 API地址: " API_URL
                            read -p "请输入 API Key: " API_KEY
                            read -p "请输入请求头（回车默认Authorization: Bearer）: " API_HEADER
                            if [ -z "$API_HEADER" ]; then API_HEADER="Authorization: Bearer"; fi
                            read -p "请输入发件邮箱(From): " FROM_EMAIL
                            read -p "请输入收件邮箱(To): " TO_EMAIL
                            cat > /home/jiancegoogle-jingweidu-qita-email.sh <<EOF
#!/bin/bash
REMARK="${REMARK}"; TARGET_REGION="${TARGET_REGION}"; BASE_COORDS="${BASE_COORDS}"; OFFSET_KM="${OFFSET_KM}"; DAILY_HOUR="${DAILY_HOUR}"; STATE_FILE="/home/jiancegoogle-jingweidu-qita-email.state"
get_maps_coords() {
    BROWSER=""
    for b in chromium chromium-browser google-chrome google-chrome-stable; do
        if command -v "\$b" >/dev/null 2>&1; then BROWSER=\$(command -v "\$b"); break; fi
    done
    [ -z "\$BROWSER" ] && return 1
    r=\$RANDOM; PORT=\$((40000 + r - r / 20000 * 20000))
    PROFILE=\$(mktemp -d)
    "\$BROWSER" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --window-size=1280,800 --lang=en-US --remote-debugging-address=127.0.0.1 --remote-debugging-port="\$PORT" --user-data-dir="\$PROFILE" "https://www.google.com/maps/" >/tmp/google-maps-jwd.log 2>&1 &
    BROWSER_PID=\$!
    COORDS=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
        COORDS=\$(python3 - "\$PORT" <<'PYEOF' 2>/dev/null
import json, re, sys, urllib.request
port=sys.argv[1]
try:
    pages=json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=2).read().decode())
except Exception:
    sys.exit(0)
for p in pages:
    url=p.get('url','')
    if 'google.com/maps' in url:
        m=re.search(r'/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?),(\d+(?:\.\d+)?z?)', url)
        if m:
            print(f"{m.group(1)},{m.group(2)},{m.group(3).rstrip('z')}")
            break
PYEOF
)
        [ -n "\$COORDS" ] && break
        sleep 1
    done
    kill "\$BROWSER_PID" >/dev/null 2>&1 || true
    wait "\$BROWSER_PID" 2>/dev/null || true
    sleep 1
    rm -rf "\$PROFILE" >/dev/null 2>&1 || true
    [ -n "\$COORDS" ] && { echo "\$COORDS"; return 0; }
    return 1
}
CURRENT_COORDS=\$(get_maps_coords)
[ -z "\$CURRENT_COORDS" ] && CURRENT_COORDS="未知"
BASE_LAT=\$(echo "\$BASE_COORDS" | cut -d, -f1)
BASE_LON=\$(echo "\$BASE_COORDS" | cut -d, -f2)
CURRENT_LAT=\$(echo "\$CURRENT_COORDS" | cut -d, -f1)
CURRENT_LON=\$(echo "\$CURRENT_COORDS" | cut -d, -f2)
DISTANCE_KM=\$(python3 - "\$BASE_LAT" "\$BASE_LON" "\$CURRENT_LAT" "\$CURRENT_LON" <<'PYEOF' 2>/dev/null
import math, sys
try:
    lat1, lon1, lat2, lon2 = map(float, sys.argv[1:5])
    r=6371.0
    p1=math.radians(lat1); p2=math.radians(lat2)
    dphi=math.radians(lat2-lat1); dl=math.radians(lon2-lon1)
    a=math.sin(dphi/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    print(int(round(r*2*math.atan2(math.sqrt(a), math.sqrt(1-a)))))
except Exception:
    print("未知")
PYEOF
)
STATUS="正常"
if [ "\$DISTANCE_KM" = "未知" ] || [ "\$CURRENT_COORDS" = "未知" ]; then
    STATUS="异常"
elif [ "\$DISTANCE_KM" -gt "\$OFFSET_KM" ] 2>/dev/null; then
    STATUS="异常"
fi
TODAY=\$(TZ=Asia/Shanghai date +%F); BJ_HOUR=\$(TZ=Asia/Shanghai date +%H); SEND=0
if [ "\${1:-}" = "--test" ]; then SEND=1; STATUS="正常"; elif [ "\$STATUS" = "异常" ]; then SEND=1; elif [ "\$BJ_HOUR" = "\$DAILY_HOUR" ] && [ "\$(cat "\$STATE_FILE" 2>/dev/null)" != "\$TODAY" ]; then SEND=1; fi
if [ "\$SEND" = "1" ]; then
TIME_TEXT=\$(date '+%Y/%m/%d %H:%M:%S')
if [ "\$STATUS" = "异常" ]; then SUBJECT="⚠️可能送中了🏷 节点：[\$REMARK] [其他 API] \$TIME_TEXT"; BODY="⚠️可能送中了🏷 节点：[\$REMARK] [其他 API] \$TIME_TEXT

当前 Google Maps 

检测地区：用户指定经纬度异常

目标地区：\$TARGET_REGION      状态：异常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
⚠️可能送中了，更多详情查看
https://www.google.com/search?q=家具"; else SUBJECT="🌍Google Maps 地区检测日报 节点：[\$REMARK] [其他 API] \$TIME_TEXT"; BODY="🌍Google Maps 地区检测日报 节点：[\$REMARK] [其他 API] \$TIME_TEXT

当前 Google Maps 

检测地区：\$TARGET_REGION

目标地区：\$TARGET_REGION      状态：正常
当前经纬度：\$CURRENT_COORDS
基准经纬度：\$BASE_COORDS
偏移距离：\${DISTANCE_KM}公里
更多详情查看
https://www.google.com/search?q=家具"; fi
curl -s -m 15 "${API_URL}" -H "${API_HEADER} ${API_KEY}" -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "from=${FROM_EMAIL}" --data-urlencode "to=${TO_EMAIL}" --data-urlencode "subject=\$SUBJECT" --data-urlencode "text=\$BODY" >/dev/null 2>&1 || true
[ "\$STATUS" = "正常" ] && [ "\${1:-}" != "--test" ] && echo "\$TODAY" > "\$STATE_FILE"
fi
exit 0
EOF
                            chmod +x /home/jiancegoogle-jingweidu-qita-email.sh
                            ( crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-qita-email.sh" | grep -v "^# Google经纬度监控 其他API邮件通知$" | grep -v "^# Google经纬度监控 其他API邮件日报$"; echo "# Google经纬度监控 其他API邮件通知"; echo "20 */2 * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-qita-email.sh' >/dev/null 2>&1"; echo "# Google经纬度监控 其他API邮件日报"; echo "0 ${DAILY_HOUR} * * * /bin/bash -c 'r=\$RANDOM; sleep \$((r - r / 300 * 300)); /bin/bash /home/jiancegoogle-jingweidu-qita-email.sh' >/dev/null 2>&1" ) | crontab -
                            echo "✅ 经纬度其他API邮件通知安装完成"
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        4)
                            clear
                            echo "▶️ 删除 Google经纬度邮件通知"
                            echo "================================"
                            echo "1. Resend API 发信"
                            echo "2. SMTP 发信"
                            echo "3. 其他 API 发信"
                            echo "4. 删除全部"
                            echo "0. 返回上一级"
                            echo "================================"
                            read -e -p "输入要删除的序号: " del_jwd_mail_opt
                            case "$del_jwd_mail_opt" in
                                1) crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-Resend-email.sh" | grep -v "^# Google经纬度监控 Resend邮件通知$" | grep -v "^# Google经纬度监控 Resend邮件日报$" | crontab -; rm -f /home/jiancegoogle-jingweidu-Resend-email.sh /home/jiancegoogle-jingweidu-Resend-email.state; echo "✅ 经纬度Resend邮件通知已删除" ;;
                                2) crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-smtp-email.sh" | grep -v "^# Google经纬度监控 SMTP邮件通知$" | grep -v "^# Google经纬度监控 SMTP邮件日报$" | crontab -; rm -f /home/jiancegoogle-jingweidu-smtp-email.sh /home/jiancegoogle-jingweidu-smtp-email.state; echo "✅ 经纬度SMTP邮件通知已删除" ;;
                                3) crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-qita-email.sh" | grep -v "^# Google经纬度监控 其他API邮件通知$" | grep -v "^# Google经纬度监控 其他API邮件日报$" | crontab -; rm -f /home/jiancegoogle-jingweidu-qita-email.sh /home/jiancegoogle-jingweidu-qita-email.state; echo "✅ 经纬度其他API邮件通知已删除" ;;
                                4) crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-Resend-email.sh" | grep -v "jiancegoogle-jingweidu-smtp-email.sh" | grep -v "jiancegoogle-jingweidu-qita-email.sh" | grep -v "^# Google经纬度监控" | crontab -; rm -f /home/jiancegoogle-jingweidu-Resend-email.sh /home/jiancegoogle-jingweidu-Resend-email.state /home/jiancegoogle-jingweidu-smtp-email.sh /home/jiancegoogle-jingweidu-smtp-email.state /home/jiancegoogle-jingweidu-qita-email.sh /home/jiancegoogle-jingweidu-qita-email.state; echo "✅ 全部经纬度邮件通知已删除" ;;
                                0) ;;
                                *) echo "无效选择" ;;
                            esac
                            read -n1 -r -p "按任意键继续..."
                            break
                            ;;
                        0) break ;;
                        *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
                    esac
                done
                ;;
            7)
                clear
                echo "▶️ 卸载 Google经纬度通知"
                echo "------------------------"
                read -e -p "确定删除 Google经纬度 Telegram/邮件通知、脚本、定时任务，并卸载 Chromium/Chrome 吗？Python 3不会卸载。(Y/N): " confirm_jwd_uninstall
                case "$confirm_jwd_uninstall" in
                    [Yy])
                        crontab -l 2>/dev/null | grep -v "jiancegoogle-jingweidu-telegram.sh" | grep -v "jiancegoogle-jingweidu-Resend-email.sh" | grep -v "jiancegoogle-jingweidu-smtp-email.sh" | grep -v "jiancegoogle-jingweidu-qita-email.sh" | grep -v "^# Google经纬度监控" | crontab -
                        rm -f /home/jiancegoogle-jingweidu-telegram.sh /home/jiancegoogle-jingweidu-telegram.state /home/jiancegoogle-jingweidu-Resend-email.sh /home/jiancegoogle-jingweidu-Resend-email.state /home/jiancegoogle-jingweidu-smtp-email.sh /home/jiancegoogle-jingweidu-smtp-email.state /home/jiancegoogle-jingweidu-qita-email.sh /home/jiancegoogle-jingweidu-qita-email.state
                        pkill -f 'chromium.*google.com/maps' >/dev/null 2>&1 || true
                        pkill -f 'google-chrome.*google.com/maps' >/dev/null 2>&1 || true
                        echo "正在卸载 Chromium/Chrome（不卸载 Python 3）..."
                        if command -v apt-get >/dev/null 2>&1; then
                            DEBIAN_FRONTEND=noninteractive apt-get purge -y chromium chromium-common chromium-sandbox chromium-browser google-chrome-stable google-chrome google-chrome-beta google-chrome-unstable >/dev/null 2>&1 || true
                            DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1 || true
                        elif command -v dnf >/dev/null 2>&1; then
                            dnf remove -y chromium chromium-common chromium-headless google-chrome-stable google-chrome google-chrome-beta google-chrome-unstable >/dev/null 2>&1 || true
                        elif command -v yum >/dev/null 2>&1; then
                            yum remove -y chromium chromium-common chromium-headless google-chrome-stable google-chrome google-chrome-beta google-chrome-unstable >/dev/null 2>&1 || true
                        elif command -v apk >/dev/null 2>&1; then
                            apk del chromium chromium-chromedriver >/dev/null 2>&1 || true
                        elif command -v zypper >/dev/null 2>&1; then
                            zypper --non-interactive remove chromium google-chrome-stable google-chrome google-chrome-beta google-chrome-unstable >/dev/null 2>&1 || true
                        elif command -v pacman >/dev/null 2>&1; then
                            pacman -Rns --noconfirm chromium google-chrome >/dev/null 2>&1 || true
                        else
                            echo -e "${gl_huang}未检测到支持的包管理器，已跳过 Chromium/Chrome 卸载。${gl_bai}"
                        fi
                        if command -v snap >/dev/null 2>&1; then
                            snap remove chromium >/dev/null 2>&1 || true
                        fi
                        hash -r 2>/dev/null || true
                        if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
                            echo -e "${gl_huang}Chromium/Chrome 可能仍存在，请按需手动检查。${gl_bai}"
                        else
                            echo -e "${gl_lv}Chromium/Chrome 已卸载或未安装。${gl_bai}"
                        fi
                        echo "✅ Google经纬度通知已卸载，脚本和定时任务已删除，Python 3已保留"
                        ;;
                    *) echo "已取消卸载" ;;
                esac
                read -n1 -r -p "按任意键继续..."
                ;;
            8)
                clear
                echo "▶️ 发送 Google经纬度测试消息"
                echo "------------------------"
                sent_any=0
                for jwd_script in /home/jiancegoogle-jingweidu-telegram.sh /home/jiancegoogle-jingweidu-Resend-email.sh /home/jiancegoogle-jingweidu-smtp-email.sh /home/jiancegoogle-jingweidu-qita-email.sh; do
                    if [ -x "$jwd_script" ]; then
                        echo "发送 $(basename "$jwd_script") 测试消息..."
                        /bin/bash "$jwd_script" --test >/dev/null 2>&1 || true
                        sent_any=1
                    fi
                done
                if [ "$sent_any" = "0" ]; then
                    echo "暂无已添加的经纬度通知配置，已跳过。"
                else
                    echo "经纬度测试消息已触发，请检查对应 Telegram/邮箱。"
                fi
                read -n1 -r -p "按任意键继续..."
                ;;
            0) break ;;
            *) echo "无效选择"; read -n1 -r -p "按任意键继续..." ;;
        esac
    done


exit 0
