#!/usr/bin/env bash
native_archive_publish() {
    python3 - "$1" "$2" <<'PY_NATIVE_PUBLISH'
import os,sys,gzip,tarfile
partial,final=sys.argv[1:]
with gzip.open(partial,'rb') as f:
    while f.read(1024*1024):pass
with tarfile.open(partial,'r:gz') as t:t.getmembers()
os.chmod(partial,0o600)
with open(partial,'rb') as f:os.fsync(f.fileno())
os.link(partial,final,follow_symlinks=False)
os.unlink(partial)
fd=os.open(os.path.dirname(final),os.O_RDONLY|os.O_DIRECTORY)
try:os.fsync(fd)
finally:os.close(fd)
PY_NATIVE_PUBLISH
}
native_archive_reserve() {
    (umask 077; set -o noclobber; : > "$1") || { echo '临时归档已存在或无法创建，未覆盖。' >&2; return 1; }
}

# 二进制哪吒 v0 备份管理；从 kejilion.sh 999/1000 导出。
umask 077
install() {
    local item
    local -a packages=()
    for item in "$@"; do command -v "$item" >/dev/null 2>&1 || packages+=("$item"); done
    [ "${#packages[@]}" -gt 0 ] || return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "${packages[@]}"
    elif command -v yum >/dev/null 2>&1; then yum install -y "${packages[@]}"
    else echo "请先安装：${packages[*]}"; return 1; fi
}
check_crontab_installed() {
    command -v crontab >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y cron || return 1
        systemctl enable --now cron || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y cronie && systemctl enable --now crond || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y cronie && systemctl enable --now crond || return 1
    else echo '请先安装并启动 cron'; return 1; fi
    command -v crontab >/dev/null 2>&1
}

# ===== 哪吒远程定时备份配置（11 -> 5 -> 1000） 开始 =====
NEZHAV0_BACKUP_DIR="/home/备份/nezhav0"
NEZHAV0_BACKUP_PREFIX="nezha"
nezha_remote_backup_base_dir="$NEZHAV0_BACKUP_DIR/config"
nezha_remote_backup_job_dir="$nezha_remote_backup_base_dir/jobs"
nezha_remote_backup_state_dir="$nezha_remote_backup_base_dir/state"

nezha_remote_backup_safe_name() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]
}

nezha_remote_backup_config_path() {
    echo "$nezha_remote_backup_job_dir/$1.conf"
}

nezha_remote_backup_script_path() {
    echo "$nezha_remote_backup_job_dir/$1.sh"
}

nezha_remote_backup_ensure_dirs() {
    mkdir -p "$nezha_remote_backup_job_dir" "$nezha_remote_backup_state_dir"
    # 保留式兼容旧位置，不覆盖新目录已有配置。
    if [ -d /home/nezha/remote_backup/jobs ]; then
        cp -an /home/nezha/remote_backup/jobs/. "$nezha_remote_backup_job_dir"/ 2>/dev/null || true
    fi
    if [ -d /home/nezha/remote_backup/state ]; then
        cp -an /home/nezha/remote_backup/state/. "$nezha_remote_backup_state_dir"/ 2>/dev/null || true
    fi
    if [ -d /root/.config/nezha_remote_backup/jobs ]; then
        cp -an /root/.config/nezha_remote_backup/jobs/. "$nezha_remote_backup_job_dir"/ 2>/dev/null || true
    fi
    if [ -d /root/.config/nezha_remote_backup/state ]; then
        cp -an /root/.config/nezha_remote_backup/state/. "$nezha_remote_backup_state_dir"/ 2>/dev/null || true
    fi
    chmod 700 "$nezha_remote_backup_base_dir" "$nezha_remote_backup_job_dir" "$nezha_remote_backup_state_dir" 2>/dev/null || true
}

nezha_remote_backup_write_runner() {
    local name="$1"
    local script_file
    script_file="$(nezha_remote_backup_script_path "$name")"
    cat > "$script_file" <<'EOF'
#!/bin/bash
set -euo pipefail

CONFIG_FILE="__CONFIG_FILE__"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ 配置文件不存在: $CONFIG_FILE"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

BACKUP_DIR="__NEZHA_BACKUP_DIR__"
STATE_DIR="__NEZHA_STATE_DIR__"
LOG_PREFIX="[$(date '+%F %T')] [$JOB_NAME]"
mkdir -p "$BACKUP_DIR" "$STATE_DIR"
STATE_FILE="$STATE_DIR/${JOB_NAME}.last_success"

interval_seconds=$((INTERVAL_DAYS * 86400))
now_ts=$(date +%s)
if [ "${FORCE_RUN:-0}" != "1" ] && [ -f "$STATE_FILE" ]; then
    last_ts=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
    if [ "$last_ts" -gt 0 ] && [ $((now_ts - last_ts)) -lt "$interval_seconds" ]; then
        next_ts=$((last_ts + interval_seconds))
        echo "$LOG_PREFIX 距离上次成功备份不足 ${INTERVAL_DAYS} 天，跳过。本次应在 $(date -d "@$next_ts" '+%F %T' 2>/dev/null || date -r "$next_ts" '+%F %T' 2>/dev/null || echo "$next_ts") 后运行。"
        exit 0
    fi
fi

start_nezha() {
    echo "[$(date '+%F %T')] [$JOB_NAME] 🚀 正在启动哪吒服务..."
    systemctl start nezha-dashboard 2>/dev/null || {
        if [ -x /opt/nezha/dashboard/app ]; then
            cd /opt/nezha/dashboard
            nohup ./app > /dev/null 2>&1 &
        fi
    }
}

stopped=0
cleanup() {
    if [ "$stopped" = "1" ]; then
        start_nezha || true
    fi
}
trap cleanup EXIT

echo "$LOG_PREFIX 🛑 正在停止哪吒服务..."
systemctl stop nezha-dashboard 2>/dev/null || true
pkill app 2>/dev/null || true
stopped=1

echo "[$(date '+%F %T')] [$JOB_NAME] ⏳ 等待数据落盘..."
sleep 3

if [ ! -f /opt/nezha/dashboard/data/sqlite.db ]; then
    echo "[$(date '+%F %T')] [$JOB_NAME] ❌ 数据库不存在，备份终止"
    exit 1
fi

DATE_STR=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/nezha-${DATE_STR}.tar.gz"

echo "[$(date '+%F %T')] [$JOB_NAME] 📦 开始打包备份..."
tar czf "$BACKUP_FILE" \
    /opt/nezha/dashboard/data \
    /opt/nezha/dashboard/app \
    /opt/nezha/dashboard/resource


echo "[$(date '+%F %T')] [$JOB_NAME] 📤 正在上传到远程服务器 ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR} ..."
SSH_OPTS=(-p "$REMOTE_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
if [ "$AUTH_TYPE" = "key" ]; then
    if [ ! -f "$SSH_KEY" ]; then
        echo "[$(date '+%F %T')] [$JOB_NAME] ❌ 密钥文件不存在: $SSH_KEY"
        exit 1
    fi
    SSH_CMD=(ssh -i "$SSH_KEY" "${SSH_OPTS[@]}")
    SCP_CMD=(scp -i "$SSH_KEY" -P "$REMOTE_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
else
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "[$(date '+%F %T')] [$JOB_NAME] ❌ sshpass 未安装，密码登录无法上传"
        exit 1
    fi
    export SSHPASS="$REMOTE_PASSWORD"
    SSH_CMD=(sshpass -e ssh "${SSH_OPTS[@]}")
    SCP_CMD=(sshpass -e scp -P "$REMOTE_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/root/.ssh/known_hosts)
fi

"${SSH_CMD[@]}" "$REMOTE_USER@$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'"
"${SCP_CMD[@]}" "$BACKUP_FILE" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"


echo "[$(date '+%F %T')] [$JOB_NAME] 🧹 清理本地旧备份，只保留最近 ${LOCAL_KEEP} 份..."
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'nezha-????????-??????.tar.gz' -printf '%T@ %p\n' | sort -nr | tail -n +$((LOCAL_KEEP + 1)) | cut -d ' ' -f2- | while IFS= read -r old; do rm -f -- "$old"; done

echo "[$(date '+%F %T')] [$JOB_NAME] 🧹 清理远程旧备份，只保留最近 ${REMOTE_KEEP} 份..."
"${SSH_CMD[@]}" "$REMOTE_USER@$REMOTE_HOST" "find '$REMOTE_DIR' -maxdepth 1 -type f -name 'nezha-????????-??????.tar.gz' -printf '%T@ %p\\n' | sort -nr | tail -n +$((REMOTE_KEEP + 1)) | cut -d ' ' -f2- | while IFS= read -r old; do rm -f -- \"\$old\"; done" || true

date +%s > "$STATE_FILE"
echo "[$(date '+%F %T')] [$JOB_NAME] ✅ 哪吒远程备份完成: $BACKUP_FILE"
EOF
    sed -i "s#__CONFIG_FILE__#$(nezha_remote_backup_config_path "$name")#g" "$script_file"
    sed -i "s#__NEZHA_BACKUP_DIR__#$NEZHAV0_BACKUP_DIR#g; s#__NEZHA_STATE_DIR__#$nezha_remote_backup_state_dir#g" "$script_file"
    chmod 700 "$script_file"
}

nezha_remote_backup_repair_cron() {
    local excluded="${1:-}" conf name
    nezha_remote_backup_ensure_dirs || return 1
    check_crontab_installed || return 1
    # Rebuild missing runner files using current paths; never execute them here.
    for conf in "$nezha_remote_backup_job_dir/"*.conf; do
        [ -f "$conf" ] && [ ! -L "$conf" ] || continue
        name=$(basename "$conf" .conf)
        nezha_remote_backup_safe_name "$name" || continue
        [ "$name" != "$excluded" ] || continue
        nezha_remote_backup_write_runner "$name" || return 1
    done
    python3 - "$nezha_remote_backup_job_dir" "$excluded" <<'PY_NEZHA_CRON'
import os,sys,pathlib,re,shlex,subprocess,fcntl
root=pathlib.Path(sys.argv[1]); excluded=sys.argv[2]
header='# 二进制 nezhav0 定时备份'; end='# /二进制 nezhav0 定时备份'
fd=os.open(root/'cron.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
with os.fdopen(fd,'w') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    jobs=[]; owned=set()
    for conf in sorted(root.glob('*.conf')):
        name=conf.stem
        if not re.fullmatch(r'[A-Za-z0-9_.-]+',name) or conf.is_symlink(): continue
        runner=root/(name+'.sh'); owned.add(str(runner))
        if name==excluded: continue
        # Read only generated scalar assignments; never execute credential configs.
        fields={}
        for line in conf.read_text().splitlines():
            m=re.fullmatch(r'(HOUR|MINUTE|INTERVAL_DAYS)=(\d+)',line)
            if m: fields[m[1]]=int(m[2])
        if not (0<=fields.get('HOUR',-1)<=23 and 0<=fields.get('MINUTE',-1)<=59 and fields.get('INTERVAL_DAYS',0)>=1):
            raise ValueError('配置时间无效，未改动cron：'+name)
        jobs.append(f"{fields['MINUTE']} {fields['HOUR']} * * * /bin/bash {shlex.quote(str(runner))}")
    current=subprocess.run(['crontab','-l'],capture_output=True,text=True)
    if current.returncode and 'no crontab' not in current.stderr.lower(): raise RuntimeError('无法读取现有crontab，未覆盖')
    rows=[]
    for line in current.stdout.splitlines():
        if line.strip() in (header,end): continue
        try: parts=shlex.split(line)
        except ValueError: parts=[]
        # Match only simple owned jobs; preserve unrelated commands/comments.
        command=parts[5:] if len(parts)>=6 and not line.lstrip().startswith('#') else []
        if len(command)==2 and command[0] in ('/bin/bash','bash'):
            p=pathlib.Path(command[1])
            if (p.parent==root or str(p.parent) in ('/home/nezha/remote_backup/jobs','/root/.config/nezha_remote_backup/jobs')) and re.fullmatch(r'[A-Za-z0-9_.-]+\.sh',p.name): continue
        rows.append(line)
    if jobs: rows += [header,*jobs,end]
    text='\n'.join(rows)+'\n' if rows else ''
    if text!=current.stdout:
        subprocess.run(['crontab','-'],input=text,text=True,check=True,capture_output=True)
    result=subprocess.run(['crontab','-l'],capture_output=True,text=True)
    if result.stdout!=text or (result.returncode and text): raise RuntimeError('cron写入后回读不一致')
PY_NEZHA_CRON
}

nezha_remote_backup_add_cron() {
    nezha_remote_backup_repair_cron
}

nezha_remote_backup_delete_cron() {
    nezha_remote_backup_repair_cron "$1"
}

nezha_remote_backup_list() {
    nezha_remote_backup_ensure_dirs
    echo "已配置的哪吒远程备份："
    echo "------------------------"
    local found=0 conf name cron_line
    for conf in "$nezha_remote_backup_job_dir"/*.conf; do
        [ -f "$conf" ] || continue
        found=1
        # shellcheck disable=SC1090
        source "$conf"
        name="$JOB_NAME"
        cron_line=$(crontab -l 2>/dev/null | grep -F "$(nezha_remote_backup_script_path "$name")" || true)
        echo "名称：$JOB_NAME"
        echo "远程：$REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT 目录：$REMOTE_DIR"
        echo "登录：$AUTH_TYPE"
        echo "周期：每 $INTERVAL_DAYS 天，$HOUR 点 $MINUTE 分检查运行"
        if [ -n "$cron_line" ]; then
            echo "定时：$cron_line"
        else
            echo "定时：未添加"
        fi
        echo "------------------------"
    done
    if [ "$found" = "0" ]; then
        echo "暂无配置"
        echo "------------------------"
    fi
}

nezha_remote_backup_add_config() {
    nezha_remote_backup_ensure_dirs
    local name remote_host remote_user remote_port remote_dir auth_type ssh_key remote_password interval_days hour minute local_keep remote_keep conf_file
    read -e -p "配置名称（英文/数字/点/横线/下划线，例如 hk1）: " name
    if ! nezha_remote_backup_safe_name "$name"; then
        echo "❌ 名称不合法，只能使用英文、数字、点、横线、下划线"
        return 1
    fi
    read -e -p "远程服务器IP/域名: " remote_host
    [ -n "$remote_host" ] || { echo "❌ 远程服务器不能为空"; return 1; }
    read -e -p "远程用户名 [root]: " remote_user
    remote_user=${remote_user:-root}
    read -e -p "SSH端口 [22]: " remote_port
    remote_port=${remote_port:-22}
    read -e -p "远程保存目录 [$NEZHAV0_BACKUP_DIR/]: " remote_dir
    remote_dir=${remote_dir:-$NEZHAV0_BACKUP_DIR/}
    echo "登录方式：1. 密钥登录  2. 密码登录"
    read -e -p "请选择 [1]: " auth_choice
    auth_choice=${auth_choice:-1}
    ssh_key=""
    remote_password=""
    case "$auth_choice" in
        1)
            auth_type="key"
            read -e -p "本机SSH私钥路径 [/root/.ssh/id_rsa]: " ssh_key
            ssh_key=${ssh_key:-/root/.ssh/id_rsa}
            if [ ! -f "$ssh_key" ]; then
                echo "⚠️ 密钥文件当前不存在：$ssh_key"
                echo "   请先配置免密，或改用密码登录。"
            fi
            ;;
        2)
            auth_type="password"
            read -s -p "远程服务器密码: " remote_password
            echo ""
            [ -n "$remote_password" ] || { echo "❌ 密码不能为空"; return 1; }
            install sshpass || return 1
            ;;
        *)
            echo "❌ 无效登录方式"
            return 1
            ;;
    esac
    read -e -p "每几天运行一次 [1]: " interval_days
    interval_days=${interval_days:-1}
    [[ "$interval_days" =~ ^[0-9]+$ ]] && [ "$interval_days" -ge 1 ] || { echo "❌ 天数必须是大于0的数字"; return 1; }
    read -e -p "几点运行，小时 0-23 [3]: " hour
    hour=${hour:-3}
    [[ "$hour" =~ ^[0-9]+$ ]] && [ "$hour" -ge 0 ] && [ "$hour" -le 23 ] || { echo "❌ 小时必须是0-23"; return 1; }
    read -e -p "几分运行，分钟 0-59 [0]: " minute
    minute=${minute:-0}
    [[ "$minute" =~ ^[0-9]+$ ]] && [ "$minute" -ge 0 ] && [ "$minute" -le 59 ] || { echo "❌ 分钟必须是0-59"; return 1; }
    read -e -p "本地保留几份备份 [7]: " local_keep
    local_keep=${local_keep:-7}
    read -e -p "远程保留几份备份 [14]: " remote_keep
    remote_keep=${remote_keep:-14}
    [[ "$local_keep" =~ ^[0-9]+$ ]] && [ "$local_keep" -ge 1 ] || local_keep=7
    [[ "$remote_keep" =~ ^[0-9]+$ ]] && [ "$remote_keep" -ge 1 ] || remote_keep=14

    conf_file="$(nezha_remote_backup_config_path "$name")"
    {
        printf 'JOB_NAME=%q\n' "$name"
        printf 'REMOTE_HOST=%q\n' "$remote_host"
        printf 'REMOTE_USER=%q\n' "$remote_user"
        printf 'REMOTE_PORT=%q\n' "$remote_port"
        printf 'REMOTE_DIR=%q\n' "$remote_dir"
        printf 'AUTH_TYPE=%q\n' "$auth_type"
        printf 'SSH_KEY=%q\n' "$ssh_key"
        printf 'REMOTE_PASSWORD=%q\n' "$remote_password"
        printf 'INTERVAL_DAYS=%q\n' "$interval_days"
        printf 'HOUR=%q\n' "$hour"
        printf 'MINUTE=%q\n' "$minute"
        printf 'LOCAL_KEEP=%q\n' "$local_keep"
        printf 'REMOTE_KEEP=%q\n' "$remote_keep"
    } > "$conf_file"
    chmod 600 "$conf_file"

    nezha_remote_backup_write_runner "$name"
    nezha_remote_backup_add_cron "$name" "$hour" "$minute"

    echo "✅ 配置已保存：$conf_file"
    echo "✅ 定时任务已添加：每 $interval_days 天，$hour 点 $minute 分运行检查"
    echo "✅ 执行脚本：$(nezha_remote_backup_script_path "$name")"
    echo "⚠️ 如果使用密码登录，密码会明文保存到本机配置文件（chmod 600），请保护 root 权限。"
    echo "📁 配置/脚本/日志目录：$nezha_remote_backup_base_dir"
}

nezha_remote_backup_delete_config() {
    nezha_remote_backup_ensure_dirs
    nezha_remote_backup_list
    local name conf_file script_file
    read -e -p "请输入要删除的配置名称，输入0返回: " name
    [ "$name" = "0" ] && return 0
    if ! nezha_remote_backup_safe_name "$name"; then
        echo "❌ 名称不合法"
        return 1
    fi
    conf_file="$(nezha_remote_backup_config_path "$name")"
    script_file="$(nezha_remote_backup_script_path "$name")"
    if [ ! -f "$conf_file" ]; then
        echo "❌ 未找到配置：$name"
        return 1
    fi
    read -e -p "确认删除配置 $name 并删除对应定时任务？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消"
        return 0
    fi
    nezha_remote_backup_delete_cron "$name" || return 1
    rm -f "$conf_file" "$script_file"
    echo "✅ 已删除配置和定时任务：$name"
}

nezha_remote_backup_run_now() {
    nezha_remote_backup_ensure_dirs
    nezha_remote_backup_list
    local name script_file
    read -e -p "请输入要立即执行的配置名称，输入0返回: " name
    [ "$name" = "0" ] && return 0
    if ! nezha_remote_backup_safe_name "$name"; then
        echo "❌ 名称不合法"
        return 1
    fi
    script_file="$(nezha_remote_backup_script_path "$name")"
    if [ ! -f "$script_file" ]; then
        echo "❌ 未找到执行脚本：$script_file"
        return 1
    fi
    echo "▶️ 开始执行"
    FORCE_RUN=1 /bin/bash "$script_file"
}


nezha_remote_backup_print_menu_summary() {
    nezha_remote_backup_ensure_dirs
    local found=0 conf name cron_line show_minute
    for conf in "$nezha_remote_backup_job_dir"/*.conf; do
        [ -f "$conf" ] || continue
        # shellcheck disable=SC1090
        source "$conf"
        name="$JOB_NAME"
        cron_line=$(crontab -l 2>/dev/null | grep -F "$(nezha_remote_backup_script_path "$name")" || true)
        [ -n "$cron_line" ] || continue
        if [ "$found" = "0" ]; then
            echo "如果有定时任务在这里显示"
            found=1
        fi
        show_minute="$MINUTE"
        if [[ "$show_minute" =~ ^[0-9]$ ]]; then
            show_minute="0$show_minute"
        fi
        echo "名称：$JOB_NAME  远程：$REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT"
        echo "每 $INTERVAL_DAYS 天，$HOUR 点 $show_minute 分运行"
        echo "crontab -e：$cron_line"
        echo "配置目录：$nezha_remote_backup_base_dir"
        echo "------------------------"
    done
}

nezha_remote_backup_menu() {
    while true; do
        clear
        echo "哪吒远程定时备份配置"
        echo "------------------------"
        echo "1. 添加/修改远程备份配置"
        echo "2. 查看配置和定时任务"
        echo "3. 删除远程配置并删除定时任务"
        echo "4. 立即执行某个远程备份配置"
        echo "------------------------"
        echo "0. 返回"
        echo "------------------------"
        read -e -p "请输入你的选择: " rb_choice
        case "$rb_choice" in
            1) nezha_remote_backup_add_config ;;
            2) nezha_remote_backup_list ;;
            3) nezha_remote_backup_delete_config ;;
            4) nezha_remote_backup_run_now ;;
            0) break ;;
            *) echo "无效选项" ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
    done
}

nezha_standalone_backup() {
        # 备份（生产级安全版）

        echo "🛑 正在优雅停止服务..."
        systemctl stop nezha-dashboard 2>/dev/null
        pkill app 2>/dev/null

        echo "⏳ 等待数据落盘..."
        sleep 3

        if [ ! -f /opt/nezha/dashboard/data/sqlite.db ]; then
          echo "❌ 数据库不存在，备份终止"
          sleep 2
          return 1
        fi

        mkdir -p "$NEZHAV0_BACKUP_DIR"
        nezha_backup_file="$NEZHAV0_BACKUP_DIR/${NEZHAV0_BACKUP_PREFIX}-$(date +%Y%m%d-%H%M%S).tar.gz"

        local partial="${nezha_backup_file}.partial"
        native_archive_reserve "$partial" || return 1
        echo "📦 开始备份..."

        tar czvf "$partial" \
          /opt/nezha/dashboard/data \
          /opt/nezha/dashboard/app \
          /opt/nezha/dashboard/resource

        local pack_rc=$?
        if [[ $pack_rc == 0 ]]; then native_archive_publish "$partial" "$nezha_backup_file" || pack_rc=$?; fi
        rm -f -- "$partial"
        if [ "$pack_rc" -eq 0 ]; then
          chmod 600 "$nezha_backup_file" || return 1
          AI_NEW_ARCHIVE="$nezha_backup_file"
          echo "✅ 备份成功: $nezha_backup_file"
        else
          echo "❌ 备份失败"
          return 1
        fi

        echo "🚀 正在重新启动哪吒服务..."
        systemctl start nezha-dashboard 2>/dev/null || {
          cd /opt/nezha/dashboard
          nohup ./app > /dev/null 2>&1 &
        }

        sleep 2
        if pgrep -f "/opt/nezha/dashboard/app" >/dev/null 2>&1 || systemctl is-active --quiet nezha-dashboard 2>/dev/null; then
          echo "✅ 哪吒服务已重新启动"
        else
          echo "⚠️ 哪吒服务可能未启动，请手动检查：systemctl status nezha-dashboard"
        fi

}

nezha_standalone_restore() (
    local selected archive work old i
    local -a files=()
    echo "备份查找目录：/home、$NEZHAV0_BACKUP_DIR"
    mapfile -t files < <(for i in /home "$NEZHAV0_BACKUP_DIR"; do
        [ -d "$i" ] || continue
        find "$i" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@\t%p\n'
    done | sort -nr | cut -f2-)
    [ "${#files[@]}" -gt 0 ] || { echo '未找到备份。'; return 1; }
    for i in "${!files[@]}"; do printf '  %s. %s\n' "$((i+1))" "${files[$i]}"; done
    read -r -p '回车恢复最新备份，输入序号选择，0返回：' selected
    selected=${selected:-1}
    [ "$selected" != 0 ] || return 0
    [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#files[@]}" ] || return 1
    archive=${files[$((selected-1))]}
    read -r -p "确认恢复 $archive 并启动？(y/N): " i
    [[ "$i" =~ ^[Yy]$ ]] || return 0
    command -v systemctl >/dev/null && [ -d /run/systemd/system ] || { echo '自动启动需要 systemd。'; return 1; }
    [ ! -L /opt ] && [ ! -L /opt/nezha ] && [ ! -L /opt/nezha/dashboard ] || { echo '拒绝符号链接部署路径。'; return 1; }
    mkdir -p "$NEZHAV0_BACKUP_DIR/config" || return 1
    work=$(mktemp -d "$NEZHAV0_BACKUP_DIR/config/.restore.XXXXXX") || return 1
    cp -- "$archive" "$work/archive.tar.gz" && mkdir "$work/stage" || return 1
    python3 - "$work/archive.tar.gz" "$work/stage" <<'PY_NEZHA_RESTORE'
import sys,tarfile,sqlite3,gzip,inspect
from pathlib import Path
archive,stage=sys.argv[1:];seen=set()
with tarfile.open(archive,'r:gz') as tar:
    for m in tar.getmembers():
        n=m.name
        while n.startswith('./'): n=n[2:]
        n=n.rstrip('/')
        if n!='opt/nezha/dashboard' and not n.startswith('opt/nezha/dashboard/'): raise ValueError('非法备份根目录')
        if '..' in n.split('/') or '\\' in n or n in seen or not(m.isfile() or m.isdir()): raise ValueError('非法路径、链接或特殊文件')
        seen.add(n)
    if 'filter' in inspect.signature(tar.extractall).parameters: tar.extractall(stage,filter='data')
    else: tar.extractall(stage)
with gzip.open(archive,'rb') as f:
    while f.read(1024*1024): pass
root=Path(stage)/'opt/nezha/dashboard'
for n in ['app','data/sqlite.db','data/config.yaml']:
    if not (root/n).is_file(): raise ValueError('备份缺少：'+n)
con=sqlite3.connect(str(root/'data/sqlite.db'))
try:
    if con.execute('pragma quick_check').fetchone()[0]!='ok': raise ValueError('数据库损坏')
finally: con.close()
print('✅ 备份校验通过。')
PY_NEZHA_RESTORE
    [ "$?" -eq 0 ] || { echo "校验失败，服务未修改；暂存：$work"; return 1; }
    systemctl stop nezha-dashboard.service 2>/dev/null || true
    python3 - <<'PY_NEZHA_STOP'
import os,signal,time
from pathlib import Path
pids=[]
for p in Path('/proc').iterdir():
    if not p.name.isdigit(): continue
    try:
        if os.readlink(p/'exe').removesuffix(' (deleted)')=='/opt/nezha/dashboard/app':
            os.kill(int(p.name),signal.SIGTERM);pids.append(int(p.name))
    except (FileNotFoundError,ProcessLookupError): pass
for _ in range(30):
    alive=[]
    for pid in pids:
        try:
            if os.readlink('/proc/'+str(pid)+'/exe').removesuffix(' (deleted)')=='/opt/nezha/dashboard/app': alive.append(pid)
        except (FileNotFoundError,ProcessLookupError): pass
    if not alive: break
    time.sleep(1)
else: raise SystemExit('旧面板进程未退出，中止恢复')
PY_NEZHA_STOP
    [ "$?" -eq 0 ] || return 1
    sync
    mkdir -p /opt/nezha || return 1
    old=$(mktemp -d "/opt/nezha/dashboard.before_restore.$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    rmdir "$old" || return 1
    if [ -e /opt/nezha/dashboard ]; then mv /opt/nezha/dashboard "$old" || return 1; fi
    if ! mv "$work/stage/opt/nezha/dashboard" /opt/nezha/dashboard; then
        [ ! -e /opt/nezha/dashboard ] && [ -d "$old" ] && mv "$old" /opt/nezha/dashboard
        echo '替换失败，已尝试回滚。'; return 1
    fi
    chmod 755 /opt/nezha/dashboard/app || return 1
    chmod 600 /opt/nezha/dashboard/data/sqlite.db /opt/nezha/dashboard/data/config.yaml || return 1
    if [ "$(systemctl show nezha-dashboard.service -p LoadState --value 2>/dev/null)" = not-found ]; then
        python3 - <<'PY_NEZHA_UNIT'
import os
text='[Unit]\nDescription=Nezha v0 dashboard\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=simple\nWorkingDirectory=/opt/nezha/dashboard\nExecStart=/opt/nezha/dashboard/app\nRestart=on-failure\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n'
fd=os.open('/etc/systemd/system/nezha-dashboard.service',os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o644)
with os.fdopen(fd,'w') as f:f.write(text)
PY_NEZHA_UNIT
        [ "$?" -eq 0 ] || return 1
    fi
    systemctl daemon-reload && systemctl enable nezha-dashboard.service && systemctl start nezha-dashboard.service || return 1
    sleep 5
    systemctl is-active --quiet nezha-dashboard.service || { echo "❌ 启动失败，旧数据保留：$old；请检查 journalctl -u nezha-dashboard.service -n 50"; return 1; }
    # Only discard this invocation's old data after the restored service is active.
    if [ -d "$old" ]; then
        case "$old" in
            /opt/nezha/dashboard.before_restore.*)
                [ ! -L "$old" ] && rm -rf -- "$old" || { echo "❌ 服务已启动，但本次旧数据清理失败：$old"; return 1; }
                ;;
            *) echo '❌ 旧数据暂存路径异常，拒绝清理。'; return 1 ;;
        esac
    fi
    rm -rf -- "$work" || return 1
    echo "✅ 恢复完成，哪吒服务已启动。"
)

# Reusable adaptation of CLIProxyAPI.sh original single-kind SSH/S3 engine.
# Parent supplies BACKUP_DIR BACKUP_PREFIX (including separator), REMOTE_DIR,
# LOCK_FILE RETENTION_FILE AI_APP_ID AI_APP_LABEL and ai_local_backup.
# Set AI_MANAGER_SCRIPT to the installed parent manager for systemd ExecStart.
# Source only defines functions; never installs timers or executes backups.
air_init() {
    [[ ${AI_APP_ID:-} == openclaw || ${AI_APP_ID:-} == hermes || ${AI_APP_ID:-} == nezhav0 ]] || return 1
    [[ -n ${AI_APP_LABEL:-} && ${BACKUP_DIR:-} == /* && -n ${BACKUP_PREFIX:-} && $BACKUP_PREFIX != */* ]] || return 1
    [[ ${REMOTE_DIR:-} == "$BACKUP_DIR/config" && ${LOCK_FILE:-} == "$BACKUP_DIR/backup.lock" && ${RETENTION_FILE:-} == "$REMOTE_DIR/local-retention.json" ]] || return 1
    declare -F ai_local_backup >/dev/null
}
air_error() { echo "错误：$*" >&2; }
air_locked() (
    umask 077
    mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || { air_error "应用备份操作正在执行。"; exit 1; }
    "$@"
)
air_ensure_environment() {
    local cmd
    for cmd in python3 flock; do command -v "$cmd" >/dev/null || { air_error "请先安装$cmd"; return 1; }; done
    if [[ ${1:-} == remote ]]; then
        if ! command -v rclone >/dev/null; then
            if command -v apt-get >/dev/null; then apt-get update && apt-get install -y rclone openssh-client || return 1
            else air_error "请先安装rclone和OpenSSH客户端。"; return 1; fi
        fi
    fi
}
air_remote_backup_app() (
    umask 077
    mkdir -p "$BACKUP_DIR" || exit 1
    AI_NEW_ARCHIVE=
    ai_local_backup >&2 || exit 1
    [[ -n ${AI_NEW_ARCHIVE:-} && -f $AI_NEW_ARCHIVE && ! -L $AI_NEW_ARCHIVE ]] || { air_error "本地备份未返回完整归档路径。"; exit 1; }
    python3 - "$AI_NEW_ARCHIVE" "$BACKUP_DIR" "$BACKUP_PREFIX" <<'PY'
import sys,pathlib,re,tarfile,gzip
p=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2])
if p.resolve().parent!=root.resolve() or not re.fullmatch(re.escape(sys.argv[3])+r'\d{8}-\d{6}\.tar\.gz',p.name): raise ValueError('新归档路径不属于当前应用')
with tarfile.open(p,'r:gz') as a: a.getmembers()
with gzip.open(p,'rb') as f:
    while f.read(1024*1024): pass
PY
    [[ $? == 0 ]] || exit 1
    if [[ -z ${AIR_EXACT_RESULT_FILE:-} ]]; then air_prune_local_backups >&2 || exit 1; fi
    if [[ -n ${AIR_EXACT_RESULT_FILE:-} ]]; then
        printf '%s\n' "$AI_NEW_ARCHIVE" > "$AIR_EXACT_RESULT_FILE" || exit 1
    else
        printf '%s\n' "$AI_NEW_ARCHIVE"
    fi
)
air_manual_remote_backup() { air_configure_local_retention && air_locked air_remote_backup_app; }
air_configure_local_retention() {
    local count
    while true; do
        IFS= read -r -p "本地备份保留数量（回车默认3）：" count || return 1
        count=${count:-3}
        if [[ $count =~ ^[1-9][0-9]{0,5}$ ]] && (( count <= 100000 )); then break; fi
        air_error "请输入1–100000的正整数。"
    done
    python3 - "$RETENTION_FILE" "$count" <<'PY'
import pathlib,os,json,sys
p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
fd=os.open(p,os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600)
with os.fdopen(fd,'w') as f: json.dump({'keep':int(sys.argv[2])},f)
os.chmod(p,0o600)
PY
}
air_prune_local_backups() {
    python3 - "$BACKUP_DIR" "$RETENTION_FILE" "$BACKUP_PREFIX" "${1:-}" <<'PY'
import pathlib,sys,json,re
root=pathlib.Path(sys.argv[1]); setting=pathlib.Path(sys.argv[2])
keep=int(sys.argv[4]) if len(sys.argv)>4 and sys.argv[4] else (json.loads(setting.read_text()).get('keep',3) if setting.exists() else 3)
if not isinstance(keep,int) or isinstance(keep,bool) or not 1<=keep<=100000: raise ValueError('本地保留数量无效，不执行删除')
files=sorted((p for p in root.iterdir() if re.fullmatch(re.escape(sys.argv[3])+r'\d{8}-\d{6}\.tar\.gz',p.name) and not p.is_symlink() and p.is_file()),key=lambda p:p.name.replace('-',''),reverse=True)
for p in files[keep:]: p.unlink()
print('本地保留最新'+str(keep)+'份备份。')
PY
}
# SSH/S3配置在应用数据之外；远端只清理本脚本命名的归档。
AI_LOG_MAX_BYTES=2097152
AI_LOG_BACKUPS=3
air_single_remote_engine() {
    python3 - "$REMOTE_DIR" "$BACKUP_DIR" "$BACKUP_PREFIX" "$AI_APP_ID" "$AI_APP_LABEL" "$@" 3<&0 <<'PY'
import os,sys,pathlib,json,re,subprocess,getpass,urllib.parse,tempfile,time,hashlib,tarfile
sys.stdin=os.fdopen(3)
root=pathlib.Path(sys.argv[1]); backups=pathlib.Path(sys.argv[2]); prefix=sys.argv[3]; app_id=sys.argv[4]; label=sys.argv[5]; mode=sys.argv[6]; kind=sys.argv[7]
owned_pattern=re.escape(prefix)+r"\d{8}-\d{6}\.tar\.gz"
if kind not in ('ssh-backup','ssh','s3'): raise ValueError('未知目标')
root.mkdir(parents=True,exist_ok=True,mode=0o700); os.chmod(root,0o700)
p=root/(kind+'.json'); conf=root/(kind+'.conf'); known=root/(kind+'-known-hosts')
def run(args,**kw):
    return subprocess.run(args,check=True,text=True,capture_output=True,timeout=900,**kw)
def ask(label,default=''):
    s=input(label+(' [默认 '+default+']' if default else '')+'：').strip(); return s or default
def valid(s):
    if not s or any(c in s for c in '\r\n\0'): raise ValueError('输入为空或含非法字符')
    return s
def save(path,text):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as f:f.write(text)
    os.chmod(path,0o600)
def load():
    if not p.is_file() or not conf.is_file(): raise ValueError('尚未配置，请先选择1')
    return json.loads(p.read_text())
def rc(args): return run(['rclone','--config',str(conf),'--contimeout','15s','--timeout','2m','--retries','2']+args)
try:
    if mode=='configure':
        if p.exists() and ask('已有配置，输入yes确认覆盖')!='yes': sys.exit(0)
        d={'kind':kind,'keep':7,'action':'backup' if kind=='ssh-backup' else 'transfer'}
        if kind=='ssh':
            while True:
                local_keep=ask('检查本地备份数量（回车默认3）','3')
                if local_keep.isdigit() and 1<=int(local_keep)<=100000:
                    d['local_keep']=int(local_keep); break
                print('请输入1–100000的整数。')
        if kind in ('ssh-backup','ssh'):
            while True:
                keep=ask('远程保留数量（回车默认 7 输入 0 不删除远程备份）','7')
                if keep.isdigit() and 0<=int(keep)<=100000:
                    d['keep']=int(keep); break
                print('请输入0–100000的整数，0表示不删除。')
        d['name']=valid(ask('任务备注名',{'ssh-backup':'SSH备份','ssh':'SSH传送','s3':'S3传送'}[kind]))
        if kind in ('ssh','ssh-backup'):
            host=valid(ask('SSH主机IP或域名')); user=valid(ask('SSH用户名','root')); port=ask('SSH端口','22')
            if not re.fullmatch(r'[A-Za-z0-9_.:-]+',host) or not re.fullmatch(r'[A-Za-z0-9_-]+',user) or not port.isdigit() or not 1<=int(port)<=65535: raise ValueError('主机/用户/端口无效')
            auth=ask('SSH认证方式：1私钥 / 2密码','1')
            if auth not in ('1','2'): raise ValueError('认证方式无效')
            key=None; password=None
            if auth=='1':
                key=pathlib.Path(valid(ask('SSH私钥文件','/root/.ssh/id_ed25519')))
                if not key.is_file(): raise ValueError('私钥不存在；定时任务需无交互可用的专用私钥')
            else:
                print('密码认证需在本机配置中保存可还原密码（权限600），不会进入备份包；rclone obscure不是强加密。')
                if ask('输入yes确认保存SSH密码')!='yes': sys.exit(0)
                password=valid(getpass.getpass('SSH密码（隐藏输入）：'))
            dest=valid(ask('远端专用备份目录',str(backups)))
            if not dest.startswith('/') or '..' in pathlib.PurePosixPath(dest).parts or dest=='/': raise ValueError('远端目录无效')
            print('将通过SFTP上传：'+dest+'；'+('不删除远程备份' if d['keep']==0 else '仅保留最新'+str(d['keep'])+'份当前前缀的远程归档'))
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = sftp\nhost = '+host+'\nuser = '+user+'\nport = '+port+'\nknown_hosts_file = \n'
            if auth=='1': text+='key_file = '+str(key)+'\n'
            else:
                # 密码经stdin传入obscure，不进入命令行参数或日志。
                obscured=run(['rclone','obscure','-'],input=password+'\n').stdout.strip()
                if not obscured or '\n' in obscured: raise ValueError('密码处理失败')
                text+='pass = '+obscured+'\n'
            d['auth']='key' if auth=='1' else 'password'
            d['dest']='remote:'+dest
        else:
            endpoint=valid(ask('S3 API Endpoint（非管理网页）'))
            u=urllib.parse.urlsplit(endpoint)
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('','/'): raise ValueError('Endpoint必须为HTTPS API地址，无用户名/路径/查询参数')
            bucket=valid(ask('存储桶名称（需提前创建）'))
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,62}',bucket): raise ValueError('桶名无效')
            prefix=valid(ask('桶内专用备份前缀','备份/'+app_id)).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(getpass.getpass('Access Key ID（隐藏输入）：')); secret=valid(getpass.getpass('Secret Access Key（隐藏输入）：'))
            while True:
                local_keep=ask('检查本地备份数量（回车默认3）','3')
                if local_keep.isdigit() and 1<=int(local_keep)<=100000:
                    d['local_keep']=int(local_keep); break
                print('请输入1–100000的整数。')
            while True:
                keep=ask('S3远程保留数量（回车默认 7 输入 0 不删除远程备份）','7')
                if keep.isdigit() and 0<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入0–100000的整数，0表示不删除。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份'+label+'时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+access+'\nsecret_access_key = '+secret+'\nendpoint = '+endpoint+'\nregion = '+region+'\nforce_path_style = true\nsign_accept_encoding = false\n'
        if d['action']=='backup':
            while True:
                interval=ask('备份间隔（1d/2d/3d/5d/7d/14d/30d）','7d')
                if interval in ('1d','2d','3d','5d','7d','14d','30d'): break
                print('请输入完整间隔，例如7d或14d。')
            d['interval']=interval
            hour=ask('每日备份北京时间小时（UTC+8）','5'); minute=ask('分钟','0')
            if not hour.isdigit() or not minute.isdigit() or not 0<=int(hour)<=23 or not 0<=int(minute)<=59: raise ValueError('时间无效')
            d['calendar']='*-*-* '+f'{int(hour):02}:{int(minute):02}:00 Asia/Shanghai'
            d['anchor_day']=int((time.time()+8*3600)//86400)
        else:
            d['calendar']='*:*:00/30'
            print('传送监控每30秒检查；仅发送最新完整归档，已成功发送的不重复上传。')
        # Validate SSH mkdir and readback using a temporary candidate config before replacing saved credentials.
        if kind in ('ssh','ssh-backup'):
            fd,candidate=tempfile.mkstemp(prefix=kind+'-candidate-',suffix='.conf',dir=root)
            os.close(fd)
            try:
                save(pathlib.Path(candidate),text)
                args=['rclone','--config',candidate,'--contimeout','15s','--timeout','2m','--retries','2']
                run(args+['mkdir',d['dest']])
                run(args+['lsjson',d['dest'],'--max-depth','1'])
            finally: os.unlink(candidate)
        save(conf,text); save(p,json.dumps(d,ensure_ascii=False))
        state=root/(kind+'-sent.json')
        if state.exists(): state.unlink()
        print('配置已保存，权限0600；凭据不进入备份包。')
    elif mode=='calendar': print(load()['calendar'])
    elif mode=='action': print(load().get('action','backup'))
    elif mode=='local-keep': print(load().get('local_keep',3))
    elif mode=='due':
        d=load(); interval=d.get('interval','7d')
        if d.get('action','backup')=='backup' and interval.endswith('d'):
            days=int(interval[:-1]); today=int((time.time()+8*3600)//86400)
            sys.exit(0 if (today-int(d.get('anchor_day',today)))%days==0 else 3)
        sys.exit(0)
    elif mode=='delete':
        owned_files=[p,conf,root/(kind+'-sent.json')]
        if kind in ('ssh','ssh-backup'): owned_files.append(known)
        for q in owned_files:
            if q.exists(): q.unlink()
        print('配置删除，远端和本地备份未删除。')
    elif mode=='test':
        d=load(); rc(['lsjson',d['dest'],'--max-depth','1']); print('远端目录读取测试通过（不代表写入权限已验证）')
    elif mode=='upload':
        d=load()
        explicit=sys.argv[8] if len(sys.argv)>8 else ''
        if explicit:
            f=pathlib.Path(explicit)
            if not f.is_file() or f.is_symlink() or f.resolve().parent!=backups.resolve() or not re.fullmatch(owned_pattern,f.name): raise ValueError('指定归档路径或名称无效')
        else:
            files=[x for x in backups.glob('*.tar.gz') if x.is_file() and not x.is_symlink()]
            if not files: print('暂无归档，等待新备份。'); sys.exit(0)
            f=max(files,key=lambda x:x.stat().st_mtime_ns)
        st=f.stat()
        if not explicit and time.time()-st.st_mtime<60: print('最新归档尚未稳定，稍后再传。'); sys.exit(0)
        state=root/(kind+'-sent.json')
        identity=[f.name,st.st_size,st.st_mtime_ns,st.st_ctime_ns,st.st_dev,st.st_ino]
        previous=json.loads(state.read_text()) if state.exists() else None
        if isinstance(previous,dict) and previous.get('version')==2 and previous.get('identity')==identity:
            print('最新归档已传送，跳过。'); sys.exit(0)
        with tarfile.open(f,'r:gz') as archive: archive.getmembers()
        import gzip
        with gzip.open(f,'rb') as stream:
            while stream.read(1024*1024): pass
        digest_hash=hashlib.sha256()
        with f.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''): digest_hash.update(chunk)
        digest=digest_hash.hexdigest()
        signature=[f.name,st.st_size,digest]
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity: raise ValueError('归档在校验中发生变化')
        record={'version':2,'identity':identity,'signature':signature}
        if previous==signature or (isinstance(previous,dict) and previous.get('signature')==signature):
            save(state,json.dumps(record))
            print('最新归档已传送，跳过。'); sys.exit(0)
        target=d['dest'].rstrip('/')+'/'+f.name
        if kind in ('ssh','ssh-backup'):
            rc(['mkdir',d['dest']]); rc(['lsjson',d['dest'],'--max-depth','1'])
        rc(['copyto',str(f),target,'--immutable','--ignore-existing','--s3-upload-cutoff','32Mi','--s3-chunk-size','8Mi'])
        info=json.loads(rc(['lsjson',target,'--stat']).stdout)
        if info.get('IsDir') or info.get('Size')!=f.stat().st_size: raise ValueError('上传后远端大小校验失败；未执行清理')
        # 按字节比较本次归档；成功后才允许远端保留清理。
        rc(['check',str(f.parent),d['dest'],'--include',f.name,'--one-way','--download'])
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化；未清理')
        if kind in ('s3','ssh-backup','ssh') and d.get('keep',0)!=0:
            listing=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(owned_pattern,x.get('Path',''))],key=lambda name:name.replace('-',''),reverse=True)
            keep=d.get('keep',7)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('远程保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化')
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity: raise ValueError('归档在传送中发生变化；未提交成功记录')
        save(state,json.dumps(record))
        retention='远端不删除' if d.get('keep',0)==0 else '远端保留最新'+str(d['keep'])+'份当前前缀归档'
        print('上传并校验成功：'+f.name+'；'+retention+'；本地数量由本地备份设置独立控制。')
    else: raise ValueError('未知操作')
except (EOFError,KeyboardInterrupt):
    print('已取消。'); sys.exit(1)
except subprocess.CalledProcessError as e:
    diagnostic=(e.stderr or '').lower()
    if 'known_hosts' in diagnostic or 'knownhosts' in diagnostic:
        reason='SSH主机校验配置不兼容，请重新保存远程配置。'
    elif 'unable to authenticate' in diagnostic or 'authentication failed' in diagnostic:
        reason='SSH认证失败，请核对用户名、密码或私钥及服务端权限。'
    elif 'connection refused' in diagnostic:
        reason='远端拒绝连接，请检查SSH端口及服务。'
    elif 'timeout' in diagnostic or 'timed out' in diagnostic:
        reason='连接超时，请检查网络、防火墙或地址。'
    elif 'permission denied' in diagnostic:
        reason='远端目录权限不足，无法创建或读取。'
    elif 'directory not found' in diagnostic or 'no such file' in diagnostic:
        reason='远程目录或本地私钥文件不存在。'
    else:
        reason='远端命令失败（退出码'+str(e.returncode)+'），请检查连接、权限与配置。'
    print('远程备份失败：'+reason,file=sys.stderr); sys.exit(1)
except Exception as e:
    # 不回显rclone原始输出、S3凭据或完整配置。
    print('远程备份失败：'+(str(e) if isinstance(e,ValueError) else type(e).__name__),file=sys.stderr); sys.exit(1)
PY
}

# 配置修改顺序：配置锁→对应任务锁，均非阻塞；不同应用路径独立。
air_single_configuration_locked() (
    local kind=$1
    shift
    umask 077
    mkdir -p "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { air_error "配置正在修改，请稍后重试。"; exit 1; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { air_error "该任务正在执行，未修改配置。"; exit 1; }
    "$@"
)
air_remote_schedule() { air_configuration_locked "$1" air_remote_schedule_unlocked "$@"; }
air_configure_remote_task() {
    air_remote_engine configure "$1" && air_remote_schedule_unlocked "$1" enable
}
air_delete_remote_task() {
    air_remote_schedule_unlocked "$1" remove && air_remote_engine delete "$1"
}
air_single_remote_schedule_unlocked() {
    local kind=$1 action=$2 calendar script unit="ai-${AI_APP_ID}-backup-$1"
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || return 1
    command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { air_error "定时备份需要systemd；配置可保留，仍可手动执行。"; return 1; }
    local owned_target
    for owned_target in "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"; do
        if [[ -e $owned_target ]] && [[ $(IFS= read -r line < "$owned_target"; printf '%s' "$line") != "# AI_APP_ID=$AI_APP_ID managed remote backup" ]]; then
            air_error "同名外部unit，拒绝修改：$owned_target"; return 1
        fi
    done
    if [[ $action == remove ]]; then
        systemctl disable --now "$unit.timer" || return 1
        # 不强行终止正在传送的service；删除配置前检查。
        systemctl is-active --quiet "$unit.service" && { air_error "任务正在运行，请完成后再删除配置。"; return 1; }
        rm -f "/etc/systemd/system/$unit.timer" "/etc/systemd/system/$unit.service"
        systemctl daemon-reload
        return
    fi
    calendar=$(air_remote_engine calendar "$kind") || return 1
    script=$(readlink -f "${AI_MANAGER_SCRIPT:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}") || return 1
    [[ $script =~ ^/[A-Za-z0-9_./-]+$ ]] || { air_error "定时运行的脚本路径不支持空格或特殊字符。"; return 1; }
    local target
    for target in "/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.timer"; do
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != "# AI_APP_ID=$AI_APP_ID managed remote backup" ]]; then air_error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" "$AI_APP_ID" "$AI_APP_LABEL" "${AIR_TASK_NAME:-}" <<'PY'
import sys,pathlib
unit,script,kind,calendar,app_id,label,task_name=sys.argv[1:]
base=pathlib.Path('/etc/systemd/system')
remote_args=('--remote-task '+task_name+' '+kind) if task_name else ('--remote '+kind)
service_content=('# AI_APP_ID='+app_id+' managed remote backup\n[Unit]\nDescription='+label+' remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' '+remote_args+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# AI_APP_ID='+app_id+' managed remote backup\n[Unit]\nDescription='+label+' daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
changed=False
for suffix,content in (('.service',service_content),('.timer',timer_content)):
    p=base/(unit+suffix)
    if not p.exists() or p.read_text()!=content:
        p.write_text(content); changed=True
print('yes' if changed else 'no')
PY
    ) || return 1
    if [[ $changed == yes ]]; then systemctl daemon-reload || return 1; fi
    if [[ $changed == yes ]] || ! systemctl is-active --quiet "$unit.timer" || ! systemctl is-enabled --quiet "$unit.timer"; then
        systemctl enable --now "$unit.timer" || return 1
        if [[ $changed == yes ]]; then systemctl restart "$unit.timer" || return 1; fi
    fi
    systemctl is-active --quiet "$unit.timer" || return 1
    systemctl cat "$unit.service" "$unit.timer" >/dev/null || return 1
    echo "定时已启用：$calendar；多天间隔按配置日期计算，脚本移动后请重新配置定时。"
}
air_backup_event_log() {
    python3 - "$REMOTE_DIR" "$AI_LOG_MAX_BYTES" "$AI_LOG_BACKUPS" "$1" "$2" <<'PY'
import pathlib,sys,logging,logging.handlers,fcntl,os
root=pathlib.Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True,mode=0o700)
with (root/'log.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    h=logging.handlers.RotatingFileHandler(root/'backup-transfer.log',maxBytes=int(sys.argv[2]),backupCount=int(sys.argv[3]),encoding='utf-8')
    h.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
    logger=logging.getLogger('ai-remote'); logger.setLevel(logging.INFO); logger.addHandler(h)
    logger.info('%s %s',sys.argv[4],sys.argv[5]); h.close()
    for p in root.glob('backup-transfer.log*'): os.chmod(p,0o600)
PY
}
air_remote_run() {
    local kind=$1
    [[ -f $REMOTE_DIR/$kind.json ]] || { air_error "尚未配置远端。"; return 1; }
    local action rc=0 result archive=""
    action=$(air_remote_engine action "$kind") || return 1
    if [[ $action == backup ]]; then
        air_backup_event_log "$kind" "本地备份开始" || return 1
        local AIR_EXACT_RESULT_FILE
        AIR_EXACT_RESULT_FILE=$(mktemp "$REMOTE_DIR/.producer-result.XXXXXX") || return 1
        chmod 600 "$AIR_EXACT_RESULT_FILE"
        if ! air_locked air_remote_backup_app; then
            rm -f "$AIR_EXACT_RESULT_FILE"
            air_backup_event_log "$kind" "本地备份失败"; return 1
        fi
        IFS= read -r archive < "$AIR_EXACT_RESULT_FILE"
        rm -f "$AIR_EXACT_RESULT_FILE"
        [[ -n $archive && -f $archive ]] || { air_error "未获得本次完整归档路径。"; return 1; }
        air_backup_event_log "$kind" "本地完整备份完成（可能包含应用凭据）" || return 1
        # 本地备份先完成并恢复容器，再检查传送工具和连接远端。
    fi
    command -v rclone >/dev/null || {
        air_error "缺少rclone；本地备份保留，可由其他传送任务发送。"
        air_backup_event_log "$kind" "传送工具缺失，本地备份保留"; return 1;
    }
    result=$(air_remote_engine upload "$kind" "$archive" 2>&1) || rc=$?
    [[ -z $result ]] || printf '%s\n' "$result"
    if (( rc )); then
        air_backup_event_log "$kind" "传送失败，本地备份保留" || return 1
    elif [[ $result == *'上传并校验成功'* ]]; then
        air_backup_event_log "$kind" "传送校验完成" || return 1
    fi
    # 无新文件/稳定等待/已发送跳过不写日志，防止空闲日志膨胀。
    # Cleanup only after verified upload or verified unchanged sent signature.
    if [[ $rc == 0 && ( $result == *'上传并校验成功'* || $result == *'最新归档已传送，跳过。'* ) ]]; then
        if [[ $action == backup ]]; then
            air_locked air_prune_local_backups || return 1
        elif [[ $kind == ssh || $kind == s3 ]]; then
            local transfer_keep
            transfer_keep=$(air_remote_engine local-keep "$kind") || return 1
            if [[ $transfer_keep =~ ^[1-9][0-9]*$ ]]; then
                air_locked air_prune_local_backups "$transfer_keep" || return 1
            fi
        fi
    fi
    return "$rc"
}
air_single_remote_locked_run() (
    local kind=$1
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || exit 1
    umask 077
    mkdir -p "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { echo "配置正在修改，本次跳过。"; exit 0; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { echo "该目标正在传送，本次跳过。"; exit 0; }
    flock -u 7
    exec 7>&-
    if [[ ${2:-} == --scheduled ]]; then
        local due_rc=0
        air_remote_engine due "$kind" || due_rc=$?
        [[ $due_rc != 3 ]] || exit 0
        [[ $due_rc == 0 ]] || exit "$due_rc"
    fi
    air_remote_run "$kind"
)
air_remote_choose_ssh() {
    local selection
    echo "1. SSH备份上传任务"
    echo "2. SSH仅传送任务"
    IFS= read -r -p "选择任务（0取消）：" selection || return 1
    case "$selection" in 1) AI_SELECTED_REMOTE=ssh-backup ;; 2) AI_SELECTED_REMOTE=ssh ;; *) return 1 ;; esac
}


air_remote_summary() {
    # 主菜单仅读取本地配置及timer状态，不连接远端，不显示凭据。
    python3 - "$REMOTE_DIR" "${1:-all}" "$AI_APP_ID" <<'PY'
import pathlib,json,subprocess,sys
root=pathlib.Path(sys.argv[1]); scope=sys.argv[2]
def color(text,code): return '\033['+code+'m'+text+'\033[0m'
def schedule(d):
    if d.get('action','backup')=='transfer': return '每30秒检测新备份并传送'
    interval=d.get('interval','7d'); calendar=d.get('calendar','')
    import re
    match=re.search(r'(\d{2}):(\d{2}):00 Asia/Shanghai$',calendar)
    if interval.endswith('h'):
        minute=int(match.group(2)) if match else 0
        return '每'+interval[:-1]+'小时，第'+str(minute)+'分运行（北京时间 UTC+8）'
    if interval.endswith('d') and match:
        return '每'+interval[:-1]+'天 '+str(int(match.group(1)))+'时 '+str(int(match.group(2)))+'分运行（北京时间 UTC+8）'
    return calendar or '未设置周期'

groups=[('ssh-backup','SSH备份','SSH备份'),('ssh','传送任务','SSH传送'),('s3','S3 API 兼容传送任务','S3传送')]
if scope=='ssh': groups=groups[:2]
elif scope=='s3': groups=groups[2:]
for index,(kind,title,default) in enumerate(groups):
    print(title)
    print('备注名   状态')
    p=root/(kind+'.json')
    if not p.exists(): print(color('暂无','31'))
    else:
        try:
            d=json.loads(p.read_text())
            if not isinstance(d,dict) or not d.get('dest') or not (root/(kind+'.conf')).is_file(): raise ValueError()
            name=str(d.get('name',default)).replace('\n',' ').replace('\r',' ')
            state=color('异常','33')+'（定时未运行）'
            try:
                unit='ai-'+sys.argv[3]+'-backup-'+kind
                r=subprocess.run(['systemctl','is-active',unit+'.timer'],capture_output=True,text=True,timeout=2)
                result=subprocess.run(['systemctl','show',unit+'.service','--property=Result','--value'],capture_output=True,text=True,timeout=2)
                if r.returncode==0 and r.stdout.strip()=='active' and result.returncode==0 and result.stdout.strip() in ('success',''):
                    state=color('正常','32')+'（定时运行中）'
                elif result.returncode==0 and result.stdout.strip() not in ('success',''):
                    state=color('异常','33')+'（最近执行失败）'
            except (OSError,subprocess.TimeoutExpired): state=color('异常','33')+'（检测失败）'
            print(name+'   '+state+'  '+schedule(d))
        except Exception: print(color('异常','33')+'（配置检测失败）')
    print('------------------------' if index==0 and scope!='s3' else '==================================')
PY
}


# Named-task context: old singleton configurations remain usable unchanged.
air_task_context() {
    local selector="$1"
    AIR_BASE_CONFIG="$BACKUP_DIR/config"
    if [[ "$selector" == *@* ]]; then
        AIR_TASK_KIND="${selector%%@*}"
        AIR_TASK_NAME="${selector#*@}"
        [[ "$AIR_TASK_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { air_error '配置名称无效'; return 1; }
        [[ "$AIR_TASK_KIND" == ssh-backup || "$AIR_TASK_KIND" == ssh || "$AIR_TASK_KIND" == s3 ]] || return 1
        REMOTE_DIR="$AIR_BASE_CONFIG/tasks/$AIR_TASK_NAME"
        RETENTION_FILE="$REMOTE_DIR/local-retention.json"
        AI_APP_ID="nezhav0-task-$AIR_TASK_NAME"
    else
        AIR_TASK_KIND="$selector"
    fi
}
air_remote_engine() (
    local mode="$1" selector="$2"; shift 2
    air_task_context "$selector" || exit 1
    air_single_remote_engine "$mode" "$AIR_TASK_KIND" "$@"
)
air_configuration_locked() (
    local selector="$1"; shift
    air_task_context "$selector" || exit 1
    air_single_configuration_locked "$AIR_TASK_KIND" "$@"
)
air_remote_schedule_unlocked() (
    local selector="$1"; shift
    air_task_context "$selector" || exit 1
    air_single_remote_schedule_unlocked "$AIR_TASK_KIND" "$@"
)
air_remote_locked_run() (
    local selector="$1"; shift
    air_task_context "$selector" || exit 1
    air_single_remote_locked_run "$AIR_TASK_KIND" "$@"
)
air_task_selectors() {
    python3 - "$BACKUP_DIR/config" "${1:-all}" <<'PY_NTASKS'
import sys,json,re
from pathlib import Path
root=Path(sys.argv[1]); scope=sys.argv[2]
kinds=['ssh-backup','ssh'] if scope=='ssh' else ['s3'] if scope=='s3' else ['ssh-backup','ssh','s3']
for kind in kinds:
    if (root/(kind+'.json')).is_file() and (root/(kind+'.conf')).is_file(): print(kind)
    for folder in sorted((root/'tasks').glob('*')):
        if folder.is_symlink() or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}',folder.name): continue
        if (folder/(kind+'.json')).is_file() and (folder/(kind+'.conf')).is_file(): print(kind+'@'+folder.name)
PY_NTASKS
}
air_named_summary() {
    [[ ${1:-all} != all ]] || bsl_engine summary
    local scope="${1:-all}" selector dir kind idx=0 title group
    if [[ $scope != s3 ]]; then
        local local_selector
        while IFS= read -r local_selector; do [[ -z $local_selector ]] || idx=$((idx+1)); done < <(bsl_engine selectors)
    fi
    local -a selectors=()
    mapfile -t selectors < <(air_task_selectors "$scope")
    for group in ssh-backup ssh s3; do
        [[ "$scope" != ssh || "$group" != s3 ]] || continue
        [[ "$scope" != s3 || "$group" == s3 ]] || continue
        case "$group" in ssh-backup) title=SSH备份;; ssh) title=传送任务;; s3) title='S3 API 兼容传送任务';; esac
        echo "$title"; echo '备注名   状态'
        local found=0
        for selector in "${selectors[@]}"; do
            kind="${selector%%@*}"; [ "$kind" = "$group" ] || continue
            idx=$((idx+1));found=1
            dir="$BACKUP_DIR/config"
            [[ "$selector" != *@* ]] || dir="$dir/tasks/${selector#*@}"
            python3 - "$dir/$kind.json" "$idx" "$selector" <<'PY_NSUMMARY'
import sys,json,subprocess
p,index,selector=sys.argv[1:]; d=json.load(open(p));kind=selector.split('@')[0]
app='nezhav0-task-'+selector.split('@')[1] if '@' in selector else 'nezhav0'
unit='ai-'+app+'-backup-'+kind+'.timer'
try: active=subprocess.run(['systemctl','is-active','--quiet',unit],capture_output=True,timeout=2).returncode==0
except (OSError,subprocess.TimeoutExpired): active=False
state='\033[32m正常（定时运行中）\033[0m' if active else '\033[33m异常（定时未运行）\033[0m'
name=''.join(c for c in str(d.get('name',selector)) if c.isprintable())
timing='每30秒检测新备份并传送' if d.get('action')=='transfer' else '每'+str(d.get('interval','7d')).removesuffix('d')+'天 '+str(d.get('calendar',''))+'（北京时间）'
print(index+'. '+name+'   '+state+'  '+timing)
PY_NSUMMARY
        done
        [ "$found" = 1 ] || echo 暂无
        [ "$group" != ssh-backup ] && echo '==================================' || echo '------------------------'
    done
}
air_repair_remote_schedules() {
    bsl_engine repair >/dev/null || { echo "本地定时备份修复失败" >&2; return 1; }
    local selector failed=0
    while IFS= read -r selector; do
        [ -n "$selector" ] || continue
        air_remote_schedule "$selector" enable >/dev/null || { air_error "修复 $selector 失败"; failed=1; }
    done < <(air_task_selectors all)
    return "$failed"
}
air_remote_menu() {
    local scope="$1" choice name target selected confirm
    local -a selectors=()
    air_ensure_environment remote || return 1
    air_repair_remote_schedules
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo '=================================='
        echo "二进制哪吒 v0 ${scope^^} 远程备份配置"
        echo '=================================='
        [[ $scope != ssh ]] || bsl_engine summary
        air_named_summary "$scope"
        if [ "$scope" = ssh ]; then
            echo '1. 添加SSH备份任务（定时备份并上传）'
            echo '2. 添加传送任务（有新备份直接传送，不打包）'
            if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then printf '\033[33m3. 本地定时备份到指定目录\033[0m\n'; else echo '3. 本地定时备份到指定目录'; fi
        else echo '1. 添加S3任务（有新备份直接传送，不打包）'; fi
        echo '7. 测试远端读取';echo '8. 立即执行任务';echo '9. 删除任务（保留备份）';echo '0. 返回'
        read -r -p '请输入选项：' choice || return 0
        case "$choice" in
            1|2)
                if [ "$scope" = s3 ]; then [ "$choice" = 1 ] || continue; target=s3
                elif [ "$choice" = 1 ]; then target=ssh-backup; else target=ssh; fi
                read -r -p '配置名称（小写字母开头，数字/横线/下划线，最多32位）: ' name || return 0
                [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo '名称无效'; continue; }
                if [ -e "$BACKUP_DIR/config/tasks/$name" ]; then echo '配置名称已存在，请使用新名称（不会修改正在运行的任务）。'; continue; fi
                air_configuration_locked "$target@$name" air_named_configure "$target" || echo '任务添加未完成，已保存配置可在重开菜单时重试定时修复。'
                ;;
            3) [[ $scope == ssh ]] || continue; bsl_engine create && bsl_engine repair ;;
            7|8|9)
                local selected target confirm
                local -a combined=()
                mapfile -t combined < <(bsl_combined_selectors "$scope")
                if (( ${#combined[@]} == 0 )); then echo '暂无任务'; continue; fi
                IFS= read -r -p '任务编号（0返回）: ' selected || return 0
                [[ $selected != 0 ]] || continue
                if ! [[ $selected =~ ^[1-9][0-9]{0,5}$ ]] || (( selected > ${#combined[@]} )); then echo '编号无效'; continue; fi
                target="${combined[$((selected-1))]}"
                if [[ $target == local@* ]]; then
                    bsl_handle_local "$choice" "$target"
                else
                    case "$choice" in
                        7) air_remote_engine test "$target" ;;
                        8) air_remote_locked_run "$target" ;;
                        9) IFS= read -r -p '输入yes删除该任务（保留备份）: ' confirm || return 0
                           [[ $confirm != yes ]] || air_configuration_locked "$target" air_delete_remote_task "${target%%@*}" ;;
                    esac
                fi
                ;;
            0) return 0 ;;
            *) echo 无效选项 ;;
        esac
    done
}
air_named_configure() {
    local kind="$1"
    if [ "$kind" = ssh-backup ]; then air_configure_local_retention || return 1; fi
    air_remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    air_remote_schedule_unlocked "$kind" enable
}

air_manager_init() {
    BACKUP_DIR="$NEZHAV0_BACKUP_DIR"
    BACKUP_PREFIX="${NEZHAV0_BACKUP_PREFIX}-"
    REMOTE_DIR="$BACKUP_DIR/config"
    LOCK_FILE="$BACKUP_DIR/backup.lock"
    RETENTION_FILE="$REMOTE_DIR/local-retention.json"
    AI_APP_ID=nezhav0
    AI_APP_LABEL='二进制哪吒 v0'
    AI_MANAGER_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
    air_init
}
ai_local_backup() {
    AI_NEW_ARCHIVE=
    nezha_standalone_backup || return 1
    [ -n "$AI_NEW_ARCHIVE" ] && [ -f "$AI_NEW_ARCHIVE" ]
}

nezha_standalone_main() {
    [ "$(id -u)" -eq 0 ] || { echo '请使用 root 运行。'; return 1; }
    install python3 || return 1
    air_manager_init || return 1
    air_repair_remote_schedules || echo "部分远程定时任务修复失败。"
    if [ -d "$nezha_remote_backup_job_dir" ] || [ -d /home/nezha/remote_backup/jobs ] || [ -d /root/.config/nezha_remote_backup/jobs ]; then
        nezha_remote_backup_repair_cron || echo '⚠️ 定时任务自动修复失败，请检查上述错误；未执行备份。'
    fi
    local choice
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo '=================================='
        echo '        二进制哪吒 v0 备份管理'
        echo '=================================='
        echo "备份目录：$NEZHAV0_BACKUP_DIR"
        echo "数据目录：/opt/nezha/dashboard/"
        echo "---------------------------------------"
        air_named_summary all
        echo '1. 备份哪吒面板'
        echo '2. 恢复备份（直接恢复并启动）'
        echo '3. SSH 远程备份配置'
        echo '4. S3 API 兼容备份配置'
        echo '0. 返回'
        echo '----------------------------------'
        IFS= read -r -p '请输入你的选择: ' choice || return 0
        case "$choice" in
            1) nezha_standalone_backup ;;
            2) nezha_standalone_restore ;;
            3) air_remote_menu ssh ;;
            4) air_remote_menu s3 ;;
            0) return 0 ;;
            *) echo '无效选项' ;;
        esac
        IFS= read -r -p '按回车继续...' choice || return 0
    done
}

# Local-only scheduled backups: embedded engine, no SSH/S3 credentials.
BSL_ID='binary-nezhav0'
BSL_LABEL='二进制哪吒v0'
bsl_engine() {
    python3 - "$BACKUP_DIR/config" "$BSL_ID" "$(readlink -f "${BASH_SOURCE[0]}")" "$BSL_LABEL" "$@" 3<&0 <<'CPA_LOCAL_PY'
import sys,os,json,re,pathlib,subprocess,tempfile,fcntl,datetime
P=pathlib.Path
root,app,script,label,mode,*args=sys.argv[1:];root=P(root);sys.stdin=os.fdopen(3)
base=root/'local-tasks';marker='# '+app+' local scheduled backup\n'
def save(p,d):
    fd,t=tempfile.mkstemp(dir=p.parent)
    with os.fdopen(fd,'w') as f:os.fchmod(f.fileno(),0o600);json.dump(d,f,ensure_ascii=False)
    os.replace(t,p)
def rows():return sorted(base.glob('*/local.json'))
def unit(name):return app+'-backup-local-'+name
if mode=='create':
    base.mkdir(parents=True,exist_ok=True,mode=0o700)
    name='default'
    task=base/name
    legacy=[p for p in rows() if p.parent.name!='default']
    if legacy:raise ValueError('检测到旧版多名称本地任务，请先通过9删除旧本地定时配置（保留备份），再设置唯一默认任务：'+', '.join(p.parent.name for p in legacy))
    if task.is_symlink():raise ValueError('任务目录不能是符号链接')
    if (task/'local.json').exists():print('已存在本地定时备份，正在修改配置；取消输入不会改变原配置。')
    print('备份间隔（1h/2h/4h/6h/8h/12h，1d/2d/3d/5d/7d/14d/30d）')
    interval=input('h等于小时，d等于天[默认 7d]：') or '7d'
    if interval not in [str(x)+'h' for x in (1,2,4,6,8,12)]+[str(x)+'d' for x in (1,2,3,5,7,14,30)]:raise ValueError('间隔无效')
    hour=int(input('北京时间备份小时[默认5]：') or 5);minute=int(input('备份分钟[默认0]：') or 0)
    if not 0<=hour<=23 or not 0<=minute<=59:raise ValueError('时间无效')
    dest=P(input('本地备份保存目录[默认'+str(root.parent)+']：') or str(root.parent))
    if not dest.is_absolute() or '..' in dest.parts:raise ValueError('必须使用绝对路径')
    for p in [*reversed(dest.parents),dest]:
        if p.is_symlink():raise ValueError('目录不可为符号链接')
        if p.exists() and (p.stat().st_uid!=0 or p.stat().st_mode&0o022):raise ValueError('目录权限不安全')
    keep=int(input('本地保留数量[默认3]：') or 3)
    if not 1<=keep<=100000:raise ValueError('保留数量无效')
    if input('确认保存本地定时备份配置，输入 yes：')!='yes':sys.exit(0)
    with open(base/'.configuration.lock','a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if any(p.parent.name!='default' for p in rows()):raise ValueError('存在旧版任务，未保存')
        task.mkdir(mode=0o700,exist_ok=True)
        with open(task/'run.lock','a') as operation:
            fcntl.flock(operation,fcntl.LOCK_EX|fcntl.LOCK_NB)
            save(task/'local.json',{'name':name,'dest':str(dest),'keep':keep,'interval':interval,'hour':hour,'minute':minute,'anchor':datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).date().isoformat()})
            if (task/'last.json').exists():(task/'last.json').unlink()
    print('配置已保存；不立即执行备份。')
elif mode=='purge':
    # Preflight every owned unit/config/lock before deleting anything. Do not wait on app locks.
    import contextlib
    if not base.exists():sys.exit(0)
    with contextlib.ExitStack() as stack:
        registry=stack.enter_context(open(base/'.configuration.lock','a'))
        fcntl.flock(registry,fcntl.LOCK_EX|fcntl.LOCK_NB)
        targets=set()
        for p in rows():
            if p.is_symlink() or p.parent.is_symlink():raise ValueError('本地任务配置存在链接，取消卸载')
            lock=stack.enter_context(open(p.parent/'run.lock','a'))
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            targets.add(unit(p.parent.name))
        unitbase=P('/etc/systemd/system')
        for t in unitbase.glob(app+'-backup-local-*.timer'):
            targets.add(t.name[:-6])
        for t in unitbase.glob(app+'-backup-local-*.service'):
            targets.add(t.name[:-8])
        for stem in targets:
            for suffix in ('.service','.timer'):
                t=unitbase/(stem+suffix)
                if t.is_symlink() or t.exists() and not t.read_text().startswith(marker):raise ValueError('发现非本脚本管理的定时单元，取消卸载')
            if subprocess.run(['systemctl','is-active','--quiet',stem+'.service']).returncode==0:raise ValueError('本地备份任务正在执行，取消卸载，请完成后重试')
        for stem in targets:
            if (unitbase/(stem+'.timer')).exists():subprocess.run(['systemctl','disable','--now',stem+'.timer'],check=True)
        for stem in targets:
            for suffix in ('.service','.timer'):
                t=unitbase/(stem+suffix)
                if t.exists():t.unlink()
        for p in rows():
            p.unlink()
            last=p.parent/'last.json'
            if last.exists() and not last.is_symlink():last.unlink()
        if targets:subprocess.run(['systemctl','daemon-reload'],check=True)
    print('本地定时备份配置及自有定时器已清理，归档与稳定锁保留。')
elif mode=='summary':
    warning='注意本地备份不会上传到远程目标地址'
    print('\033[31m'+warning+'\033[0m' if sys.stdout.isatty() and os.environ.get('TERM') not in (None,'dumb') else warning)
    print('本地备份  状态        备份间隔               备份保存路径')
    if not rows():print('\033[31m暂无\033[0m' if sys.stdout.isatty() else '暂无')
    for i,p in enumerate(rows(),1):
        try:
            d=json.loads(p.read_text());stem=unit(p.parent.name)
            def props(suffix,keys):
                r=subprocess.run(['systemctl','show',stem+suffix,*sum((['-p',k] for k in keys),[])],capture_output=True,text=True,timeout=5)
                if r.returncode:raise ValueError('无法查询定时任务')
                return dict(line.split('=',1) for line in r.stdout.splitlines() if '=' in line)
            timer=props('.timer',['LoadState','ActiveState','UnitFileState'])
            service=props('.service',['LoadState','ActiveState','Result'])
            status='正常';color='32'
            if service.get('ActiveState')=='failed' or service.get('Result') not in (None,'','success') or timer.get('ActiveState')=='failed' or 'error' in (timer.get('LoadState',''),service.get('LoadState','')):
                status='错误';color='31'
            elif timer.get('LoadState')!='loaded' or service.get('LoadState')!='loaded' or timer.get('ActiveState')!='active' or timer.get('UnitFileState') not in ('enabled','enabled-runtime'):
                status='异常';color='33'
            period=d['interval'];amount=int(period[:-1]);hour=int(d['hour']);minute=int(d['minute'])
            timing=(f'每 {amount} 小时 第 {minute} 分' if period.endswith('h') else f'每 {amount} 天 {hour} 点 {minute} 分')+'（北京时间）'
            name='本地备份' if p.parent.name=='default' else d['name'];dest=d['dest']
        except Exception:
            name=p.parent.name;dest='配置不可读';timing='无法读取';status='错误';color='31'
        if sys.stdout.isatty():status='\033['+color+'m'+status+'\033[0m'
        print(f'{i}. {name}   {status}  {timing}  {dest}')
    print('==================================')
elif mode=='selectors':
    for p in rows():print('local@'+p.parent.name)
elif mode=='repair' or mode=='remove':
    if mode=='remove' and not re.fullmatch('[a-z][a-z0-9_-]{0,31}',args[0]):raise ValueError('任务名无效')
    configs=rows() if mode=='repair' else [base/args[0]/'local.json']
    for p in configs:
        d=json.loads(p.read_text());name=p.parent.name;stem=unit(name);unitbase=P('/etc/systemd/system')
        targets=[unitbase/(stem+s) for s in ('.service','.timer')]
        for t in targets:
            if t.is_symlink() or t.exists() and not t.read_text().startswith(marker):raise ValueError('外部unit冲突')
        if mode=='remove':
            if subprocess.run(['systemctl','is-active','--quiet',stem+'.service']).returncode==0:raise ValueError('任务正在执行，未删除')
            subprocess.run(['systemctl','disable','--now',stem+'.timer'],check=True)
            for t in targets:
                if t.exists():t.unlink()
            with open(p.parent/'run.lock','a') as op:
                fcntl.flock(op,fcntl.LOCK_EX|fcntl.LOCK_NB)
                p.unlink()
                if (p.parent/'last.json').exists():(p.parent/'last.json').unlink()
            subprocess.run(['systemctl','daemon-reload'],check=True);continue
        if not re.fullmatch('/[A-Za-z0-9_./-]+',script):raise ValueError('脚本路径不支持空格或特殊字符')
        n=int(d['interval'][:-1]);calendar=(f'*-*-* 0/{n}:{d["minute"]:02d}:00' if d['interval'].endswith('h') else f'*-*-* {d["hour"]:02d}:{d["minute"]:02d}:00')+' Asia/Shanghai'
        contents=[marker+'[Unit]\nDescription=Application local backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' --local-task '+name+' --scheduled\nTimeoutStartSec=2h\n',marker+'[Unit]\nDescription=Application local backup timer\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n']
        changed=False
        for t,body in zip(targets,contents):
            if not t.exists() or t.read_text()!=body:t.write_text(body);t.chmod(0o644);changed=True
        if changed:subprocess.run(['systemctl','daemon-reload'],check=True)
        subprocess.run(['systemctl','enable','--now',stem+'.timer'],check=True,stdout=subprocess.DEVNULL)
        if changed:subprocess.run(['systemctl','restart',stem+'.timer'],check=True)
        subprocess.run(['systemctl','is-active','--quiet',stem+'.timer'],check=True)
elif mode in ('settings','due','done'):
    name=args[0]
    if not re.fullmatch('[a-z][a-z0-9_-]{0,31}',name):raise ValueError('任务名无效')
    task=base/name;d=json.loads((task/'local.json').read_text())
    if mode=='settings':print(d['dest']);print(d['keep'])
    else:
        from zoneinfo import ZoneInfo
        today=datetime.datetime.now(ZoneInfo('Asia/Shanghai')).date()
        if mode=='done':save(task/'last.json',{'day':today.isoformat()})
        elif d['interval'].endswith('d'):
            last=json.loads((task/'last.json').read_text()).get('day') if (task/'last.json').exists() else None
            if last==today.isoformat() or (today-datetime.date.fromisoformat(d['anchor'])).days%int(d['interval'][:-1]):sys.exit(3)
CPA_LOCAL_PY
}


bsl_run() (
    local name="$1" due=0 task="$BACKUP_DIR/config/local-tasks/$1"
    mkdir -p "$BACKUP_DIR/config" || return 1
    [[ $name =~ ^[a-z][a-z0-9_-]{0,31}$ && -f $task/local.json && ! -L $task ]] || return 1
    umask 077
    exec 8>"$task/run.lock" || return 1
    flock -n 8 || { echo '本地定时备份任务正在执行。' >&2; return 1; }
    if [[ ${2:-} == --scheduled ]]; then
        bsl_engine due "$name" || due=$?
        [[ $due != 3 ]] || return 0
        [[ $due == 0 ]] || return "$due"
    fi
    local values destination keep
    values=$(bsl_engine settings "$name") || return 1
    destination=${values%$'\n'*}; keep=${values##*$'\n'}
    BSL_DEST="$destination" BSL_KEEP="$keep" BSL_TASK="$task" BSL_TASK_NAME="$name" air_locked bsl_produce || return 1
    bsl_engine done "$name"
)
local_partial_cleanup() {
    python3 - "$BACKUP_DIR" 'nezha-\d{8}-\d{6}\.tar\.gz\.partial' <<'PY_PARTIAL_CLEAN'
import pathlib,sys,re,os,stat
root=pathlib.Path(sys.argv[1]);rule=re.compile(sys.argv[2]);candidates=[]
for p in root.iterdir():
    if not rule.fullmatch(p.name):continue
    s=p.lstat()
    if stat.S_ISREG(s.st_mode) and s.st_uid==0 and s.st_nlink==1:
        candidates.append((p,s))
# Conservative guard: retain every open candidate, regardless of read/write mode.
opened=set()
try:
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit():continue
        try:
            for fd in (proc/'fd').iterdir():
                try:
                    s=fd.stat();opened.add((s.st_dev,s.st_ino))
                except FileNotFoundError:pass
        except (FileNotFoundError,ProcessLookupError):pass
except (PermissionError,OSError):
    print('临时归档清理跳过：不能完整检查进程文件句柄。',file=sys.stderr)
    sys.exit(0)
closed=sorted(((p,s) for p,s in candidates if (s.st_dev,s.st_ino) not in opened),key=lambda pair:(pair[1].st_mtime_ns,pair[0].name),reverse=True)
# Keep newest ONE stale partial; never count live files against this limit.
for p,before in closed[1:]:
    try:after=p.lstat()
    except FileNotFoundError:continue
    if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns)!=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):continue
    p.unlink()
PY_PARTIAL_CLEAN
}

bsl_produce() (
    umask 077
    BSL_DATA_DIR="/opt/nezha/dashboard"
    python3 - "$BSL_DEST" "${BSL_DATA_DIR:-}" <<'PY_BSL_PATH'
import os,sys,pathlib
p=pathlib.Path(sys.argv[1]);data=pathlib.Path(sys.argv[2]) if sys.argv[2] else None
if not p.is_absolute() or '..' in p.parts:raise ValueError('备份目录必须是绝对路径')
for q in [*reversed(p.parents),p]:
    if q.is_symlink():raise ValueError('备份路径不能含符号链接')
    if not q.exists():q.mkdir(mode=0o700)
    s=q.stat()
    if s.st_uid!=0 or s.st_mode&0o022:raise ValueError('备份目录权限不安全')
if data and (p==data or data in p.parents):raise ValueError('备份目录不能在应用数据内')
PY_BSL_PATH
    [[ $? == 0 ]] || return 1
    BACKUP_DIR="$BSL_DEST"
    NEZHAV0_BACKUP_DIR="$BACKUP_DIR"
    local retention
    retention=$(mktemp "$BACKUP_DIR/.local-retention.XXXXXXXX") || return 1
    trap 'rm -f -- "$retention"' EXIT
    RETENTION_FILE="$retention"
    printf '{"keep":%s}\n' "$BSL_KEEP" > "$RETENTION_FILE"
    local_partial_cleanup || return 1
    air_remote_backup_app

)
bsl_combined_selectors() {
    local scope="${1:-ssh}"
    [[ $scope == s3 ]] || bsl_engine selectors
    air_task_selectors "$scope"
}

bsl_handle_local() {
    local choice="$1" target="$2" confirm
    case "$choice" in
        7) echo '本地定时备份无远端，无需读取测试。' ;;
        8) bsl_run "${target#*@}" ;;
        9) IFS= read -r -p '输入yes删除本地定时任务（保留备份）：' confirm || return 1
           [[ $confirm != yes ]] || bsl_engine remove "${target#*@}" ;;
    esac
}

if [[ ${1:-} == --local-task ]]; then
    air_manager_init || exit 1
    bsl_run "${2:-}" "${3:-}"
    exit $?
fi
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} == --remote-task ]]; then
        air_manager_init || exit 1
        air_ensure_environment || exit 1
        air_remote_locked_run "${3:-}@${2:-}" "${4:-}"
        exit $?
    fi
    if [[ ${1:-} == --remote ]]; then
        air_manager_init || exit 1
        air_ensure_environment || exit 1
        air_remote_locked_run "${2:-}" "${3:-}"
        exit $?
    fi
    nezha_standalone_main
fi
