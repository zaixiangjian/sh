#!/bin/bash

certs_directory="/home/web/certs/"
days_before_expiry=5

for cert_file in ${certs_directory}*_cert.pem; do
    # 提取域名
    yuming=$(basename "$cert_file" _cert.pem)

    # 检查是否是有效证书
    expiration_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    [ -z "$expiration_date" ] && continue  # 无效证书直接跳过

    # 输出检查信息
    echo "检查证书过期日期： ${yuming}"
    echo "过期日期： ${expiration_date}"

    expiration_timestamp=$(date -d "$expiration_date" +%s)
    current_timestamp=$(date +%s)
    days_until_expiry=$(( (expiration_timestamp - current_timestamp) / 86400 ))

    if [ $days_until_expiry -le $days_before_expiry ]; then
        # 快过期，尝试申请新证书（静默执行）
        docker stop nginx > /dev/null 2>&1

        certbot certonly --standalone \
            -d "$yuming" \
            --email your@email.com \
            --agree-tos \
            --no-eff-email \
            --force-renewal \
            --key-type ecdsa > /dev/null 2>&1 || { docker start nginx > /dev/null 2>&1; echo "证书申请失败，跳过 ${yuming}"; echo "--------------------------"; continue; }

        # 覆盖 nginx 使用的证书
        [ -f /etc/letsencrypt/live/$yuming/fullchain.pem ] && cp /etc/letsencrypt/live/$yuming/fullchain.pem ${certs_directory}${yuming}_cert.pem
        [ -f /etc/letsencrypt/live/$yuming/privkey.pem ] && cp /etc/letsencrypt/live/$yuming/privkey.pem ${certs_directory}${yuming}_key.pem

        docker start nginx > /dev/null 2>&1
        echo "证书已更新完成"
    else
        echo "证书仍然有效，距离过期还有 ${days_until_expiry} 天。"
    fi

    # 分隔线
    echo "--------------------------"
done
