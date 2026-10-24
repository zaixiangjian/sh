#!/bin/bash

SCRIPT_PATH="/home/myip.sh"
DB_FILE="/home/myip_db.txt"
DEFAULT_MINUTES="5"             # IP 白名单自定义默认时间（2-60 分钟）

# DDNS 独立路径，可自定义；不影响上面的 IP 白名单功能。
DDNS_SCRIPT_PATH="/home/myip_ddns.sh"
DDNS_DB_FILE="/home/myip_ddns_db.txt"
DDNS_DEFAULT_MINUTES="2"        # DDNS 自定义默认时间（2-60 分钟）
DDNS_STATE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.myip-ddns-paths"

# 上次路径保存在管理脚本旁，不随数据路径移动，也不执行其中内容。
PATH_STATE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.myip-paths"
OLD_SCRIPT_PATH=""
OLD_DB_FILE=""

# 安装及管理修复调用顶部默认值，不覆盖已保存的间隔。
default_minutes() {
  local value=$1 fallback=$2
  [[ "$value" =~ ^([2-9]|[1-5][0-9]|60)$ ]] || value=$fallback
  printf '%s\n' "$value"
}

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
    [[ "$minute" =~ ^([2-9]|[1-5][0-9]|60)$ ]] || minute=$(default_minutes "$DEFAULT_MINUTES" 5)
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
  local default_min
  default_min=$(default_minutes "$DEFAULT_MINUTES" 5)
  read -p "定时分钟(默认${default_min},2-60): " MIN
  [[ "$MIN" =~ ^[0-9]+$ ]] || MIN=$default_min
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

# Bash-only DDNS add-on. Parent supplies DDNS_SCRIPT_PATH, DDNS_DB_FILE, DDNS_STATE.
ddns_error() { printf 'DDNS: %s\n' "$*" >&2; }
ddns_path_ok() { [[ $1 == /* && $1 != *[$'\n\r%']* && $1 != */ && ! -L $1 && ! -d $1 ]]; }
ddns_domain_ok() {
    local ddns_label; local -a ddns_labels
    [[ ${#1} -le 253 && $1 == *.* && $1 != *[$'\n\r|']* ]] || return 1
    IFS=. read -r -a ddns_labels <<< "$1"
    [[ $1 != *. ]] || return 1
    for ddns_label in "${ddns_labels[@]}"; do
        [[ ${#ddns_label} -le 63 && $ddns_label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
}
ddns_atomic() {
    local ddns_target=$1 ddns_mode=$2 ddns_tmp
    ddns_tmp=$(mktemp "${ddns_target}.tmp.XXXXXX") || return 1
    if cat > "$ddns_tmp" && chmod "$ddns_mode" "$ddns_tmp" && mv -f -- "$ddns_tmp" "$ddns_target"; then return 0; fi
    rm -f -- "$ddns_tmp"; return 1
}
ddns_prepare() {
    local ddns_old_script='' ddns_old_db='' ddns_p ddns_candidate='' ddns_line
    for ddns_p in "$DDNS_SCRIPT_PATH" "$DDNS_DB_FILE" "$DDNS_STATE"; do
        ddns_path_ok "$ddns_p" || { ddns_error '路径必须是安全的绝对文件路径'; return 1; }
        [[ $ddns_p != "$SCRIPT_PATH" && $ddns_p != "$DB_FILE" && $ddns_p != "$PATH_STATE" && $ddns_p != "$(readlink -f -- "${BASH_SOURCE[0]}")" ]] || { ddns_error 'DDNS 路径不能覆盖白名单文件或管理脚本'; return 1; }
    done
    [[ $DDNS_SCRIPT_PATH != "$DDNS_DB_FILE" && $DDNS_STATE != "$DDNS_DB_FILE" && $DDNS_STATE != "$DDNS_SCRIPT_PATH" ]] || return 1
    mkdir -p -- "$(dirname -- "$DDNS_SCRIPT_PATH")" "$(dirname -- "$DDNS_DB_FILE")" "$(dirname -- "$DDNS_STATE")" || return 1
    if [[ -f $DDNS_STATE ]]; then
        { IFS= read -r ddns_old_script; IFS= read -r ddns_old_db; } < "$DDNS_STATE"
        ddns_path_ok "$ddns_old_script" && ddns_path_ok "$ddns_old_db" && [[ $ddns_old_script != "$ddns_old_db" ]] || { ddns_error '路径状态无效'; return 1; }
        [[ $DDNS_SCRIPT_PATH != "$ddns_old_db" && $DDNS_DB_FILE != "$ddns_old_script" && $DDNS_STATE != "$ddns_old_db" && $DDNS_STATE != "$ddns_old_script" ]] || { ddns_error '新旧路径交叉冲突'; return 1; }
        if [[ $ddns_old_db != "$DDNS_DB_FILE" && -f $ddns_old_db && -e $DDNS_DB_FILE ]]; then
            cmp -s -- "$ddns_old_db" "$DDNS_DB_FILE" || { ddns_error '新数据库路径已有不同内容，拒绝覆盖'; return 1; }
        fi
        if [[ -f $ddns_old_script && ( $ddns_old_script != "$DDNS_SCRIPT_PATH" || $ddns_old_db != "$DDNS_DB_FILE" ) ]]; then
            ddns_candidate=$(mktemp "${DDNS_SCRIPT_PATH}.migrate.XXXXXX") || return 1
            while IFS= read -r ddns_line || [[ -n $ddns_line ]]; do
                if [[ $ddns_line == DDNS_DB_FILE=* ]]; then printf 'DDNS_DB_FILE=%q\n' "$DDNS_DB_FILE"; else printf '%s\n' "$ddns_line"; fi
            done < "$ddns_old_script" > "$ddns_candidate"
            if [[ -e $DDNS_SCRIPT_PATH && $DDNS_SCRIPT_PATH != "$ddns_old_script" ]] && ! cmp -s -- "$ddns_candidate" "$DDNS_SCRIPT_PATH"; then
                rm -f -- "$ddns_candidate"; ddns_error '新脚本路径已有不同内容，拒绝覆盖'; return 1
            fi
        fi
        if [[ $ddns_old_db != "$DDNS_DB_FILE" && -f $ddns_old_db && ! -e $DDNS_DB_FILE ]]; then
            ddns_atomic "$DDNS_DB_FILE" 600 < "$ddns_old_db" || { rm -f -- "${ddns_candidate:-/nonexistent}"; return 1; }
        fi
        if [[ $ddns_old_db != "$DDNS_DB_FILE" && -f "${ddns_old_db}.cron_minutes" && ! -e "${DDNS_DB_FILE}.cron_minutes" ]]; then
            ddns_atomic "${DDNS_DB_FILE}.cron_minutes" 600 < "${ddns_old_db}.cron_minutes" || return 1
        fi
        if [[ -n $ddns_candidate ]]; then
            ddns_atomic "$DDNS_SCRIPT_PATH" 700 < "$ddns_candidate"; local ddns_rc=$?
            rm -f -- "$ddns_candidate"; (( ddns_rc == 0 )) || return 1
        fi
    fi
    [[ ! -f $DDNS_DB_FILE ]] || chmod 600 -- "$DDNS_DB_FILE" || return 1
    if [[ -f $DDNS_SCRIPT_PATH && -f $DDNS_DB_FILE ]]; then
        printf '%s\n%s\n' "$DDNS_SCRIPT_PATH" "$DDNS_DB_FILE" | ddns_atomic "$DDNS_STATE" 600 || return 1
    fi
}
ddns_cron() {
    local ddns_minutes ddns_schedule
    ddns_minutes=$(default_minutes "$DDNS_DEFAULT_MINUTES" 2)
    if [[ -f "${DDNS_DB_FILE}.cron_minutes" ]]; then
        read -r ddns_minutes < "${DDNS_DB_FILE}.cron_minutes"
    fi
    [[ $ddns_minutes =~ ^([2-9]|[1-5][0-9]|60)$ ]] || ddns_minutes=$(default_minutes "$DDNS_DEFAULT_MINUTES" 2)
    if [[ $ddns_minutes == 60 ]]; then ddns_schedule='0 * * * *'; else ddns_schedule="*/$ddns_minutes * * * *"; fi
    local ddns_old ddns_new='' ddns_line ddns_inside=0 ddns_begin=0 ddns_end=0 ddns_cmd ddns_after ddns_tmp
    command -v crontab >/dev/null || { ddns_error '缺少 crontab'; return 1; }
    ddns_old=$(crontab -l 2>/dev/null); local ddns_rc=$?
    # crontab -l returns 1 for an empty table; other failures must not erase jobs.
    (( ddns_rc <= 1 )) || return 1
    while IFS= read -r ddns_line || [[ -n $ddns_line ]]; do
        if [[ $ddns_line == '# DDNS 本机 IP 到指定域名' ]]; then
            (( ddns_inside == 0 && ddns_begin == ddns_end )) || return 1
            ddns_inside=1; ddns_begin=$((ddns_begin+1)); continue
        fi
        if [[ $ddns_line == '# DDNS 本机 IP 到指定域名 结束' ]]; then
            (( ddns_inside == 1 )) || return 1
            ddns_inside=0; ddns_end=$((ddns_end+1)); continue
        fi
        (( ddns_inside )) || ddns_new+="$ddns_line"$'\n'
    done <<< "$ddns_old"
    (( ddns_inside == 0 )) || { ddns_error '定时任务标记不完整，未修改'; return 1; }
    [[ -n $ddns_old ]] || ddns_new=''
    if [[ ${1:-} != remove && -f $DDNS_SCRIPT_PATH && -f $DDNS_DB_FILE ]]; then
        # Cron uses /bin/sh: single-quote paths rather than Bash-only %q.
        ddns_cmd=${DDNS_SCRIPT_PATH//\'/\'\\\'\'}
        ddns_new+="# DDNS 本机 IP 到指定域名"$'\n'"$ddns_schedule /bin/bash '$ddns_cmd' >/dev/null 2>&1"$'\n'"# DDNS 本机 IP 到指定域名 结束"$'\n'
    fi
    ddns_tmp=$(mktemp "${DDNS_STATE}.cron.XXXXXX") || return 1
    printf '%s' "$ddns_new" > "$ddns_tmp"
    crontab "$ddns_tmp"; ddns_rc=$?; rm -f -- "$ddns_tmp"
    (( ddns_rc == 0 )) || return 1
    ddns_after=$(crontab -l 2>/dev/null) || return 1
    [[ $ddns_after == "$(printf '%s' "$ddns_new")" ]] || { ddns_error '定时任务回读不一致'; return 1; }
    if [[ ${1:-} != remove && -f $DDNS_SCRIPT_PATH && -f $DDNS_DB_FILE ]]; then
        printf '%s\n%s\n' "$DDNS_SCRIPT_PATH" "$DDNS_DB_FILE" | ddns_atomic "$DDNS_STATE" 600 || return 1
    fi
}
ddns_list() {
    local ddns_domain ddns_rest ddns_n=0
    if [[ -f $DDNS_DB_FILE ]]; then
        while IFS='|' read -r ddns_domain ddns_rest || [[ -n $ddns_domain ]]; do
            [[ -n $ddns_domain ]] || continue
            ddns_n=$((ddns_n+1)); printf '%s. \033[36m%s\033[0m\n' "$ddns_n" "$ddns_domain"
        done < "$DDNS_DB_FILE"
    fi
    (( ddns_n )) || printf '\033[31m暂无\033[0m\n'
}
ddns_api() {
    local ddns_method=$1 ddns_path=$2 ddns_body=${3:-} ddns_response
    [[ $ddns_token =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    ddns_response=$(printf 'header = "Authorization: Bearer %s"\n' "$ddns_token" |
        curl --config - --silent --show-error --fail --connect-timeout 10 --max-time 35 \
        --request "$ddns_method" --header 'Content-Type: application/json' \
        --data "$ddns_body" "https://api.cloudflare.com/client/v4$ddns_path" 2>/dev/null) || return 1
    jq -e '.success == true' >/dev/null 2>&1 <<< "$ddns_response" || return 1
    printf '%s\n' "$ddns_response"
}
ddns_records() {
    local ddns_zone=$1 ddns_name=$2 ddns_type=$3 ddns_page=1 ddns_pages ddns_response ddns_all='[]' ddns_part
    while :; do
        ddns_response=$(ddns_api GET "/zones/$ddns_zone/dns_records?name=$ddns_name&type=$ddns_type&per_page=100&page=$ddns_page") || return 1
        ddns_pages=$(jq -er '.result_info.total_pages | select(type == "number" and . >= 0 and . <= 1000 and . == floor)' <<< "$ddns_response") || return 1
        ddns_part=$(jq -ce --arg n "$ddns_name" --arg t "$ddns_type" '.result | select(type == "array") | map(select(.name == $n and .type == $t))' <<< "$ddns_response") || return 1
        ddns_all=$(jq -cn --argjson a "$ddns_all" --argjson b "$ddns_part" '$a+$b') || return 1
        (( ddns_page >= ddns_pages )) && break
        ddns_page=$((ddns_page+1))
    done
    printf '%s\n' "$ddns_all"
}
ddns_ip_ok() {
    local ddns_ip=${2,,} ddns_a ddns_b ddns_c ddns_d ddns_x ddns_colons; local -a ddns_groups
    if [[ $1 == A ]]; then
        [[ $ddns_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
        IFS=. read -r ddns_a ddns_b ddns_c ddns_d <<< "$ddns_ip"
        for ddns_x in "$ddns_a" "$ddns_b" "$ddns_c" "$ddns_d"; do (( 10#$ddns_x <= 255 )) || return 1; done
        ddns_a=$((10#$ddns_a)); ddns_b=$((10#$ddns_b)); ddns_c=$((10#$ddns_c))
        (( ddns_a > 0 && ddns_a < 224 && ddns_a != 10 && ddns_a != 127 && !(ddns_a == 100 && ddns_b >= 64 && ddns_b <= 127) && !(ddns_a == 169 && ddns_b == 254) && !(ddns_a == 172 && ddns_b >= 16 && ddns_b <= 31) && !(ddns_a == 192 && (ddns_b == 168 || ddns_b == 0 || (ddns_b == 2))) && !(ddns_a == 198 && (ddns_b == 18 || ddns_b == 19 || (ddns_b == 51 && ddns_c == 100))) && !(ddns_a == 203 && ddns_b == 0 && ddns_c == 113) ))
    else
        # Conservative public unicast only; reject embedded IPv4 and scoped addresses.
        [[ $ddns_ip =~ ^[23][0-9a-f:]+$ && $ddns_ip == *:* && $ddns_ip != *:::* && $ddns_ip != *::*::* && $ddns_ip != 2001:db8:* ]] || return 1
        [[ $ddns_ip != :* && ( $ddns_ip != *: || $ddns_ip == *:: ) ]] || return 1
        ddns_colons=${ddns_ip//[^:]}; IFS=: read -r -a ddns_groups <<< "$ddns_ip"
        for ddns_x in "${ddns_groups[@]}"; do [[ ${#ddns_x} -le 4 ]] || return 1; done
        if [[ $ddns_ip == *::* ]]; then (( ${#ddns_colons} <= 7 )); else (( ${#ddns_colons} == 7 )); fi
    fi
}
ddns_probe() {
    local ddns_family=$1 ddns_url ddns_ip ddns_flag=-4
    [[ $ddns_family != AAAA ]] || ddns_flag=-6
    for ddns_url in https://api64.ipify.org https://icanhazip.com; do
        ddns_ip=$(curl "$ddns_flag" --silent --fail --connect-timeout 5 --max-time 12 "$ddns_url" 2>/dev/null) || continue
        ddns_ip=${ddns_ip//$'\r'/}; ddns_ip=${ddns_ip//$'\n'/}
        if ddns_ip_ok "$ddns_family" "$ddns_ip"; then printf '%s\n' "${ddns_ip,,}"; return 0; fi
    done
    return 1
}
ddns_matches() {
    jq -e --arg id "$1" --arg n "$2" --arg t "$3" --arg ip "$4" \
        '.id == $id and .name == $n and .type == $t and (.content|ascii_downcase) == $ip and .proxied == false and .ttl == 1' >/dev/null 2>&1
}
ddns_sync_family() {
    local ddns_zone=$1 ddns_domain=$2 ddns_type=$3 ddns_ip=$4 ddns_rows ddns_id ddns_response ddns_body ddns_duplicate
    ddns_rows=$(ddns_records "$ddns_zone" "$ddns_domain" "$ddns_type") || return 1
    ddns_id=$(jq -r '.[0].id // empty' <<< "$ddns_rows")
    ddns_body=$(jq -cn --arg n "$ddns_domain" --arg t "$ddns_type" --arg ip "$ddns_ip" '{name:$n,type:$t,content:$ip,ttl:1,proxied:false}') || return 1
    if [[ -n $ddns_id ]]; then
        [[ $ddns_id =~ ^[a-fA-F0-9]{32}$ ]] || return 1
        ddns_api PATCH "/zones/$ddns_zone/dns_records/$ddns_id" "$ddns_body" >/dev/null || return 1
    else
        ddns_response=$(ddns_api POST "/zones/$ddns_zone/dns_records" "$ddns_body") || return 1
        ddns_id=$(jq -er '.result.id' <<< "$ddns_response") || return 1
        [[ $ddns_id =~ ^[a-fA-F0-9]{32}$ ]] || return 1
    fi
    ddns_response=$(ddns_api GET "/zones/$ddns_zone/dns_records/$ddns_id") || return 1
    jq -c '.result' <<< "$ddns_response" | ddns_matches "$ddns_id" "$ddns_domain" "$ddns_type" "$ddns_ip" || return 1
    while IFS= read -r ddns_duplicate; do
        [[ -n $ddns_duplicate && $ddns_duplicate != "$ddns_id" ]] || continue
        [[ $ddns_duplicate =~ ^[a-fA-F0-9]{32}$ ]] || return 1
        ddns_api DELETE "/zones/$ddns_zone/dns_records/$ddns_duplicate" >/dev/null || return 1
    done < <(jq -r '.[].id' <<< "$ddns_rows")
    ddns_rows=$(ddns_records "$ddns_zone" "$ddns_domain" "$ddns_type") || return 1
    [[ $(jq 'length' <<< "$ddns_rows") == 1 ]] || return 1
    jq -c '.[0]' <<< "$ddns_rows" | ddns_matches "$ddns_id" "$ddns_domain" "$ddns_type" "$ddns_ip"
}
ddns_run() {
    local ddns_cmd ddns_v4='' ddns_v6='' ddns_domain ddns_zone ddns_token ddns_extra ddns_rc=0 ddns_cnames
    for ddns_cmd in curl jq flock; do command -v "$ddns_cmd" >/dev/null || { ddns_error "缺少 $ddns_cmd"; return 1; }; done
    exec 9< "$0" || return 1
    flock -n 9 || return 0
    [[ -f $DDNS_DB_FILE ]] || return 0
    ddns_v4=$(ddns_probe A) || ddns_error 'IPv4 探测失败，保留原记录'
    ddns_v6=$(ddns_probe AAAA) || ddns_error 'IPv6 探测失败，保留原记录'
    while IFS='|' read -r ddns_domain ddns_zone ddns_token ddns_extra || [[ -n $ddns_domain ]]; do
        [[ -n $ddns_domain ]] || continue
        if ! ddns_domain_ok "$ddns_domain" || [[ ! $ddns_zone =~ ^[a-fA-F0-9]{32}$ || ! $ddns_token =~ ^[A-Za-z0-9_-]+$ || -n $ddns_extra ]]; then ddns_error '配置行无效'; ddns_rc=1; continue; fi
        ddns_cnames=$(ddns_records "$ddns_zone" "$ddns_domain" CNAME) || { ddns_error "$ddns_domain 查询失败"; ddns_rc=1; continue; }
        [[ $(jq 'length' <<< "$ddns_cnames") == 0 ]] || { ddns_error "$ddns_domain 存在 CNAME，跳过"; ddns_rc=1; continue; }
        if [[ -n $ddns_v4 ]]; then ddns_sync_family "$ddns_zone" "$ddns_domain" A "$ddns_v4" || { ddns_error "$ddns_domain A 同步失败"; ddns_rc=1; }; fi
        if [[ -n $ddns_v6 ]]; then ddns_sync_family "$ddns_zone" "$ddns_domain" AAAA "$ddns_v6" || { ddns_error "$ddns_domain AAAA 同步失败"; ddns_rc=1; }; fi
    done < "$DDNS_DB_FILE"
    return "$ddns_rc"
}
ddns_write_worker() {
    {
        printf '#!/usr/bin/env bash\nDDNS_DB_FILE=%q\n' "$DDNS_DB_FILE"
        declare -f ddns_error ddns_domain_ok ddns_api ddns_records ddns_ip_ok ddns_probe ddns_matches ddns_sync_family ddns_run
        printf '\nddns_run\n'
    } | ddns_atomic "$DDNS_SCRIPT_PATH" 700
}
ddns_install() {
    local ddns_minutes ddns_default_min
    ddns_default_min=$(default_minutes "$DDNS_DEFAULT_MINUTES" 2)
    local CFRECORD_NAME CFKEY ddns_token ddns_suffix ddns_response ddns_zone='' ddns_cnames ddns_tmp ddns_domain ddns_rest
    ddns_prepare || return 1
    install_deps || return 1
    command -v flock >/dev/null || { ddns_error '缺少 flock（util-linux）'; return 1; }
    read -r -p 'CFRECORD_NAME（完整域名）: ' CFRECORD_NAME || return 1
    read -r -s -p 'CFKEY（API Token，Zone Read / DNS Edit）: ' CFKEY || return 1
    printf '\n'; CFRECORD_NAME=${CFRECORD_NAME,,}; ddns_token=$CFKEY
    while true; do
        read -r -p "定时分钟(默认${ddns_default_min},2-60): " ddns_minutes || return 1
        ddns_minutes=${ddns_minutes:-$ddns_default_min}
        [[ $ddns_minutes =~ ^([2-9]|[1-5][0-9]|60)$ ]] && break
        ddns_error '请输入 2-60 的整数'
    done
    ddns_domain_ok "$CFRECORD_NAME" && [[ $ddns_token =~ ^[A-Za-z0-9_-]+$ ]] || { ddns_error '域名或 Token 格式无效'; return 1; }
    ddns_suffix=$CFRECORD_NAME
    while [[ $ddns_suffix == *.* ]]; do
        ddns_response=$(ddns_api GET "/zones?name=$ddns_suffix&per_page=50") || { ddns_error 'Zone 查询失败，请检查 Token 权限'; return 1; }
        ddns_zone=$(jq -r --arg n "$ddns_suffix" '[.result[] | select(.name == $n and (.account.id | type == "string" and length > 0))] | if length == 1 then .[0].id else empty end' <<< "$ddns_response") || return 1
        if [[ -n $ddns_zone ]]; then break; fi
        ddns_suffix=${ddns_suffix#*.}
    done
    [[ $ddns_zone =~ ^[a-fA-F0-9]{32}$ ]] || { ddns_error '找不到可见 Zone，请授予 Zone Read / DNS Edit'; return 1; }
    ddns_cnames=$(ddns_records "$ddns_zone" "$CFRECORD_NAME" CNAME) || { ddns_error 'DNS 读取失败'; return 1; }
    [[ $(jq 'length' <<< "$ddns_cnames") == 0 ]] || { ddns_error '同名 CNAME 不可用于 DDNS'; return 1; }
    ddns_tmp=$(mktemp "${DDNS_DB_FILE}.add.XXXXXX") || return 1
    if [[ -f $DDNS_DB_FILE ]]; then
        while IFS='|' read -r ddns_domain ddns_rest || [[ -n $ddns_domain ]]; do
            [[ -z $ddns_domain || $ddns_domain == "$CFRECORD_NAME" ]] || printf '%s|%s\n' "$ddns_domain" "$ddns_rest"
        done < "$DDNS_DB_FILE" > "$ddns_tmp"
    fi
    printf '%s|%s|%s\n' "$CFRECORD_NAME" "$ddns_zone" "$CFKEY" >> "$ddns_tmp"
    ddns_atomic "$DDNS_DB_FILE" 600 < "$ddns_tmp"; local ddns_rc=$?; rm -f -- "$ddns_tmp"
    (( ddns_rc == 0 )) || return 1
    printf '%s\n' "$ddns_minutes" | ddns_atomic "${DDNS_DB_FILE}.cron_minutes" 600 || return 1
    ddns_write_worker && ddns_cron || return 1
    printf 'DDNS 已配置：%s（每 %s 分钟，未立即修改 DNS）\n' "$CFRECORD_NAME" "$ddns_minutes"
}
ddns_manage() {
    local ddns_choice ddns_selected ddns_domain ddns_rest ddns_row ddns_tmp
    local -a ddns_lines
    while true; do
        ddns_prepare || return 1
        if [[ -f $DDNS_DB_FILE && -f $DDNS_SCRIPT_PATH ]]; then ddns_cron || return 1; fi
        clear
        echo "======================"
        echo "DDNS 本机 IP 到指定域名"
        ddns_list
        echo "======================"
        echo "1. 添加域名"
        echo "2. 查看列表"
        echo "3. 删除域名"
        echo "0. 返回"
        echo "------------------------"
        read -r -p "选择: " ddns_choice || return 0
        case $ddns_choice in
            1) ddns_install; read -r -p "回车返回..." || return 0 ;;
            2) ddns_list; read -r -p "回车返回..." || return 0 ;;
            3)
                ddns_list
                ddns_lines=(); ddns_row=0
                if [[ -f $DDNS_DB_FILE ]]; then
                    while IFS='|' read -r ddns_domain ddns_rest || [[ -n $ddns_domain ]]; do
                        ((ddns_row+=1))
                        [[ -n $ddns_domain ]] && ddns_lines+=("$ddns_row")
                    done < "$DDNS_DB_FILE"
                fi
                ((${#ddns_lines[@]})) || { read -r -p "回车返回..." || return 0; continue; }
                read -r -p "选择序号（ 0 取消）: " ddns_selected || return 0
                [[ $ddns_selected == 0 ]] && continue
                if [[ $ddns_selected =~ ^[1-9][0-9]{0,8}$ ]] && ((ddns_selected <= ${#ddns_lines[@]})); then
                    ddns_tmp=$(mktemp "${DDNS_DB_FILE}.delete.XXXXXX") || return 1
                    if awk -v target="${ddns_lines[ddns_selected-1]}" 'NR != target' "$DDNS_DB_FILE" > "$ddns_tmp" &&
                       ddns_atomic "$DDNS_DB_FILE" 600 < "$ddns_tmp"; then
                        echo "✔ 已删除本地 DDNS 配置，云端 DNS 记录保留"
                    else
                        ddns_error "删除失败"
                    fi
                    rm -f -- "$ddns_tmp"
                else
                    ddns_error "无效序号"
                fi
                read -r -p "回车返回..." || return 0
                ;;
            0) return 0 ;;
            *) ddns_error "无效选项" ;;
        esac
    done
}
ddns_uninstall() {
    local ddns_answer
    read -r -p '仅卸载 DDNS 本地配置，不删除云端 DNS。输入 yes 确认: ' ddns_answer || return 1
    [[ $ddns_answer == yes ]] || return 0
    ddns_prepare && ddns_cron remove || return 1
    rm -f -- "$DDNS_SCRIPT_PATH" "$DDNS_DB_FILE" "${DDNS_DB_FILE}.cron_minutes" "$DDNS_STATE"
}

# =========================
# 主菜单
# =========================
while true; do
  if prepare_paths; then sync_cron; else exit 1; fi
  if ddns_prepare; then
    if [[ -f "$DDNS_DB_FILE" || -f "$DDNS_SCRIPT_PATH" ]]; then ddns_cron; fi
  fi
  clear
  echo "======================"
  echo " Cloudflare IP白名单配置列表"
  echo "======================"
  show_configured_domains
  echo "======================"
  echo "DDNS 本机 IP 到指定域名"
  ddns_list
  echo "======================"
  echo "1. 安装"
  echo "2. 管理"
  echo "3. 卸载"
  echo "======================"
  echo "11. DDNS 公网 IP"
  echo "12. 管理"
  echo "13. 卸载"
  echo "======================"
  echo "0. 退出"
  echo "------------------------"
  read -p "选择: " c

  case $c in
    1) install ;;
    2) manage ;;
    3) uninstall ;;
    11) ddns_install; read -r -p "回车返回..." ;;
    12) ddns_manage ;;
    13) ddns_uninstall; read -r -p "回车返回..." ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
  esac
done
