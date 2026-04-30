#!/bin/bash

# --- 配置区 ---
certs_directory="/home/web/certs"
days_before_expiry=10
acme_container="acme"
nginx_container="nginx"
acme_script_path="acme.sh"
email="admin@rowad.eu.org"

[ -t 1 ] && interactive=true || interactive=false

# --- 环境初始化 ---
if [ ! -f "${certs_directory}/acme_conf/account.conf" ]; then
    docker exec "$acme_container" "$acme_script_path" --set-default-ca --server letsencrypt >/dev/null 2>&1
    docker exec "$acme_container" "$acme_script_path" --register-account -m "$email" >/dev/null 2>&1
fi

# --- 脚本逻辑 ---
for cert_file in ${certs_directory}/*_cert.pem; do
    [ -e "$cert_file" ] || continue
    domain=$(basename "$cert_file" _cert.pem)
    [[ "$domain" == "certs*" ]] && continue

    expiration_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    
    if [ -z "$expiration_date" ]; then
        days_until_expiry=-1
    else
        expiration_timestamp=$(date -d "$expiration_date" +%s)
        current_timestamp=$(date +%s)
        days_until_expiry=$(( (expiration_timestamp - current_timestamp) / 86400 ))
    fi

    if [ "$interactive" = true ]; then
        echo "检查证书过期日期： ${domain}"
        echo "过期日期： ${expiration_date:-'文件读取失败'}"
        echo "证书 ${domain} 剩余天数： ${days_until_expiry} 天"
    fi

    if [ $days_until_expiry -le $days_before_expiry ]; then
        # 申请并安装
        docker exec "$acme_container" "$acme_script_path" --issue --dns dns_cf -d "$domain" --ecc --force --server letsencrypt >/dev/null 2>&1
        
        docker exec "$acme_container" "$acme_script_path" --install-cert -d "$domain" --ecc \
            --fullchain-file "/acme.sh/${domain}_cert.pem" \
            --key-file       "/acme.sh/${domain}_key.pem" \
            --reloadcmd     "docker exec $nginx_container nginx -s reload" >/dev/null 2>&1
        
        [ "$interactive" = true ] && echo "状态: ${domain} 已尝试更新。"
    else
        [ "$interactive" = true ] && echo "状态: ${domain} 仍然有效。"
    fi
done

# --- ⭐ 强力扫尾：保留指定文件，清理其余杂物 ---
find "${certs_directory}" -maxdepth 1 \
    ! -name "*_cert.pem" \
    ! -name "*_key.pem" \
    ! -name "acme_conf" \
    ! -name "default_server.crt" \
    ! -name "default_server.key" \
    ! -name "ticket12.key" \
    ! -name "ticket13.key" \
    ! -name "crontab" \
    ! -path "${certs_directory}" \
    -exec rm -rf {} + >/dev/null 2>&1

if [ "$interactive" = true ]; then
    echo "--------------------------"
    echo "清理完成：/home/web/certs 目录已保持纯净。"
fi
