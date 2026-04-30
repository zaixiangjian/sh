#!/bin/bash

# --- 配置区 ---
certs_directory="/home/web/certs"
days_before_expiry=10
acme_container="acme"
nginx_container="nginx"
acme_script_path="acme.sh"
email="admin@linbiji.com"

# 判断是否为交互式终端（手动运行则显示，自动运行则全静默）
[ -t 1 ] && interactive=true || interactive=false

# --- 环境初始化 ---
# 如果没有账号配置，静默执行初始化
if [ ! -f "${certs_directory}/acme_conf/account.conf" ]; then
    docker exec "$acme_container" "$acme_script_path" --set-default-ca --server letsencrypt >/dev/null 2>&1
    docker exec "$acme_container" "$acme_script_path" --register-account -m "$email" >/dev/null 2>&1
fi

# --- 脚本逻辑 ---
for cert_file in ${certs_directory}/*_cert.pem; do
    [ -e "$cert_file" ] || continue
    domain=$(basename "$cert_file" _cert.pem)

    # 过滤非域名文件
    [[ "$domain" == "certs*" ]] && continue

    expiration_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    
    if [ -z "$expiration_date" ]; then
        days_until_expiry=-1
    else
        expiration_timestamp=$(date -d "$expiration_date" +%s)
        current_timestamp=$(date +%s)
        days_until_expiry=$(( (expiration_timestamp - current_timestamp) / 86400 ))
    fi

    # 仅在手动运行时输出信息
    if [ "$interactive" = true ]; then
        echo "检查证书过期日期： ${domain}"
        echo "过期日期： ${expiration_date:-'文件读取失败'}"
        echo "证书 ${domain} 剩余天数： ${days_until_expiry} 天"
    fi

    # 执行更新逻辑
    if [ $days_until_expiry -le $days_before_expiry ]; then
        # 申请并安装，所有错误全丢弃 (>/dev/null 2>&1)
        docker exec "$acme_container" "$acme_script_path" --issue --dns dns_cf -d "$domain" --ecc --force --server letsencrypt >/dev/null 2>&1
        
        docker exec "$acme_container" "$acme_script_path" --install-cert -d "$domain" --ecc \
            --fullchain-file "/acme.sh/${domain}_cert.pem" \
            --key-file       "/acme.sh/${domain}_key.pem" \
            --reloadcmd     "docker exec $nginx_container nginx -s reload" >/dev/null 2>&1
        
        [ "$interactive" = true ] && echo "状态: ${domain} 已尝试更新。"
    else
        [ "$interactive" = true ] && echo "状态: ${domain} 仍然有效。"
    fi
    [ "$interactive" = true ] && echo "--------------------------"
done
