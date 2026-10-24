#!/bin/bash

SCRIPT_PATH="/home/myip.sh"
DB_FILE="/home/myip_db.txt"

# 上次路径保存在管理脚本旁，不随数据路径移动，也不执行其中内容。
PATH_STATE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.myip-paths"
OLD_SCRIPT_PATH=""
OLD_DB_FILE=""

prepare_paths() {
  local db_literal line tmp replaced=0
  [[ "$SCRIPT_PATH" == /* && "$DB_FILE" == /* && "$SCRIPT_PATH" != "$DB_FILE" && "$SCRIPT_PATH" != "${BASH_SOURCE[0]}" ]] || {
    echo "❌ 运行脚本和配置须使用不同的绝对路径，且不能覆盖管理脚本" >&2; return 1;
  }
  # cron 对 % 有特殊含义，拒绝此类路径，避免生成不可执行任务。
  [[ "$SCRIPT_PATH$DB_FILE" != *$'\n'* && "$SCRIPT_PATH$DB_FILE" != *%* ]] || return 1
  if [[ -f "$PATH_STATE" ]]; then
    { IFS= read -r OLD_SCRIPT_PATH; IFS= read -r OLD_DB_FILE; } < "$PATH_STATE"
  fi
  mkdir -p -- "$(dirname -- "$SCRIPT_PATH")" "$(dirname -- "$DB_FILE")" || return 1
  if [[ -n "$OLD_DB_FILE" && "$OLD_DB_FILE" != "$DB_FILE" && -f "$OLD_DB_FILE" ]]; then
    if [[ -f "$DB_FILE" ]] && ! cmp -s -- "$OLD_DB_FILE" "$DB_FILE"; then
      echo "❌ 新路径已有不同配置，未覆盖；请先手动合并：$DB_FILE" >&2; return 1
    fi
    [[ -f "$DB_FILE" ]] || { cp -p -- "$OLD_DB_FILE" "$DB_FILE" && chmod 600 "$DB_FILE"; } || return 1
    if [[ ! -f "${DB_FILE}.cron_minutes" && -f "${OLD_DB_FILE}.cron_minutes" ]]; then
      cp -p -- "${OLD_DB_FILE}.cron_minutes" "${DB_FILE}.cron_minutes" || return 1
    fi
  fi
  if [[ -n "$OLD_SCRIPT_PATH" && "$OLD_SCRIPT_PATH" != "$SCRIPT_PATH" && -f "$OLD_SCRIPT_PATH" ]]; then
    if [[ -e "$SCRIPT_PATH" ]]; then
      echo "❌ 新运行路径已存在文件，未覆盖：$SCRIPT_PATH" >&2; return 1
    fi
    cp -p -- "$OLD_SCRIPT_PATH" "$SCRIPT_PATH" || return 1
  fi
  # 只替换运行脚本的配置路径，保留现有同步正文。
  if [[ -f "$SCRIPT_PATH" && -f "$DB_FILE" ]]; then
    printf -v db_literal 'DB_FILE=%q' "$DB_FILE"
    if ! grep -Fxq -- "$db_literal" "$SCRIPT_PATH"; then
      tmp=$(mktemp "${SCRIPT_PATH}.path.XXXXXX") || return 1
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == DB_FILE=* && "$replaced" == 0 ]]; then
          printf '%s\n' "$db_literal"; replaced=1
        else printf '%s\n' "$line"; fi
      done < "$SCRIPT_PATH" > "$tmp"
      if [[ "$replaced" == 0 ]] || ! bash -n "$tmp"; then rm -f -- "$tmp"; return 1; fi
      chmod --reference="$SCRIPT_PATH" "$tmp"
      mv -- "$tmp" "$SCRIPT_PATH" || return 1
    fi
  fi
}

# =========================
# 本项目独立定时任务块（不触碰其他项目任务）
# =========================
sync_cron() {
  local mode=${1:-repair} current cleaned updated line minute schedule quoted_path saved
  command -v crontab >/dev/null 2>&1 || { echo "❌ 未找到 crontab" >&2; return 1; }
  current=$(crontab -l 2>/dev/null)
  printf -v quoted_path '%q' "$SCRIPT_PATH"
  # 只匹配本脚本的执行命令，不使用路径模糊过滤。
  cleaned=$(printf '%s\n' "$current" | awk -v path="$SCRIPT_PATH" -v quoted="$quoted_path" -v old="$OLD_SCRIPT_PATH" '
    $0 == "# IP白名单配置列表" { block=1; next }
    $0 == "# IP白名单配置列表 结束" { block=0; next }
    block { next }
    {
      command = $0
      for (i = 1; i <= 5; i++) sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", command)
      if (command == path " >/dev/null 2>&1" || command == quoted " >/dev/null 2>&1" || (old != "" && command == old " >/dev/null 2>&1")) next
      print
    }')
  if [[ "$mode" == remove ]]; then
    updated=$cleaned
  else
    # 未安装时不创建任务，避免定时运行不存在的文件。
    [[ -f "$SCRIPT_PATH" && -f "$DB_FILE" ]] || return 0
    saved="${DB_FILE}.cron_minutes"
    minute=${MIN:-}
    if [[ -z "$minute" && -f "$saved" ]]; then
      read -r minute < "$saved"
    fi
    if [[ -z "$minute" ]]; then
      while IFS= read -r line; do
        if [[ "$line" == *" $SCRIPT_PATH >/dev/null 2>&1" || "$line" == *" $quoted_path >/dev/null 2>&1" ]]; then
          if [[ "$line" =~ ^\*/([0-9]+)[[:space:]] ]]; then
            minute=${BASH_REMATCH[1]}
            break
          elif [[ "$line" == '0 * * * * '* ]]; then
            minute=60
            break
          fi
        fi
      done <<< "$current"
    fi
    [[ "$minute" =~ ^([2-9]|[1-5][0-9]|60)$ ]] || minute=5
    if [[ "$minute" == 60 ]]; then schedule='0 * * * *'; else schedule="*/$minute * * * *"; fi
    updated="${cleaned:+$cleaned$'\n'}# IP白名单配置列表
$schedule $quoted_path >/dev/null 2>&1
# IP白名单配置列表 结束"
    chmod +x "$SCRIPT_PATH" || return 1
    printf '%s\n' "$minute" > "$saved" || return 1
  fi
  if [[ "$updated" != "$current" ]]; then
    printf '%s\n' "$updated" | crontab - || { echo "❌ 定时任务修复失败" >&2; return 1; }
  fi
  if [[ "$mode" != remove ]]; then
    (umask 077; printf '%s\n%s\n' "$SCRIPT_PATH" "$DB_FILE" > "$PATH_STATE") || return 1
  fi
}

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

# 只在生成时展开路径；同步正文中的变量仍在定时运行时展开。
write_worker() {
  {
    printf '#!/bin/bash\n\nDB_FILE=%q\n' "$DB_FILE"
    cat <<'EOF'

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
  # 获取 Cloudflare 列表项（拉取 100 条打破默认分页限制）
  # =========================
  RESP=$(curl -s \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/rules/lists/${LIST_ID}/items?per_page=100" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "Content-Type: application/json")

  # =========================
  # 精确提取并批量删除旧记录（已修复修复）
  # =========================
  # 将匹配到的所有旧 ID 组装成符合 CF 官方规范的 {"items": [{"id": "xxx"}]} 结构
  DELETE_PAYLOAD=$(echo "$RESP" | jq -c "{items: [.result[]? | select(.comment != null and (.comment | contains(\"$DDNS\"))) | {id: .id}]}" 2>/dev/null)
  HAS_ITEMS=$(echo "$DELETE_PAYLOAD" | jq '.items | length' 2>/dev/null)

  if [[ "$HAS_ITEMS" -gt 0 ]]; then
    # 使用 Cloudflare 正确的批量删除端点（Body 传参）
    curl -s -X DELETE \
    "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/rules/lists/${LIST_ID}/items" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$DELETE_PAYLOAD" >/dev/null
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
  } > "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
}

# =========================
# 安装
# =========================
install() {
  prepare_paths || return 1
  install_deps
  echo "===== Cloudflare DNS（WAF IP白名单配置列表覆盖版）====="
  require_input DDNS "DNS域名（已DDNS的 IP 域名）: "
  require_input ACCOUNT_ID "ACCOUNT_ID（帐户ID 例如：a44ee7ef949....）: "
  require_input LIST_ID "LIST_ID（列表ID 例如：92a1eb84761e4ed8....）: "
  require_input API_TOKEN "API_TOKEN（密钥包含 帐户筛选器列表 读取与编辑 ）: "
  read -p "定时分钟(默认5,2-60): " MIN
  [[ "$MIN" =~ ^[0-9]+$ ]] || MIN=5
  MIN=$((10#$MIN))
  ((MIN<2)) && MIN=2
  ((MIN>60)) && MIN=60
  (umask 077; echo "$DDNS|$ACCOUNT_ID|$LIST_ID|$API_TOKEN" >> "$DB_FILE") || return 1
  write_worker || return 1
  sync_cron || return 1

  echo "✔ 安装完成"
  echo "✔ 批量覆盖删除逻辑已完全修复！历史堆积的 IP 会在下次执行时一次性清空。"
}

# =========================
# 管理菜单
# =========================
manage() {
  while true; do
    prepare_paths || return 1
    sync_cron
    clear
    echo "======================"
    echo " IP白名单配置列表 管理"
    show_configured_domains no_title
    echo "======================"
    echo "1. 添加域名"
    echo "2. 查看列表"
    echo "3. 删除域名"
    echo "0. 返回"
    echo "------------------------"
    read -p "选择: " c

    case $c in

      1)
        require_input DDNS "DNS域名（已DDNS的 IP 域名）: "
        require_input ACCOUNT_ID "ACCOUNT_ID（帐户ID 例如：a44ee7ef949....）: "
        require_input LIST_ID "LIST_ID（列表ID 例如：92a1eb84761e4ed8....）: "
        require_input API_TOKEN "API_TOKEN（密钥包含 帐户筛选器列表 读取与编辑 ）: "
        echo "$DDNS|$ACCOUNT_ID|$LIST_ID|$API_TOKEN" >> "$DB_FILE"
        sync_cron
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
        # 保留当前管理页面，在选项下方追加域名及删除提示。
        show_configured_domains no_title
        if [[ -f "$DB_FILE" ]]; then
          local -a domain_lines=()
          local row=0 domain rest n tmp
          while IFS='|' read -r domain rest || [[ -n "$domain" ]]; do
            ((row+=1))
            [[ -z "${domain//[[:space:]]/}" ]] && continue
            domain_lines+=("$row")
          done < "$DB_FILE"
          if ((${#domain_lines[@]} > 0)); then
            read -r -p "选择序号（ 0 取消）: " n
            [[ "$n" == 0 ]] && continue
            if [[ "$n" =~ ^[1-9][0-9]{0,8}$ ]] && ((n <= ${#domain_lines[@]})); then
              tmp=$(mktemp "${DB_FILE}.delete.XXXXXX") || continue
              if awk -v target="${domain_lines[n-1]}" 'NR != target' "$DB_FILE" > "$tmp" &&
                 chmod --reference="$DB_FILE" "$tmp" && mv -- "$tmp" "$DB_FILE"; then
                echo "✔ 已从本地配置中删除"
              else
                rm -f -- "$tmp"
                echo "❌ 删除失败"
              fi
            else
              echo "❌ 无效序号"
            fi
          fi
        fi
        read -r -p "回车返回..."
        ;;

      0) break ;;
    esac
  done
}

# =========================
# 卸载
# =========================
uninstall() {
  local confirm
  read -r -p "确认卸载并删除全部本地配置？请输入 yes 确认: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "已取消卸载"
    return 0
  fi

  sync_cron remove || return 1
  rm -f -- "$SCRIPT_PATH" "$DB_FILE" "${DB_FILE}.cron_minutes" "$PATH_STATE"
  OLD_SCRIPT_PATH=""; OLD_DB_FILE=""
  echo "✔ 已完全卸载"
}

# 主菜单只显示本地已配置域名，不展示账户信息或密钥。
show_configured_domains() {
  local domain rest count=0
  [[ "${1:-}" == no_title ]] || echo "IP白名单配置列表"
  if [[ -f "$DB_FILE" ]]; then
    while IFS='|' read -r domain rest || [[ -n "$domain" ]]; do
      [[ -z "${domain//[[:space:]]/}" ]] && continue
      ((count+=1))
      printf '%d. \033[36m%s\033[0m\n' "$count" "$domain"
    done < "$DB_FILE"
  fi
  if ((count == 0)); then
    printf '\033[31m暂无\033[0m\n'
  fi
}

# =========================
# 主菜单
# =========================
while true; do
  if prepare_paths; then sync_cron; else exit 1; fi
  clear
  echo "======================"
  echo " Cloudflare IP白名单配置列表"
  echo "======================"
  show_configured_domains
  echo "======================"
  echo "1. 安装"
  echo "2. 管理"
  echo "3. 卸载"
  echo "0. 退出"
  echo "------------------------"
  read -p "选择: " c

  case $c in
    1) install ;;
    2) manage ;;
    3) uninstall ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
