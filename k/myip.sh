#!/bin/bash

SCRIPT_PATH="/home/myip.sh"
DB_FILE="/home/myip_db.txt"

# =========================
# 依赖检查（支持 apt/yum 并自动安装 jq）
# =========================
install_deps() {
  if command -v apt >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || apt install curl -y
    command -v dig >/dev/null 2>&1 || apt install dnsutils -y
    command -v jq >/dev/null 2>&1 || apt install jq -y
  elif command -v yum >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || yum install curl -y
    command -v dig >/dev/null 2>&1 || yum install bind-utils -y
    command -v jq >/dev/null 2>&1 || yum install jq -y
  fi
}

# =========================
# 输入校验
# =========================
require_input() {
  local var=$1
  local prompt=$2
  local val

  while true; do
    read -p "$prompt" val
    [[ -n "$val" ]] && break
    echo "❌ 不能为空"
  done

  # 清理可能不小心复制进去的前后空格
  val=$(echo "$val" | xargs)
  eval "$var='$val'"
}

# =========================
# 安装
# =========================
install() {

  install_deps

  echo "===== Cloudflare DDNS（终极彻底终结旧IP版）====="

  require_input DDNS "DDNS域名: "
  require_input ACCOUNT_ID "ACCOUNT_ID: "
  require_input LIST_ID "LIST_ID: "
  require_input API_TOKEN "API_TOKEN: "

  read -p "定时分钟(默认5,2-60): " MIN
  MIN=${MIN:-5}
  ((MIN<2)) && MIN=2
  ((MIN>60)) && MIN=60

  echo "$DDNS|$ACCOUNT_ID|$LIST_ID|$API_TOKEN" >> "$DB_FILE"

cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash

DB_FILE="/home/myip_db.txt"

while IFS="|" read -r DDNS ACCOUNT_ID LIST_ID API_TOKEN; do

  [[ -z "$DDNS" ]] && continue

  # 再次清洗变量，确保绝对无空格隐患
  DDNS=$(echo "$DDNS" | xargs)

  # =========================
  # 获取域名的 IP 地址（强制使用阿里公共DNS解析防止本地缓存）
  # =========================
  IPV4=$(dig @223.5.5.5 +short A "$DDNS" | grep -E '^[0-9.]+$' | head -n1)
  IPV6=$(dig @223.5.5.5 +short AAAA "$DDNS" | grep -E '^[0-9a-fA-F:]+$' | head -n1)

  [[ -z "$IPV4" && -z "$IPV6" ]] && continue

  # =========================
  # 获取 Cloudflare 列表项（强行拉取 100 条打破默认 25 条分页限制）
  # =========================
  RESP=$(curl -s \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/rules/lists/${LIST_ID}/items?per_page=100" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json")

  # =========================
  # 精确提取并删除旧记录（使用 jq 模糊包含筛选）
  # =========================
  # 只要注释中包含你的 DDNS 域名，全部揪出来删除，防止空格或不完全匹配导致漏删
  MATCH_IDS=$(echo "$RESP" | jq -r ".result[]? | select(.comment != null and (.comment | contains(\"$DDNS\"))) | .id" 2>/dev/null)

  if [[ -n "$MATCH_IDS" ]]; then
    for id in $MATCH_IDS; do
      if [[ -n "$id" && "$id" != "null" ]]; then
        curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/rules/lists/${LIST_ID}/items/$id" \
        -H "Authorization: Bearer ${API_TOKEN}" >/dev/null
        sleep 0.3 # 稍作停顿，防止 Cloudflare API 频率限制冲突
      fi
    done
  fi

  # =========================
  # 写入新 IPv4
  # =========================
  [[ -n "$IPV4" ]] && curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/rules/lists/${LIST_ID}/items" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "[{\"ip\":\"$IPV4\",\"comment\":\"$DDNS\"}]" >/dev/null

  # =========================
  # 写入新 IPv6
  # =========================
  [[ -n "$IPV6" ]] && curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/rules/lists/${LIST_ID}/items" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "[{\"ip\":\"$IPV6\",\"comment\":\"$DDNS\"}]" >/dev/null

done < "$DB_FILE"
EOF

  chmod +x "$SCRIPT_PATH"

  (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "*/$MIN * * * * $SCRIPT_PATH >/dev/null 2>&1") | crontab -

  echo "✔ 安装完成"
  echo "✔ 分页限制、备注不匹配、空格干扰等问题已全部解决！"
}

# =========================
# 管理菜单
# =========================
manage() {
  while true; do
    clear
    echo "===== DDNS 管理 ====="
    echo "1) 添加域名"
    echo "2) 查看列表"
    echo "3) 删除域名"
    echo "0) 返回"

    read -p "选择: " c

    case $c in

      1)
        require_input DDNS "DDNS域名: "
        require_input ACCOUNT_ID "ACCOUNT_ID: "
        require_input LIST_ID "LIST_ID: "
        require_input API_TOKEN "API_TOKEN: "
        echo "$DDNS|$ACCOUNT_ID|$LIST_ID|$API_TOKEN" >> "$DB_FILE"
        echo "✔ 已添加"
        read -p "回车返回..."
        ;;

      2)
        clear
        echo "===== 当前域名 ====="
        if [[ -f "$DB_FILE" ]]; then
          i=1
          while IFS="|" read -r DDNS _ _ _; do
            [[ -z "$DDNS" ]] && continue
            echo "$i. $DDNS"
            ((i++))
          done < "$DB_FILE"
        else
          echo "暂无数据"
        fi
        read -p "回车返回..."
        ;;

      3)
        clear
        if [[ -f "$DB_FILE" ]]; then
          i=1
          while IFS="|" read -r DDNS _ _ _; do
            [[ -z "$DDNS" ]] && continue
            echo "$i. $DDNS"
            ((i++))
          done < "$DB_FILE"

          read -p "选择序号: " n
          if [[ -n "$n" ]]; then
            sed -i "${n}d" "$DB_FILE"
            echo "✔ 已删除"
          fi
        else
          echo "暂无数据"
        fi
        read -p "回车返回..."
        ;;

      0) break ;;
    esac
  done
}

# =========================
# 卸载
# =========================
uninstall() {
  rm -f /home/myip.sh
  rm -f /home/myip_db.txt
  crontab -l 2>/dev/null | grep -v "/home/myip.sh" | crontab -
  echo "✔ 已完全卸载"
}

# =========================
# 主菜单
# =========================
while true; do
  clear
  echo "======================"
  echo " Cloudflare DDNS"
  echo "======================"
  echo "1) 安装"
  echo "2) 管理"
  echo "3) 卸载"
  echo "0) 退出"

  read -p "选择: " c

  case $c in
    1) install ;;
    2) manage ;;
    3) uninstall ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
