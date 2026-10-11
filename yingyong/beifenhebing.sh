#!/bin/bash
# 明文任务管理；不自动迁移、停止或启动现有 legacy .x 任务。
# 凭据仅保存到 0600 配置；下载任务和 launcher 为 0700。
set +x
set +v
gh_proxy=${gh_proxy-}

generate_task() (
    set +x
    set +v
    umask 077
    local url=$1 output=$2 temp local_ip
    [[ $output == /*.sh && ${useip-} =~ ^[a-zA-Z0-9.:_-]+$ && -n ${usepasswd-} ]] || {
        echo "远程地址或密码为空/无效" >&2; return 1;
    }
    command -v python3 >/dev/null || { echo "需要 python3" >&2; return 1; }
    temp=$(mktemp -d "${output%/*}/.task-build.XXXXXXXX") || return 1
    trap 'rm -rf -- "$temp"' EXIT
    if ! wget -q -O "$temp/payload.sh" "$url" || [[ ! -s $temp/payload.sh ]]; then
        echo "下载失败，未生成任务或修改调度" >&2; return 1
    fi
    local_ip=$(curl -4 -fsS --max-time 15 ifconfig.me || curl -4 -fsS --max-time 15 ipinfo.io/ip) || {
        echo "获取本机 IP 失败" >&2; return 1;
    }
    [[ $local_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $local_ip != 0.0.0.0 ]] || {
        echo "本机 IP 无效" >&2; return 1;
    }
    # 只替换有明确 shell 引用上下文的占位符，模板变化则 fail closed。
    python3 - "$temp/payload.sh" <<'PY'
import pathlib, sys, subprocess
p = pathlib.Path(sys.argv[1])
s = p.read_text().replace('\r\n', '\n')
for token, var in [('vps密码', 'TASK_PASSWORD'), ('vpsip', 'TASK_REMOTE_IP')]:
    if token not in s:
        raise SystemExit('模板缺少凭据占位符')
    for quote in ["'", '"']:
        s = s.replace(quote + token + quote, '"${' + var + '}"')
    if token == 'vpsip':
        # 地址已验证为不含 shell 元字符的主机/IP。
        s = s.replace(token, '${TASK_REMOTE_IP}')
    if token in s:
        raise SystemExit('模板占位符引用形式不支持，拒绝生成')
p.write_text(s)
if subprocess.run(['bash', '-n', str(p)]).returncode:
    raise SystemExit('下载脚本语法错误')
PY
    [[ $? == 0 ]] || return 1
    printf 'TASK_REMOTE_IP=%q\nTASK_PASSWORD=%q\nTASK_LOCAL_IP=%q\n' \
        "$useip" "$usepasswd" "$local_ip" > "$temp/task.conf" || return 1
    {
        echo '#!/bin/bash'
        echo 'set +x'
        echo 'set +v'
        printf 'source %q || exit 1\n' "$output.conf"
        echo 'IP=$(curl -4 -fsS --max-time 15 ifconfig.me || curl -4 -fsS --max-time 15 ipinfo.io/ip) || exit 1'
        echo '[[ "$IP" == "$TASK_LOCAL_IP" ]] || { echo "IP not allowed: $IP" >&2; exit 1; }'
        printf 'source %q\n' "${output%.sh}.payload.sh"
    } > "$temp/launcher.sh" || return 1
    bash -n "$temp/launcher.sh" || return 1
    chmod 600 "$temp/task.conf" || return 1
    chmod 700 "$temp/launcher.sh" "$temp/payload.sh" || return 1
    # 临时文件与最终文件同文件系统；最终 .sh 绝不作为清理中间文件删除。
    mv -fT -- "$temp/task.conf" "$output.conf" &&
    mv -fT -- "$temp/payload.sh" "${output%.sh}.payload.sh" &&
    mv -fT -- "$temp/launcher.sh" "$output" || return 1
)

# 精确路径白名单，禁止按关键词广泛删除 cron 或任意路径。
known_task_paths() {
    local base
    for base in /home/web/beifen/beifenwhmcs /home/web/beifen/beifen /home/web/beifen/chuansong \
        /home/luntanbeifen /home/web/vaultwarden/beifen \
        /home/web/vaultwarden/mimachuansong /home/web/vaultwarden/mimachuansong2 \
        /home/web/beifen/zidongtuchuang /home/docker/wangpan /home/docker/zixuanmulu \
        /home/docker/zixuanmulu2 /home/docker/wangpan/waibucunchu \
        /home/docker/miniochuansong /home/论坛备份/discoursebeifen \
        /home/论坛备份/discoursebeifen1 /home/quanbubeifen /home/quanbubeifen2; do
        printf '%s.sh\n%s.x\n' "$base" "$base"
    done
}
managed_tasks() {
    local line path token found
    local -a paths words
    mapfile -t paths < <(known_task_paths)
    while IFS= read -r line; do
        [[ -z $line || $line == \#* ]] && continue
        read -r -a words <<< "$line"
        found=0
        for token in "${words[@]}"; do
            for path in "${paths[@]}"; do
                if [[ $token == "$path" ]]; then
                    printf '%s\t%s\n' "$path" "$line"
                    found=1; break
                fi
            done
            (( found )) && break
        done
    done
}
show_tasks() {
    local row i=0
    echo "当前已有定时任务（.x 为 legacy，保持不迁移）："
    while IFS= read -r row; do
        ((i+=1)); printf '%s. %s\n' "$i" "${row#*$'\t'}"
    done < <(crontab -l 2>/dev/null | managed_tasks)
}
website_tasks() {
    local path row
    while IFS=$'\t' read -r path row; do
        case "$path" in
            /home/web/beifen/beifen.sh|/home/web/beifen/beifen.x|/home/web/beifen/beifenwhmcs.sh|/home/web/beifen/beifenwhmcs.x|/home/web/beifen/chuansong.sh|/home/web/beifen/chuansong.x) printf '%s\t%s\n' "$path" "$row" ;;
        esac
    done
}

delete_task() {
    local scope=${1:-all}
    if [[ $scope == website ]]; then
        python3 /root/yingyong/beifenhebing-web.py select-delete
        return $?
    fi
    local snapshot row choice selected path line temp i=0
    local -a rows
    snapshot=$(crontab -l 2>/dev/null) || { echo "没有可删除的 cron 任务"; return 1; }
    if [[ $scope == website ]]; then
        mapfile -t rows < <(printf '%s\n' "$snapshot" | managed_tasks | website_tasks)
    else
        mapfile -t rows < <(printf '%s\n' "$snapshot" | managed_tasks)
    fi
    for row in "${rows[@]}"; do ((i+=1)); printf '%s. %s\n' "$i" "${row#*$'\t'}"; done
    IFS= read -r -p "请输入要删除的任务编号: " choice || return 1
    [[ $choice =~ ^[1-9][0-9]*$ && $choice -le ${#rows[@]} ]] || { echo "无效编号"; return 1; }
    selected=${rows[choice-1]}; path=${selected%%$'\t'*}; line=${selected#*$'\t'}
    temp=$(mktemp) || return 1
    # 保持原次序，且只删选中那一行一次。
    local removed=0 current
    while IFS= read -r current; do
        if [[ $removed == 0 && $current == "$line" ]]; then removed=1; continue; fi
        printf '%s\n' "$current"
    done <<< "$snapshot" > "$temp"
    crontab "$temp" || { rm -f -- "$temp"; return 1; }
    rm -f -- "$temp"
    # 若该路径还有其他 cron 引用，不删除其文件。systemd/legacy 不停启。
    if ! crontab -l 2>/dev/null | managed_tasks | cut -f1 | grep -Fxq -- "$path"; then
        rm -f -- "$path"
        if [[ $path == *.sh ]]; then
            rm -f -- "$path.conf" "${path%.sh}.payload.sh"
        fi
    fi
    echo "已删除定时任务: $line（未停止或迁移服务）"
}
test_task() {
    local kind=$1 row path choice i=0
    if [[ $kind == website ]]; then
        python3 /root/yingyong/beifenhebing-web.py select-run
        return $?
    fi
    local -a paths=()
    while IFS=$'\t' read -r path row; do
        case $kind:$path in
            website:/home/web/beifen/beifen.sh|website:/home/web/beifen/beifen.x|website:/home/web/beifen/beifenwhmcs.sh|website:/home/web/beifen/beifenwhmcs.x|website:/home/web/beifen/chuansong.sh|website:/home/web/beifen/chuansong.x) ;;
            backup:*beifen.sh|backup:*beifen.x|backup:*beifenwhmcs.sh|backup:*beifenwhmcs.x) ;;
            transfer:*chuansong.sh|transfer:*chuansong.x|transfer:*mimachuansong2.sh|transfer:*mimachuansong2.x) ;;
            *) continue ;;
        esac
        paths+=("$path"); ((i+=1)); printf '%s. %s\n' "$i" "$path"
    done < <(crontab -l 2>/dev/null | managed_tasks)
    IFS= read -r -p "请选择要测试的任务编号: " choice || return 1
    [[ $choice =~ ^[1-9][0-9]*$ && $choice -le ${#paths[@]} ]] || { echo "无效编号"; return 1; }
    path=${paths[choice-1]}
    [[ -f $path && -x $path ]] || { echo "脚本不存在或不可执行"; return 1; }
    # ELF legacy .x 必须直接执行，不能交给 bash 解释。
    "$path"
}

website_backup_menu() {
    local choice
    local WEB_CONNECTION_SESSION=menu-${BASHPID}-${RANDOM}
    export WEB_CONNECTION_SESSION
    /usr/bin/python3 /root/yingyong/beifenhebing-web.py probe || echo '连接检测异常'
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        网站备份（/home/web）"
        echo "=================================="
        /usr/bin/python3 /root/yingyong/beifenhebing-web.py summary || echo "任务检测异常"
        echo "=================================="
        echo "1. 网站备份"
        echo "2. 备份传送"
        echo "3. S3 API兼容备份配置"
        echo "7. 测试连接"
        echo "8. 执行某个任务"
        echo "9. 删除任务"
        echo "------------------------"
        echo "0. 返回上一级"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) operation_1 ;;
            2) operation_2 ;;
            3) /usr/bin/python3 /root/yingyong/beifenhebing-web.py create-s3 ;;
            7) /usr/bin/python3 /root/yingyong/beifenhebing-web.py select-test ;;
            8) test_task website ;;
            9) delete_task website ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

forum_backup_menu() {
    local choice
    local WEB_CONNECTION_SESSION=menu-${BASHPID}-${RANDOM}
    export WEB_CONNECTION_SESSION
    /usr/bin/python3 /root/yingyong/beifenhebing-forum.py install-cron >/dev/null || echo '论坛调度修复异常'
    /usr/bin/python3 /root/yingyong/beifenhebing-forum.py probe || echo '连接检测异常'
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        论坛备份（/var/discourse）"
        echo "=================================="
        /usr/bin/python3 /root/yingyong/beifenhebing-forum.py summary || echo "任务检测异常"
        echo "=================================="
        echo "1. 论坛全量备份"
        echo "2. 论坛全量传送"
        echo "3. 论坛全量传送S3 API兼容备份配置"
        echo "4. 论坛全量备份恢复（从 /home 检测备份）"
        echo "7. 测试连接"
        echo "8. 执行某个任务"
        echo "9. 删除任务"
        echo "------------------------"
        echo "0. 返回上一级"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) /usr/bin/python3 /root/yingyong/beifenhebing-forum.py create ;;
            2) /usr/bin/python3 /root/yingyong/beifenhebing-forum.py create-transfer ;;
            3) /usr/bin/python3 /root/yingyong/beifenhebing-forum.py create-s3 ;;
            4) forum_restore ;;
            7) /usr/bin/python3 /root/yingyong/beifenhebing-forum.py select-test ;;
            8) /usr/bin/python3 /root/yingyong/beifenhebing-forum.py select-run ;;
            9) /usr/bin/python3 /root/yingyong/beifenhebing-forum.py select-delete ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

forum_generated_menu() {
    local choice
    local WEB_CONNECTION_SESSION=menu-${BASHPID}-${RANDOM}
    export WEB_CONNECTION_SESSION
    /usr/bin/python3 /root/yingyong/beifenhebing-generated.py install-cron >/dev/null || echo '论坛调度修复异常'
    /usr/bin/python3 /root/yingyong/beifenhebing-generated.py probe || echo '连接检测异常'
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        论坛内部生成备份传送"
        echo "=================================="
        /usr/bin/python3 /root/yingyong/beifenhebing-generated.py summary || echo "任务检测异常"
        echo "=================================="
        echo "1. 论坛内部生成备份传送"
        echo "2. 论坛内部生成备份S3 API兼容备份配置"
        echo "7. 测试连接"
        echo "8. 执行某个任务"
        echo "9. 删除任务"
        echo "------------------------"
        echo "0. 返回上一级"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) /usr/bin/python3 /root/yingyong/beifenhebing-generated.py create-transfer ;;
            2) /usr/bin/python3 /root/yingyong/beifenhebing-generated.py create-s3 ;;
            7) /usr/bin/python3 /root/yingyong/beifenhebing-generated.py select-test ;;
            8) /usr/bin/python3 /root/yingyong/beifenhebing-generated.py select-run ;;
            9) /usr/bin/python3 /root/yingyong/beifenhebing-generated.py select-delete ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

local_archive_mode_menu() {
    local choice
    local engine="$1" title="$2"
    local WEB_CONNECTION_SESSION=menu-${BASHPID}-${RANDOM}
    export WEB_CONNECTION_SESSION
    /usr/bin/python3 "$engine" install-cron >/dev/null || echo '论坛调度修复异常'
    /usr/bin/python3 "$engine" probe || echo '连接检测异常'
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        $title"
        echo "=================================="
        /usr/bin/python3 "$engine" summary || echo "任务检测异常"
        echo "=================================="
        echo "1. 本地归档SSH传送"
        echo "2. 本地归档S3 API兼容备份配置"
        echo "7. 测试连接"
        echo "8. 执行某个任务"
        echo "9. 删除任务"
        echo "------------------------"
        echo "0. 返回上一级"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) /usr/bin/python3 "$engine" create-transfer ;;
            2) /usr/bin/python3 "$engine" create-s3 ;;
            7) /usr/bin/python3 "$engine" select-test ;;
            8) /usr/bin/python3 "$engine" select-run ;;
            9) /usr/bin/python3 "$engine" select-delete ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}


local_archive_overview() {
    /usr/bin/python3 - "$1" <<'LOCAL_OVERVIEW_PY'
import importlib.util,sys
from pathlib import Path
modules=[]
for mode in ('sync','keep'):
    path=Path('/root/yingyong/beifenhebing-local-'+mode+'.py')
    spec=importlib.util.spec_from_file_location('overview_'+mode,path)
    module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
    modules.append(module)
if sys.argv[1]=='count':
    count=sum(len(m.entries()) for m in modules)
    print(f'\033[32m已有 {count} 个\033[0m' if count else '\033[31m暂无\033[0m')
else:
    index=0
    for i,(m,title) in enumerate(zip(modules,('同步传送删除远端','传送不删除远程文件'))):
        print(title);print('备注名   状态')
        rows=m.entries();states=m.cached_connections()
        if not rows:print('\033[31m暂无\033[0m')
        for row in rows:
            index+=1
            label='S3' if row.get('config',{}).get('mode')=='s3' else 'SSH'
            name=''.join(x for x in row['name'] if x.isprintable())
            print(f"{index}. {name}   {m.connection_label(states.get(row['id']))}（{label}）")
        if i==0:print('------------------------')
LOCAL_OVERVIEW_PY
}

local_archive_menu() {
    local choice
    local WEB_CONNECTION_SESSION=local-overview-${BASHPID}-${RANDOM}
    export WEB_CONNECTION_SESSION
    /usr/bin/python3 /root/yingyong/beifenhebing-local-sync.py probe || echo "同步任务连接检测异常"
    /usr/bin/python3 /root/yingyong/beifenhebing-local-keep.py probe || echo "传送任务连接检测异常"
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo "=================================="
        echo "        备份本地*.tar.gz（/home/备份）"
        echo "=================================="
        local_archive_overview summary || echo "任务检测异常"
        echo "=================================="
        echo "1. 本地*.tar.gz备份同步传送"
        echo "2. 本地*.tar.gz备份传送不删除远程文件"
        echo "------------------------"
        echo "0. 返回上一级"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) local_archive_mode_menu /root/yingyong/beifenhebing-local-sync.py '本地归档同步传送（删除远端多余归档）' ;;
            2) local_archive_mode_menu /root/yingyong/beifenhebing-local-keep.py '本地归档传送（不删除远端）' ;;
            0) return 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

show_menu() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo "=================================="
    echo "        自动备份传送 管理脚本"
    echo "明文任务配置、定时备份及文件变化监控传送"
    echo "=================================="
    echo "网站备份任务 详情进入 1 查看"
    /usr/bin/python3 /root/yingyong/beifenhebing-web.py count || echo "任务检测异常"
    echo "论坛备份任务 详情进入 2 查看"
    /usr/bin/python3 /root/yingyong/beifenhebing-forum.py count || echo "任务检测异常"
    echo "论坛生成备份传送 详情进入 3 查看"
    /usr/bin/python3 /root/yingyong/beifenhebing-generated.py count || echo "任务检测异常"
    echo "备份本地*.tar.gz（home/备份）详情进入 99 查看"
    local_archive_overview count || echo "任务检测异常"
    echo "=================================="
      echo "1. 网站备份（/home/web）"
      echo "2. 论坛备份（/var/discourse）"
      echo "------------------------"
      echo "3. 论坛生成备份传送"
      echo "------------------------"
      echo "11. 图床备份"
      echo "------------------------"
      echo "------------------------"
      echo "99. 备份本地*.tar.gz（home/备份）"
      echo "------------------------"
      echo "------------------------"
      echo "0. 退出"
}

operation_111() (
IFS= read -r -p "输入远程服务器IP: " useip
  IFS= read -r -s -p "输入远程服务器密码: " usepasswd || return 1; echo

  mkdir -p /home/web/beifen
  cd /home/web/beifen || return 1

  OUTPUT_BIN="/home/web/beifen/beifenwhmcs.sh"
  generate_task "${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/beifenwhmcs.sh" "$OUTPUT_BIN" || return 1

  echo "------------------------"
  echo "选择备份频率："
  echo "1. 每周备份"
  echo "2. 每天固定时间备份"
  echo "3. 每N天备份一次（精确到分钟）"
  IFS= read -r -p "请输入选择编号: " dingshi

  case $dingshi in
    1)
      IFS= read -r -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
      IFS= read -r -p "几点备份（0-23）: " hour
      IFS= read -r -p "几分备份（0-59）: " minute
      if crontab -l 2>/dev/null | grep -Fq -- "$OUTPUT_BIN"; then
        echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
      else
        (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
        echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
      fi
      ;;
    2)
      IFS= read -r -p "每天几点备份（0-23）: " hour
      IFS= read -r -p "每天几分备份（0-59）: " minute
      if crontab -l 2>/dev/null | grep -Fq -- "$OUTPUT_BIN"; then
        echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
      else
        (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
        echo "已设置每天 ${hour}点${minute}分进行备份"
      fi
      ;;
    3)
      IFS= read -r -p "每几天备份一次（如：2 表示每2天）: " interval
      IFS= read -r -p "几点（0-23）: " hour
      IFS= read -r -p "几分（0-59）: " minute
      if crontab -l 2>/dev/null | grep -Fq -- "$OUTPUT_BIN"; then
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
)

operation_1() (
    python3 /root/yingyong/beifenhebing-web.py create
)

operation_2() (
    python3 /root/yingyong/beifenhebing-web.py create-transfer
)

operation_3() (
delete_task
)

operation_4() (
test_task backup
)

operation_5() (
test_task transfer
)

operation_11() (
IFS= read -r -p "输入远程服务器IP: " useip
          IFS= read -r -s -p "输入远程服务器密码: " usepasswd || return 1; echo

          mkdir -p /home/web/beifen
          cd /home/web/beifen || return 1

          OUTPUT_BIN="/home/web/beifen/beifen.sh"
          generate_task "${gh_proxy}https://raw.githubusercontent.com/zaixiangjian/sh/main/zidongtuchuang.sh" "$OUTPUT_BIN" || return 1

          echo "------------------------"
          echo "选择备份频率："
          echo "1. 每周备份"
          echo "2. 每天固定时间备份"
          echo "3. 每N天备份一次（精确到分钟）"
          IFS= read -r -p "请输入选择编号: " dingshi

          case $dingshi in
            1)
              IFS= read -r -p "选择每周备份的星期几 (0-6，0代表星期日): " weekday
              IFS= read -r -p "几点备份（0-23）: " hour
              IFS= read -r -p "几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -Fq -- "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * $weekday $OUTPUT_BIN") | crontab -
                echo "已设置每周星期$weekday ${hour}点${minute}分进行备份"
              fi
              ;;
            2)
              IFS= read -r -p "每天几点备份（0-23）: " hour
              IFS= read -r -p "每天几分备份（0-59）: " minute
              if crontab -l 2>/dev/null | grep -Fq -- "$OUTPUT_BIN"; then
                echo "备份任务 $OUTPUT_BIN 已存在，跳过添加。"
              else
                (crontab -l 2>/dev/null; echo "$minute $hour * * * $OUTPUT_BIN") | crontab -
                echo "已设置每天 ${hour}点${minute}分进行备份"
              fi
              ;;
            3)
              IFS= read -r -p "每几天备份一次（如：2 表示每2天）: " interval
              IFS= read -r -p "几点（0-23）: " hour
              IFS= read -r -p "几分（0-59）: " minute
              if crontab -l 2>/dev/null | grep -Fq -- "$OUTPUT_BIN"; then
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
)







forum_restore() (
    /usr/bin/python3 - 3<&0 <<'FORUM_RESTORE_PY'
import os, sys, tarfile, tempfile, shutil, datetime
sys.stdin = os.fdopen(3)
from pathlib import Path
home = Path('/home')
target = Path('/var/discourse')
files = sorted((p for p in home.glob('*.tar.gz') if p.is_file() and not p.is_symlink()), key=lambda p:p.stat().st_mtime_ns, reverse=True)
if not files:
    print('没有找到 /home 第一层的 .tar.gz 备份'); raise SystemExit(0)
for i,p in enumerate(files,1): print(f'{i}. {p.name}')
choice=input('选择论坛备份编号（回车最新，0取消）: ')
if choice=='0': raise SystemExit(0)
if choice and (not choice.isdigit() or not 1 <= int(choice) <= len(files)):
    raise SystemExit('编号无效，未恢复')
p=files[int(choice)-1 if choice else 0]
with tarfile.open(p,'r:gz') as archive:
    members=archive.getmembers()
    if not members: raise SystemExit('归档为空，未恢复')
    for m in members:
        parts=Path(m.name).parts
        if not parts or parts[0]!='discourse' or '..' in parts or Path(m.name).is_absolute() or not (m.isfile() or m.isdir()):
            raise SystemExit('不是安全的 discourse 全量目录归档（链接/特殊文件不允许），未恢复')
print('将恢复 '+p.name+' 到 /var/discourse。请先停止论坛容器及数据库，勿在运行中恢复。')
if input('确认已停止论坛并恢复，输入小写 yes: ') != 'yes':
    print('已取消'); raise SystemExit(0)
if target.is_symlink(): raise SystemExit('恢复目标是符号链接，拒绝操作')
staging=Path(tempfile.mkdtemp(prefix='.forum-restore-',dir='/var'))
previous=None
try:
    with tarfile.open(p,'r:gz') as archive:
        archive.extractall(staging,filter='data')
    candidate=staging/'discourse'
    if not candidate.is_dir(): raise ValueError('归档缺少 discourse 目录')
    if target.exists():
        previous=Path(tempfile.mkdtemp(prefix='discourse-before-restore-',dir='/var'))
        previous.rmdir()
        target.rename(previous)
    try: candidate.rename(target)
    except BaseException:
        if previous is not None: previous.rename(target)
        raise
    print('论坛全量备份恢复完成。')
    if previous: print('恢复前数据保留在：'+str(previous))
    print('请使用')
    print('bash /root/kejilion.sh')
    print('11.  面板工具 ▶️')
    print('72 应用  2 号重建')
finally:
    shutil.rmtree(staging)
FORUM_RESTORE_PY
)

repair_dependencies() {
    local tool manager
    local -a missing=() packages=()
    for tool in curl wget sshpass rsync ssh scp python3 flock crontab; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if ! [[ -x /usr/bin/python3 ]] || ! /usr/bin/python3 -c 'import sys,json,pathlib,fcntl,subprocess; assert sys.version_info >= (3,9)' >/dev/null 2>&1; then
        [[ " ${missing[*]} " == *" python3 "* ]] || missing+=(python3)
    fi
    [[ ${#missing[@]} -gt 0 ]] || return 0
    [[ $EUID -eq 0 ]] || { echo "缺少依赖：${missing[*]}；请使用 root 运行以自动安装。" >&2; return 1; }
    if command -v apt-get >/dev/null 2>&1; then manager=apt
    elif command -v dnf >/dev/null 2>&1; then manager=dnf
    elif command -v yum >/dev/null 2>&1; then manager=yum
    elif command -v apk >/dev/null 2>&1; then manager=apk
    else echo "缺少依赖：${missing[*]}；无法识别包管理器，请手动安装。" >&2; return 1
    fi
    for tool in "${missing[@]}"; do
        case "$tool" in
            ssh|scp) [[ $manager == apt || $manager == apk ]] && packages+=(openssh-client) || packages+=(openssh-clients) ;;
            flock) packages+=(util-linux) ;;
            crontab) [[ $manager == apt ]] && packages+=(cron) || { [[ $manager == apk ]] && packages+=(dcron) || packages+=(cronie); } ;;
            *) packages+=("$tool") ;;
        esac
    done
    echo "缺少 ${missing[*]}，正在自动安装..."
    case "$manager" in
        apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}" || return 1 ;;
        dnf) dnf install -y -q "${packages[@]}" || return 1 ;;
        yum) yum install -y -q "${packages[@]}" || return 1 ;;
        apk) apk add --no-cache "${packages[@]}" || return 1 ;;
    esac
    for tool in "${missing[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || { echo "依赖安装后校验失败：$tool" >&2; return 1; }
    done
    /usr/bin/python3 -c 'import sys,json,pathlib,fcntl,subprocess; assert sys.version_info >= (3,9)' >/dev/null 2>&1 || {
        echo "系统 Python 3 不可用或低于3.9，未启动菜单任务，请升级系统Python。" >&2
        return 1
    }
}

main() {
    local choice
    repair_dependencies || { echo "依赖自动修复失败，请处理以上错误后重试。" >&2; return 1; }
    /usr/bin/python3 /root/yingyong/beifenhebing-web.py install-cron >/dev/null || echo "网站备份定时任务检测异常，未覆盖其他任务。" >&2
    /usr/bin/python3 /root/yingyong/beifenhebing-forum.py install-cron >/dev/null || echo "论坛调度修复异常" >&2
    /usr/bin/python3 /root/yingyong/beifenhebing-generated.py install-cron >/dev/null || echo "论坛生成备份传送调度修复异常" >&2
    /usr/bin/python3 /root/yingyong/beifenhebing-local-sync.py install-cron >/dev/null || echo "本地同步调度修复异常" >&2
    /usr/bin/python3 /root/yingyong/beifenhebing-local-keep.py install-cron >/dev/null || echo "本地传送调度修复异常" >&2
    while true; do
        show_menu
        IFS= read -r -p "请输入选项：" choice || { echo "已退出"; return 0; }
        case "$choice" in
            1) website_backup_menu; continue ;;
            2) forum_backup_menu; continue ;;
            3) forum_generated_menu; continue ;;
            11) operation_11 ;;
            99) local_archive_menu; continue ;;
            0) echo "已退出"; return 0 ;;
            *) echo "无效选项。" ;;
        esac
        IFS= read -r -p "按回车继续..." choice || return 0
    done
}

# 单文件发布：helpers 为下方可读源码；只在直接运行时释放，不在 source 时写入。
central_data_migrate() {
    /usr/bin/python3 - <<'CENTRAL_DATA_MIGRATE_PY'
import os,sys,json,shutil,subprocess,tempfile,fcntl,stat
from pathlib import Path
base=Path('/home/备份/data')
old_roots={'website':Path('/home/web/beifen/tasks'),'forum':Path('/home/论坛备份/tasks'),'generated':Path('/home/论坛生成备份任务/tasks'),'local-sync':Path('/home/本地归档传送任务/sync'),'local-keep':Path('/home/本地归档传送任务/keep')}
base.mkdir(parents=True,exist_ok=True,mode=0o700)
if base.is_symlink():raise ValueError('data不能是符号链接')
os.chmod(base,0o700)
lock=open(base/'.migration.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
pending=[(key,src) for key,src in old_roots.items() if src.exists() and not src.is_symlink()]
if not pending:sys.exit(0)
services=[]
for key,src in pending:
 stem='web' if key=='website' else key
 for transport in ['transfer','s3']:
  name='beifenhebing-'+stem+'-'+transport+'.service'
  r=subprocess.run(['systemctl','is-active','--quiet',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  if r.returncode==0:services.append(name)
for name in services:subprocess.run(['systemctl','stop',name],check=True)
held=[]
try:
 # All former workers stopped. Fail immediately if a manual operation still holds any stable lock.
 for key,src in pending:
  if src.is_symlink():raise ValueError('旧注册目录不能是链接')
  for p in src.rglob('*.lock'):
   fd=os.open(p,os.O_RDWR|os.O_NOFOLLOW)
   if not stat.S_ISREG(os.fstat(fd).st_mode):raise ValueError('锁不是普通文件')
   fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);held.append(fd)
 backup=Path(tempfile.mkdtemp(prefix='migration-backup-',dir=base))
 for key,src in pending:
  dst=base/key
  if dst.exists():raise ValueError('新旧注册目录同时存在，停止迁移以避免覆盖')
  shutil.copytree(src,backup/key)
  src.rename(dst) # same filesystem: retain all lock inodes
  for pointer in dst.glob('*/location.json'):
   task=pointer.parent;loc=json.loads(pointer.read_text())
   if loc.get('runtime_config'):continue
   filename=loc.get('config_file')
   if not filename:raise ValueError('旧配置格式需人工核对')
   original=Path(loc['local_dir'])/filename
   if original.is_symlink():raise ValueError('脚本不能是链接')
   lines=original.read_text().splitlines(keepends=True)
   rows=[r[len('# BEIFEN_CONFIG '):] for r in lines if r.startswith('# BEIFEN_CONFIG ')]
   if len(rows)!=1:raise ValueError('配置标记异常')
   c=json.loads(rows[0]);target=task/filename
   for field,suffix in [('password_file','.password'),('credential_file','.credentials')]:
    if c.get(field):
     cred=Path(c[field])
     if cred.is_symlink():raise ValueError('凭据不能是链接')
     shutil.copy2(cred,backup/(key+'-'+task.name+suffix))
     dest=target.with_suffix(suffix);cred.rename(dest);os.chmod(dest,0o600);c[field]=str(dest)
   original.rename(target)
   target.write_text(''.join('# BEIFEN_CONFIG '+json.dumps(c,ensure_ascii=False)+'\n' if r.startswith('# BEIFEN_CONFIG ') else r for r in lines));os.chmod(target,0o700)
   pointer.write_text(json.dumps({'runtime_config':filename,'local_dir':c['local_dir']},ensure_ascii=False)+'\n');os.chmod(pointer,0o600)
finally:
 for fd in held:os.close(fd)
 for name in services:subprocess.run(['systemctl','start',name],check=True)
CENTRAL_DATA_MIGRATE_PY
}

singlefile_python_ready() {
    /usr/bin/python3 -c 'import sys,fcntl; assert sys.version_info >= (3,9)' >/dev/null 2>&1 && return 0
    [[ $EUID == 0 ]] || { echo '自动释放需要 root 和 Python >=3.9' >&2; return 1; }
    echo '正在安装单文件启动依赖 Python 3...' >&2
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 || return 1
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q python3 || return 1
    elif command -v yum >/dev/null 2>&1; then yum install -y -q python3 || return 1
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache python3 || return 1
    else echo '请安装 Python >=3.9 后重试' >&2; return 1; fi
    /usr/bin/python3 -c 'import sys,fcntl; assert sys.version_info >= (3,9)' >/dev/null 2>&1
}
singlefile_bootstrap() {
    singlefile_python_ready || return 1
    /usr/bin/python3 - "${BASH_SOURCE[0]}" 'beifenhebing.sh' <<'SINGLEFILE_INSTALLER_PY'
import os,sys,stat,fcntl,re,tempfile,subprocess
from pathlib import Path
if os.geteuid()!=0: raise SystemExit('单文件释放请使用 root 运行')
os.umask(0o077)
canonical=Path('/root/yingyong')

def open_components(path, create=False):
    path=Path(os.path.abspath(path))
    fd=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            if create:
                try: os.mkdir(part,0o700,dir_fd=fd)
                except FileExistsError: pass
            nxt=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=fd)
            os.close(fd);fd=nxt
            st=os.fstat(fd)
            if create and (st.st_uid!=0 or st.st_mode&0o022):
                raise ValueError('发布目录必须 root 所有且不可被其他用户写入')
        return fd
    except BaseException:
        os.close(fd);raise

def read_regular(fd,name):
    f=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
    try:
        st=os.fstat(f)
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_mode&0o022:
            raise ValueError('源码/目标必须为 root 所有的安全普通文件: '+name)
        with os.fdopen(os.dup(f),'rb') as stream: return stream.read(),stat.S_IMODE(st.st_mode)
    finally: os.close(f)

source=Path(os.path.abspath(sys.argv[1]))
sfd=open_components(source.parent)
try: source_bytes,_=read_regular(sfd,source.name)
finally: os.close(sfd)
text=source_bytes.decode('utf-8')
files={}
for match in re.finditer(r'^# SINGLEFILE_HELPER ([a-z0-9-]+\.py) (SINGLEFILE_SOURCE_[A-Z0-9_]+)\n    cat <<\x27\2\x27\n(.*?)^\2\n',text,re.M|re.S):
    name,delimiter,body=match.groups()
    if name in files: raise ValueError('重复嵌入helper')
    compile(body,name,'exec')
    files[name]=body.encode('utf-8')
expected=['beifenhebing-web.py', 'beifenhebing-web-s3.py']
if set(files)!=set(expected): raise ValueError('嵌入helper集合不完整')
# Derive independent forum engines from the embedded current source.
forum = files['beifenhebing-web.py'].decode('utf-8')
forum = forum.replace('beifenhebing-web', 'beifenhebing-forum').replace('网站', '论坛')
forum = forum.replace("ROOT = Path('/home/web/beifen/tasks')", "ROOT = Path('/home/论坛备份/tasks')")
forum = forum.replace("SOURCE = Path('/home/web')", "SOURCE = Path('/var/discourse')")
forum = forum.replace('/home/web', '/var/discourse')
a = forum.index('LEGACY = tuple(')
b = forum.index('\n\n', a)
forum = forum[:a] + "LEGACY = tuple(Path('/home/论坛备份/' + n + ext) for n in ('discoursebeifen','discoursebeifen1') for ext in ('.sh','.x'))" + forum[b:]
forum_s3 = files['beifenhebing-web-s3.py'].decode('utf-8').replace('beifenhebing-web', 'beifenhebing-forum').replace('网站', '论坛')
for name, body in [('beifenhebing-forum.py', forum), ('beifenhebing-forum-s3.py', forum_s3)]:
    compile(body, name, 'exec')
    files[name] = body.encode('utf-8')
generated = files['beifenhebing-web.py'].decode('utf-8').replace('beifenhebing-web', 'beifenhebing-generated').replace('网站', '论坛内部生成备份')
generated = generated.replace("ROOT = Path('/home/web/beifen/tasks')", "ROOT = Path('/home/论坛生成备份任务/tasks')")
generated = generated.replace('/home/web', '/var/discourse/shared/standalone/backups/default')
a = generated.index('LEGACY = tuple('); b = generated.index('\n\n', a)
generated = generated[:a] + "LEGACY = tuple(Path('/home/luntanbeifen' + ext) for ext in ('.sh','.x'))" + generated[b:]
overrides = "import shutil\n\n# Discourse-generated backups: separate read source from owned config/archive directory.\n_PENDING_SOURCE = None\n_GENERATED_PATTERN = re.compile(r'(.+?)-([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})(?:-v[^/]*)?\\.tar\\.gz')\n\ndef archive_pattern(c):\n    site = c.get('generated_site')\n    return re.compile((re.escape(site) if site else r'[^/]+') + r'-([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})(?:-v[^/]*)?\\.tar\\.gz')\n\ndef archive_sort_key(name, c):\n    match = archive_pattern(c).fullmatch(name)\n    if not match: return None\n    stamp = match.group(1)\n    try: dt.datetime.strptime(stamp, '%Y-%m-%d-%H%M%S')\n    except ValueError: return None\n    return stamp\n\ndef local_path(text):\n    text = text.strip()\n    if not text or any(ord(x)<32 for x in text): raise ValueError('本地路径不能为空或含控制字符')\n    p = Path('/' + text.lstrip('/')).resolve()\n    if p == Path('/'): raise ValueError('不能选择根目录')\n    return p\n\ndef transfer_source():\n    global _PENDING_SOURCE\n    existing = [c for _,c in configs() if c.get('source_dir')]\n    default_source = existing[0]['source_dir'] if existing else '/var/discourse/shared/standalone/backups/default'\n    while True:\n        try:\n            source = local_path(prompt('本地Discourse生成备份目录（可手动修改）', default_source))\n            if not source.is_dir(): raise ValueError('备份读取目录不存在')\n            break\n        except ValueError as ex: print(str(ex))\n    matches = [c for c in existing if c['source_dir'] == str(source)]\n    reuse = matches[0] if matches else None\n    archive = latest_archive(source, {})\n    site = reuse.get('generated_site') if reuse else None\n    if not site and archive:\n        site = _GENERATED_PATTERN.fullmatch(archive.name).group(1)\n        validate_backup_prefix(site)\n    if site:\n        default = reuse['local_dir'] if reuse else '/home/备份/' + site\n        print('自动获取网站名称：' + site)\n        destination = local_path(prompt('配置保存目录', default))\n    else:\n        print('名称自动获取失败')\n        while True:\n            text = prompt('请手动输入本地路径（例如 /home/备份/备注名）')\n            if not text.strip():\n                text = prompt('不能为空请重新输入（例如 /home/备份/备注名）')\n            try:\n                destination = local_path(text)\n                site = validate_backup_prefix(destination.name)\n                break\n            except ValueError as ex: print(str(ex))\n    if destination == source or destination in source.parents or source in destination.parents:\n        raise ValueError('配置保存目录必须独立于原始备份目录')\n    _PENDING_SOURCE = (str(source), site)\n    return destination, site\n\n_original_atomic_json = atomic_json\ndef atomic_json(path, value):\n    if path.name == 'location.json' and _PENDING_SOURCE:\n        script = Path(value['local_dir']) / value['config_file']\n        c = read_config(script)\n        c.pop('backup_prefix', None)\n        c['source_dir'], c['generated_site'] = _PENDING_SOURCE\n        rows = script.read_text().splitlines(keepends=True)\n        content = ''.join('# BEIFEN_CONFIG ' + json.dumps(c, ensure_ascii=False) + '\\n' if row.startswith('# BEIFEN_CONFIG ') else row for row in rows)\n        fd,tmp = tempfile.mkstemp(prefix='.config-', dir=script.parent)\n        try:\n            os.fchmod(fd,0o700)\n            with os.fdopen(fd,'w') as f: f.write(content)\n            os.replace(tmp,script)\n        finally:\n            if os.path.exists(tmp): os.unlink(tmp)\n    return _original_atomic_json(path, value)\n\n_original_transfer_tick = transfer_tick\n_original_upload_existing = upload_existing\n_original_s3_module = s3_module\n\ndef copy_for_send(task,c,p):\n    local = local_path(c.get('archive_destination', c['local_dir']))\n    local.mkdir(parents=True,exist_ok=True,mode=0o700)\n    if local == p.parent: return p\n    target = local / p.name\n    digest = checked_checksum(p)\n    if target.exists():\n        if target.is_symlink() or checked_checksum(target)!=digest: raise ValueError('本地备份同名冲突，拒绝覆盖')\n        return target\n    before = signature(p)\n    fd,tmp = tempfile.mkstemp(prefix='.archive-',dir=local)\n    try:\n        os.fchmod(fd,0o600)\n        with os.fdopen(fd,'wb') as out, p.open('rb') as source:\n            shutil.copyfileobj(source,out)\n        if signature(p)!=before or checked_checksum(Path(tmp))!=digest: raise ValueError('复制期间原始备份变化')\n        os.link(tmp,target)\n    finally:\n        if os.path.exists(tmp): os.unlink(tmp)\n    return target\n\ndef upload_existing(task,c,p):\n    sent = copy_for_send(task,c,p)\n    transport = dict(c); transport['local_dir'] = c.get('archive_destination',c['local_dir'])\n    return _original_upload_existing(task,transport,sent)\n\ndef s3_module():\n    module = _original_s3_module()\n    if not getattr(module,'_generated_copy_wrapper',False):\n        original = module.upload_existing\n        def upload(task,c,p):\n            sent = copy_for_send(task,c,p)\n            transport = dict(c); transport['local_dir'] = c.get('archive_destination',c['local_dir'])\n            return original(task,transport,sent)\n        module.upload_existing = upload\n        module._generated_copy_wrapper = True\n    return module\n\ndef transfer_tick(task,c,now=None,force=False):\n    effective = dict(c)\n    if c.get('source_dir'):\n        effective['archive_destination'] = c['local_dir']\n        effective['local_dir'] = c['source_dir']\n    return _original_transfer_tick(task,effective,now,force)\n"
generated = generated.replace("[('backup', '备份任务'), ('transfer', '备份传送'), ('s3', 'S3 API 兼容传送任务')]", "[('transfer', '备份传送'), ('s3', 'S3 API 兼容传送任务')]")
main_guard = generated.rfind("if __name__ == '__main__':")
if main_guard < 0: raise ValueError('generated engine缺少main入口')
generated = generated[:main_guard] + overrides + generated[main_guard:]
generated_s3 = files['beifenhebing-web-s3.py'].decode('utf-8').replace('beifenhebing-web', 'beifenhebing-generated')
for name, body in [('beifenhebing-generated.py', generated), ('beifenhebing-generated-s3.py', generated_s3)]:
    compile(body, name, 'exec'); files[name] = body.encode('utf-8')
bulk_overrides = '# Overrides for recursive local archive transfer; no local deletions.\nimport stat\n\ndef transfer_source():\n    while True:\n        try:\n            p = local_path(prompt(\'本地备份读取路径（包含下级目录）\', \'/home/备份\'))\n            if not p.is_dir(): raise ValueError(\'读取目录不存在\')\n            return p, None\n        except ValueError as ex: print(str(ex))\n\ndef local_path(text):\n    if not text.strip() or any(ord(x)<32 for x in text): raise ValueError(\'目录不能为空或含控制字符\')\n    p=Path(\'/\'+text.strip().lstrip(\'/\')).resolve()\n    if p==Path(\'/\'): raise ValueError(\'不能使用根目录\')\n    return p\n\ndef snapshot(c):\n    root=local_path(c[\'local_dir\']); result={}\n    for directory, dirs, names in os.walk(root, followlinks=False):\n        dirs[:]=[n for n in dirs if not (Path(directory)/n).is_symlink() and (Path(directory)/n).resolve()!=Path(\'/home/备份/data\').resolve()]\n        for name in names:\n            p=Path(directory)/name\n            if not name.endswith(\'.tar.gz\') or p.is_symlink() or not p.is_file(): continue\n            result[p.relative_to(root).as_posix()]=signature(p)\n    return result\n\ndef remote_command(c,task,program,args):\n    target=c.get(\'user\',\'root\')+\'@\'+c[\'host\']\n    command=\'python3 -c \'+shlex.quote(program)+\' \'+ \' \'.join(shlex.quote(str(x)) for x in args)\n    return auth_call([\'ssh\']+ssh_args(task,c)+[target,command],c,capture_output=True)\n\ndef ssh_send(task,c,p,rel,checksum):\n    base=remote_path(c[\'remote_dir\']);dest=posixpath.join(base,rel);part=dest+\'.partial-\'+uuid.uuid4().hex\n    cmd=\'umask 077; mkdir -p -- \'+shlex.quote(posixpath.dirname(dest))+\'; t=\'+shlex.quote(part)+\'; trap \\\'rm -f -- "$t"\\\' EXIT; cat > "$t" && mv -- "$t" \'+shlex.quote(dest)\n    with p.open(\'rb\') as f:auth_call([\'ssh\']+ssh_args(task,c)+[c.get(\'user\',\'root\')+\'@\'+c[\'host\'],cmd],c,stdin=f)\n    result=remote_command(c,task,"import hashlib,sys;h=hashlib.sha256();f=open(sys.argv[1],\'rb\');\\nfor b in iter(lambda:f.read(1048576),b\'\'):h.update(b)\\nprint(h.hexdigest())",[dest])\n    if result.stdout.decode().strip()!=checksum:raise ValueError(\'SSH远端校验失败\')\n\ndef safe_rel(value):\n    return bool(value) and not value.startswith(\'/\') and all(x not in (\'\',\'.\',\'..\') for x in value.split(\'/\')) and \'\\\\\' not in value and all(ord(x)>=32 for x in value)\n\ndef s3_rows(client,c):\n    rows=[]\n    for page in client.get_paginator(\'list_objects_v2\').paginate(Bucket=c[\'bucket\'],Prefix=c[\'prefix\']):\n        for item in page.get(\'Contents\',[]):\n            rel=item[\'Key\'][len(c[\'prefix\']):]\n            if safe_rel(rel) and rel.endswith(\'.tar.gz\'):rows.append((rel,item[\'Key\']))\n    return rows\n\ndef transfer_tick(task,c,now=None,force=False):\n    now=time.time() if now is None else now\n    path=task/\'bulk-state.json\';state=json.loads(path.read_text()) if path.exists() else {}\n    current=snapshot(c)\n    if not current:return # Never turn an empty/missing source into remote deletion.\n    if state.get(\'observed\')!=current:\n        state.update(observed=current,changed_at=now,attempts=0,next_attempt=0)\n        atomic_json(path,state);return\n    if now-state[\'changed_at\']<c.get(\'quiet_seconds\',5):return\n    if state.get(\'completed\')==current:return\n    sl=slot(c,now)\n    if state.get(\'attempts\',0)>=c.get(\'retries\',3):\n        if sl is None or sl<=state.get(\'fallback_slot\',-1):return\n        state[\'fallback_slot\']=sl\n    elif now<state.get(\'next_attempt\',0):return\n    state[\'attempts\']=state.get(\'attempts\',0)+1;state[\'next_attempt\']=now+c.get(\'retry_seconds\',60)\n    atomic_json(path,state)\n    root=local_path(c[\'local_dir\']);sent=state.setdefault(\'sent\',{})\n    client=None;module=None\n    try:\n        for rel,sig in current.items():\n            if not safe_rel(rel):raise ValueError(\'不安全相对路径\')\n            if sent.get(rel)==sig:continue\n            p=root/rel;checksum=checked_checksum(p)\n            if signature(p)!=sig:raise ValueError(\'文件变化\')\n            if c.get(\'mode\')==\'s3\':\n                if client is None:\n                    module=s3_module();client=module.client(c);module.ensure_bucket(client,c)\n                from boto3.s3.transfer import TransferConfig\n                cfg=TransferConfig(multipart_threshold=8*1024*1024,multipart_chunksize=8*1024*1024,max_concurrency=2)\n                key=c[\'prefix\']+rel\n                client.upload_file(str(p),c[\'bucket\'],key,Config=cfg,ExtraArgs={\'Metadata\':{\'sha256\':checksum}})\n                body=client.get_object(Bucket=c[\'bucket\'],Key=key)[\'Body\'];digest=hashlib.sha256()\n                try:\n                    for block in iter(lambda:body.read(1048576),b\'\'):digest.update(block)\n                finally:body.close()\n                if digest.hexdigest()!=checksum:raise ValueError(\'S3读回校验失败\')\n            else:ssh_send(task,c,p,rel,checksum)\n            if signature(p)!=sig:raise ValueError(\'上传期间本地变化\')\n            sent[rel]=sig;atomic_json(path,state)\n        if snapshot(c)!=current:raise ValueError(\'目录变化，未清理\')\n        if BULK_SYNC:\n            if c.get(\'mode\')==\'s3\':\n                if client is None:module=s3_module();client=module.client(c)\n                for rel,key in s3_rows(client,c):\n                    if rel not in current:client.delete_object(Bucket=c[\'bucket\'],Key=key)\n                if any(rel not in current for rel,key in s3_rows(client,c)):raise ValueError(\'远端删除未完成\')\n            else:\n                manifest=json.dumps(list(current),ensure_ascii=False)\n                program="import os,sys,json,pathlib;root=pathlib.Path(sys.argv[1]);keep=set(json.loads(sys.argv[2]));\\nif root.is_symlink():raise ValueError(\'unsafe root\')\\nfor d,dirs,names in os.walk(root,followlinks=False):\\n dirs[:]=[n for n in dirs if not (pathlib.Path(d)/n).is_symlink()]\\n for n in names:\\n  p=pathlib.Path(d)/n\\n  if n.endswith(\'.tar.gz\') and not p.is_symlink() and p.is_file() and p.relative_to(root).as_posix() not in keep:p.unlink()\\nremaining={p.relative_to(root).as_posix() for p in root.rglob(\'*.tar.gz\') if p.is_file() and not p.is_symlink()}\\nassert not remaining-keep"\n                remote_command(c,task,program,[remote_path(c[\'remote_dir\']),manifest])\n        state[\'completed\']=current;state[\'sent\']={r:sent[r] for r in current};atomic_json(path,state)\n    except Exception as ex:\n        print(\'本地归档传送未完成：\'+type(ex).__name__+\'；未标记完成\',file=sys.stderr)\n\n# Explicit confirmation of each task\'s remote destination; normalize slash variants.\n_bulk_prompt = prompt\ndef remote_path(text):\n    text = text.strip()\n    if not text or any(ord(x)<32 for x in text): raise ValueError(\'远程目录不能为空或含控制字符\')\n    value = posixpath.normpath(\'/\' + text.lstrip(\'/\'))\n    if value == \'/\': raise ValueError(\'远程目录不能是根目录\')\n    return value\n\ndef prompt(label, default=None):\n    if label not in (\'远程目录\',) and not label.startswith(\'S3桶内保存路径\'):\n        return _bulk_prompt(label, default)\n    while True:\n        text = _bulk_prompt(label, default)\n        try:\n            if label == \'远程目录\': normalized = remote_path(text)\n            else:\n                text = text or (label.split(\'回车默认 \',1)[1].split(\' ）\',1)[0].strip() if \'回车默认 \' in label else \'/备份/web\')\n                normalized = s3_module().normalize_prefix(text)\n        except ValueError as ex:\n            print(str(ex));continue\n        print(\'本任务远程保存位置：\' + normalized)\n        if _bulk_prompt(\'与本任务配置的备份传送目录一致请输入 yes 确认\') == \'yes\':\n            return normalized\n        print(\'未确认，请重新输入远程保存位置。\')\n'
for mode, sync in [('sync', True), ('keep', False)]:
    stem = 'beifenhebing-local-' + mode
    bulk = files['beifenhebing-web.py'].decode('utf-8').replace('beifenhebing-web', stem).replace('网站', '本地归档')
    bulk = bulk.replace("ROOT = Path('/home/web/beifen/tasks')", "ROOT = Path('/home/本地归档传送任务/" + mode + "')")
    bulk = bulk.replace('# 本地归档备份 /home/web', '# 本地归档' + mode + '备份 /home/web')
    a = bulk.index('LEGACY = tuple('); b = bulk.index('\n\n', a)
    bulk = bulk[:a] + 'LEGACY = ()' + bulk[b:]
    bulk = bulk.replace("[('backup', '备份任务'), ('transfer', '备份传送'), ('s3', 'S3 API 兼容传送任务')]", "[('transfer', '备份传送'), ('s3', 'S3 API 兼容传送任务')]")
    bulk = bulk.replace("'transfer-state.json', 'known_hosts'", "'transfer-state.json', 'bulk-state.json', 'known_hosts'")
    bulk = bulk.replace("确认专用目录并保存任务，输入 yes", "确认递归传送且同步模式会删除专用远端内本地不存在的.tar.gz，输入 yes")
    bulk = bulk.replace('仅扫描选中目录第一层最新归档；不打包、不清理本地。定时为额外兜底，时区UTC。', '递归传送所选目录内全部.tar.gz，保留相对目录；已成功且未变化则跳过。不打包、不清理本地，时区UTC。')
    bulk = bulk.replace("    private_root()\n    with lock(ROOT / '.scheduler.lock'),", "    private_root()\n    with lock(ROOT / '.scheduler.lock'),")
    bulk = bulk.replace("    host = prompt(", "    if any(c.get('id') == task_id for _, c in configs()):\n        print('同名任务已存在，请使用其他任务名称；如需重建，请先通过9删除。')\n        return\n    host = prompt(")
    pos = bulk.rfind("if __name__ == '__main__':")
    bulk = bulk[:pos] + 'BULK_SYNC = ' + repr(sync) + '\n' + bulk_overrides + '\n' + bulk[pos:]
    bulk_s3 = files['beifenhebing-web-s3.py'].decode('utf-8').replace('beifenhebing-web', stem)
    bulk_s3 = bulk_s3.replace('确认保存凭据并启用远端清理请输入 yes', '确认保存：同步模式删除本地不存在的远端.tar.gz，保留模式不删除，输入 yes')
    for name, content in [(stem+'.py', bulk), (stem+'-s3.py', bulk_s3)]:
        compile(content,name,'exec'); files[name] = content.encode('utf-8')
central_overrides = '# Central runtime config, task locks, bounded logs; archive locations stay unchanged.\nimport logging, logging.handlers\n\n_runtime_config_path = config_path\n_runtime_atomic_json = atomic_json\n\ndef config_path(task):\n    pointer = task / \'location.json\'\n    if pointer.exists():\n        location = json.loads(pointer.read_text())\n        filename = location.get(\'runtime_config\')\n        if filename:\n            if \'/\' in filename or not filename.endswith(\'.sh\'): raise ValueError(\'运行配置路径无效\')\n            target = task / filename\n            if target.is_symlink(): raise ValueError(\'配置不能是链接\')\n            return target\n    return _runtime_config_path(task)\n\ndef atomic_json(path, value):\n    if path.name == \'location.json\' and value.get(\'config_file\'):\n        task = path.parent\n        original = Path(value[\'local_dir\']) / value[\'config_file\']\n        c = read_config(original)\n        pending = globals().get("_PENDING_SOURCE")\n        if pending:\n            c.pop("backup_prefix", None)\n            c["source_dir"], c["generated_site"] = pending\n        target = task / original.name\n        for field, suffix in [(\'password_file\',\'.password\'), (\'credential_file\',\'.credentials\')]:\n            if c.get(field):\n                src = Path(c[field]); dest = target.with_suffix(suffix)\n                if src != dest:\n                    if src.is_symlink() or dest.exists(): raise ValueError(\'凭据迁移路径冲突\')\n                    # Never expose the secret; preserve bytes and private permissions.\n                    fd = os.open(dest, os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)\n                    with os.fdopen(fd,\'wb\') as f: f.write(src.read_bytes())\n                    src.unlink()\n                c[field] = str(dest)\n        content = \'#!/bin/bash\\n# BEIFEN_CONFIG \'+json.dumps(c,ensure_ascii=False)+\'\\nexec /usr/bin/python3 \'+shlex.quote(str(ENGINE))+\' run \'+shlex.quote(c[\'id\'])+\'\\n\'\n        fd,tmp=tempfile.mkstemp(prefix=\'.config-\',dir=task)\n        try:\n            os.fchmod(fd,0o700)\n            with os.fdopen(fd,\'w\') as f:f.write(content)\n            os.replace(tmp,target)\n        finally:\n            if os.path.exists(tmp):os.unlink(tmp)\n        if original != target:original.unlink()\n        value={\'runtime_config\':target.name,\'local_dir\':c[\'local_dir\']}\n    return _runtime_atomic_json(path,value)\n\ndef runtime_log(task,event,status):\n    # Stable flock protects log rotation across cron and worker processes.\n    ROOT.mkdir(parents=True,exist_ok=True,mode=0o700)\n    with lock(ROOT/\'.log.lock\'):\n        logger=logging.getLogger(\'runtime-\'+str(ROOT));logger.setLevel(logging.INFO);logger.propagate=False\n        handler=logging.handlers.RotatingFileHandler(ROOT/\'operations.log\',maxBytes=2*1024*1024,backupCount=5,encoding=\'utf-8\')\n        logger.addHandler(handler)\n        try:\n            handler.setFormatter(logging.Formatter(\'%(asctime)s %(message)s\'))\n            logger.info(\'%s %s %s\', \'\'.join(x for x in str(task.name) if x.isalnum() or x in \'-_\'),event,status)\n            os.chmod(ROOT/\'operations.log\',0o600)\n        finally:logger.removeHandler(handler);handler.close()\n\n_runtime_tick=transfer_tick\ndef transfer_tick(task,c,now=None,force=False):\n    # No idle heartbeat logging: record only changed transmission results.\n    before={p.name:p.stat().st_mtime_ns for p in task.glob(\'*state.json\')}\n    try:\n        result=_runtime_tick(task,c,now,force)\n        after={p.name:p.stat().st_mtime_ns for p in task.glob(\'*state.json\')}\n        if before!=after:runtime_log(task,\'transfer\',\'state-updated\')\n        return result\n    except Exception as ex:\n        runtime_log(task,\'transfer\',type(ex).__name__);raise\n\n_runtime_archive=archive_and_transfer\ndef archive_and_transfer(task,c):\n    runtime_log(task,\'backup\',\'started\')\n    try:\n        result=_runtime_archive(task,c);runtime_log(task,\'backup\',\'completed\');return result\n    except Exception as ex:runtime_log(task,\'backup\',type(ex).__name__);raise\n'
runtime_roots = {
 'web':'/home/备份/data/website', 'forum':'/home/备份/data/forum',
 'generated':'/home/备份/data/generated', 'local-sync':'/home/备份/data/local-sync',
 'local-keep':'/home/备份/data/local-keep'}
for category, root in runtime_roots.items():
    name='beifenhebing-'+category+'.py'
    text=files[name].decode('utf-8')
    text=re.sub(r"^ROOT = Path\('[^']+'\)", 'ROOT = Path('+repr(root)+')',text,flags=re.M)
    pos=text.rfind("if __name__ == '__main__':")
    text=text[:pos]+central_overrides+'\n'+text[pos:]
    compile(text,name,'exec');files[name]=text.encode('utf-8')
    s3name='beifenhebing-'+category+'-s3.py'
    text=files[s3name].decode('utf-8')
    text=text.replace("expected = Path(c['local_dir']) / (c['name'] + '-s3.credentials')", "expected = e.config_path(e.task_by_id(c['id'])).with_suffix('.credentials')")
    text=text.replace('    validate(c)\n    expected =', '    validate(c)\n    e = engine()\n    expected =')
    compile(text,s3name,'exec');files[s3name]=text.encode('utf-8')
files[sys.argv[2]]=source_bytes
rootfd=open_components(canonical,create=True)
os.fchmod(rootfd,0o700)
lockfd=os.open('.singlefile-bootstrap.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600,dir_fd=rootfd)
st=os.fstat(lockfd)
if not stat.S_ISREG(st.st_mode) or st.st_uid!=0 or st.st_nlink!=1 or st.st_mode&0o077:
    raise ValueError('bootstrap锁文件不安全')
fcntl.flock(lockfd,fcntl.LOCK_EX)
staged={};old={};published=[]
try:
    # 先校验所有目标、编译全部源码、准备全部同目录临时文件，再开始发布。
    for name,data in files.items():
        try: before,mode=read_regular(rootfd,name)
        except FileNotFoundError: before,mode=None,None
        old[name]=(before,mode)
        if before==data and mode==0o700: continue
        fd,tmp=tempfile.mkstemp(prefix='.singlefile-stage-',dir=canonical)
        try:
            os.fchmod(fd,0o700)
            with os.fdopen(fd,'wb') as stream:
                stream.write(data);stream.flush();os.fsync(stream.fileno())
        except BaseException:
            os.unlink(tmp);raise
        staged[name]=tmp
    check=staged.get(sys.argv[2]) or str(canonical/sys.argv[2])
    subprocess.run(['bash','-n',check],check=True)
    for name,tmp in staged.items():
        os.replace(tmp,name,dst_dir_fd=rootfd);published.append(name)
    os.fsync(rootfd)
except BaseException:
    # 可捕获的发布错误恢复旧版本，不删除用户数据/配置。
    for name in reversed(published):
        data,mode=old[name]
        if data is None: os.unlink(name,dir_fd=rootfd)
        else:
            fd,tmp=tempfile.mkstemp(prefix='.singlefile-rollback-',dir=canonical)
            with os.fdopen(fd,'wb') as stream:
                os.fchmod(stream.fileno(),mode);stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.replace(tmp,name,dst_dir_fd=rootfd)
    raise
finally:
    for tmp in staged.values():
        try: os.unlink(tmp)
        except FileNotFoundError: pass
    os.close(lockfd);os.close(rootfd)
SINGLEFILE_INSTALLER_PY
}

# 内嵌源码：不要只修改已释放 .py；再次分发前应同步这里的最新版。
singlefile_embedded_sources() {
# SINGLEFILE_HELPER beifenhebing-web.py SINGLEFILE_SOURCE_BEIFENHEBING_WEB_PY
    cat <<'SINGLEFILE_SOURCE_BEIFENHEBING_WEB_PY'
#!/usr/bin/env python3
"""明文、多任务网站热备；仅显式 create/install-cron/delete 会修改 cron。"""
import argparse
import contextlib
import datetime as dt
import fcntl
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import posixpath
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
import concurrent.futures
import gzip
import tarfile
import importlib.util

_S3 = None
def s3_module():
    global _S3
    if _S3 is None:
        spec = importlib.util.spec_from_file_location('web_s3', ENGINE.with_name('beifenhebing-web-s3.py'))
        _S3 = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_S3)
    return _S3

SERVICE = 'beifenhebing-web-transfer.service'
SERVICE_FILE = Path('/etc/systemd/system') / SERVICE
LEGACY_ARCHIVE_PATTERN = re.compile(r'web_(?:[0-9]{14}|[0-9]{20}_[0-9a-f]{8})\.tar\.gz')
DATE_SUFFIX = r'([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})\.tar\.gz'
ARCHIVE_PATTERN = re.compile(r'(?:web_(?:[0-9]{14}|[0-9]{20}_[0-9a-f]{8})|[^/\\\x00-\x1f*?\[\]]+-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})\.tar\.gz')


def validate_backup_prefix(value):
    if (not isinstance(value, str) or not value.strip() or value in ('.', '..') or
            any(x in value for x in '/\\*?[]') or
            any(ord(x) < 32 or 127 <= ord(x) <= 159 for x in value)):
        raise ValueError('备份前缀不能为空，不能含路径分隔、控制字符、通配符或为 . / ..')
    try: size = len(value.encode('utf-8', errors='strict'))
    except UnicodeError: raise ValueError('备份前缀必须为有效UTF-8') from None
    if size > 128: raise ValueError('备份前缀最多128字节UTF-8')
    return value


def backup_prefix_prompt():
    print('备份前缀可更改，例如：*-xxxx-xx-xx-xxxxxx.tar.gz')
    label = '请输入备份前缀（必填）'
    while True:
        value = prompt(label)
        try:
            validate_backup_prefix(value)
            print('当前备份前缀为')
            print(value + '-xxxx-xx-xx-xxxxxx.tar.gz')
            return value
        except ValueError as ex:
            if not value.strip():
                label = '不能为空，重新输入前缀 '
            else:
                print(str(ex))
                label = '重新输入前缀 '


def archive_pattern(c):
    if 'backup_prefix' not in c: return LEGACY_ARCHIVE_PATTERN
    prefix = validate_backup_prefix(c['backup_prefix'])
    return re.compile(re.escape(prefix) + '-' + DATE_SUFFIX)


def archive_sort_key(name, c):
    match = archive_pattern(c).fullmatch(name)
    if not match: return None
    if 'backup_prefix' not in c: return name[4:-7]
    stamp = match.group(1)
    try: dt.datetime.strptime(stamp, '%Y-%m-%d-%H%M%S')
    except ValueError: return None
    return stamp


def archive_name(c):
    now = dt.datetime.now(dt.timezone.utc)
    if 'backup_prefix' not in c: return 'web_' + now.strftime('%Y%m%d%H%M%S') + '.tar.gz'
    return validate_backup_prefix(c['backup_prefix']) + '-' + now.strftime('%Y-%m-%d-%H%M%S') + '.tar.gz'


def backup_local(prefix):
    default = '/home/备份/' + prefix + '/'
    while True:
        try: return local_path(prompt('本地备份保存路径（回车默认' + default + '）') or default)
        except ValueError as ex: print(str(ex))

ROOT = Path('/home/web/beifen/tasks')
SOURCE = Path('/home/web')
ENGINE = Path('/root/yingyong/beifenhebing-web.py')
BEGIN = '# 网站备份 /home/web （勿删）'
END = '# 网站备份 /home/web 结束（勿删）'
OLD_BEGIN = '# BEGIN beifenhebing-web managed'
OLD_END = '# END beifenhebing-web managed'
INTERVALS = {s: int(s[:-1]) * (3600 if s[-1] == 'h' else 86400)
             for s in ('1h','2h','4h','6h','12h','1d','2d','3d','5d','7d')}
LEGACY = tuple(Path('/home/web/beifen/' + n + ext)
               for n in ('beifen','beifenwhmcs','chuansong') for ext in ('.sh','.x'))


def call(args, **kw):
    return subprocess.run(args, check=True, timeout=kw.pop('timeout', 120), **kw)


@contextlib.contextmanager
def lock(path, blocking=True):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield
    finally:
        os.close(fd)  # 永不删除锁 inode


def private_root():
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if ROOT.is_symlink():
        raise ValueError('任务根目录不能是符号链接')
    os.chmod(ROOT, 0o700)


def atomic_json(path, value):
    fd, tmp = tempfile.mkstemp(prefix='.json-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def local_path(text):
    text = text.strip()
    if not text or any(c in text for c in '\n\r\0'):
        raise ValueError('本地目录必须填写绝对路径')
    p = Path('/' + text.lstrip('/')).resolve()
    source = SOURCE.resolve()
    if p == source or source in p.parents:
        raise ValueError('本地备份目录不能位于 /home/web 内，避免递归归档')
    if p == Path('/') or p in source.parents:
        raise ValueError('不能使用根目录或备份源的父目录作为专用目录')
    return p


def remote_path(text):
    if not text.startswith('/') or any(c in text for c in '\n\r\0'):
        raise ValueError('远程目录必须是绝对路径且不能含换行/NUL')
    p = posixpath.normpath('/' + text.lstrip('/'))
    if p == '/': raise ValueError('远程目录不能是根目录')
    return p


def anchor(hour, minute, now=None):
    now = dt.datetime.now(dt.timezone.utc) if now is None else now
    first = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if first < now: first += dt.timedelta(days=1)
    return int(first.timestamp())


def schedule_anchor(interval, hour, minute, now=None):
    if not interval.endswith('h'):
        return anchor(hour, minute, now)
    now = dt.datetime.now(dt.timezone.utc) if now is None else now
    step = INTERVALS[interval]
    epoch = int(now.timestamp())
    offset = minute * 60
    return ((epoch - offset + step - 1) // step) * step + offset


def slot(config, now):
    if config['interval'].endswith('h'):
        # UTC midnight-aligned N-hour windows, independent of legacy hour=5 anchor.
        offset = int(config['minute']) * 60
        if config.get('schedule_version') == 2 and now < config['anchor_epoch']:
            return None
        if now < offset: return None
        return (int(now) - offset) // config['interval_seconds']
    if now < config['anchor_epoch']: return None
    return (int(now) - config['anchor_epoch']) // config['interval_seconds']


def config_path(task):
    pointer = task / 'location.json'
    if pointer.exists():
        location = json.loads(pointer.read_text())
        local = local_path(location['local_dir'])
        if location.get('config_file'):
            filename = location['config_file']
            if '/' in filename or not filename.endswith('.sh'):
                raise ValueError('任务配置文件名无效')
            target = local / filename
            if target.is_symlink(): raise ValueError('配置不允许符号链接')
            return target
        name = location['config_dir']
        if '/' in name or name in ('.', '..'):
            raise ValueError('配置目录名无效')
        target = local / name / 'config.json'
        if target.is_symlink() or target.parent.is_symlink():
            raise ValueError('配置不允许符号链接')
        return target
    return task / 'config.json'  # existing task compatibility


def read_config(path):
    if path.suffix == '.sh':
        marker = '# BEIFEN_CONFIG '
        rows = [line[len(marker):] for line in path.read_text().splitlines() if line.startswith(marker)]
        if len(rows) != 1: raise ValueError('任务脚本配置标记异常')
        return json.loads(rows[0])
    return json.loads(path.read_text())


def configs():
    if not ROOT.exists(): return []
    result = []
    for task in sorted(ROOT.iterdir()):
        if not task.is_dir() or task.is_symlink(): continue
        p = task
        try:
            p = config_path(task)
            if not p.exists(): continue
            if p.is_symlink() or p.parent.is_symlink(): continue
            c = read_config(p)
            if c.get('id') != task.name: raise ValueError('任务 ID 不一致')
            archive_pattern(c)
            result.append((task, c))
        except (ValueError, OSError) as e:
            print('配置读取失败: ' + str(p) + ': ' + str(e), file=sys.stderr)
    return result


def read_cron():
    r = subprocess.run(['crontab', '-l'], capture_output=True, text=True, timeout=15)
    if r.returncode == 0: return r.stdout
    if r.returncode == 1 and 'no crontab for' in r.stderr.lower(): return ''
    raise RuntimeError('读取 crontab 失败，拒绝覆盖: ' + r.stderr.strip())


def write_cron(text):
    call(['crontab', '-'], input=text, text=True, timeout=15)
    if read_cron() != text:
        raise RuntimeError('crontab readback 不一致，请检查调度；不声称成功')


def cron_text(text, enabled):
    lines = text.splitlines(keepends=True)
    out = []; inside = False; seen = False
    for line in lines:
        if line.rstrip('\r\n') in (BEGIN, OLD_BEGIN):
            if inside or seen: raise ValueError('重复/嵌套拥有块，拒绝覆盖 cron')
            inside = True; seen = True
        elif line.rstrip('\r\n') in (END, OLD_END):
            if not inside: raise ValueError('拥有块标记不完整')
            inside = False
        elif not inside: out.append(line)
    if inside: raise ValueError('拥有块未结束，拒绝覆盖 cron')
    s = ''.join(out)
    if enabled:
        if s and not s.endswith('\n'): s += '\n'
        s += BEGIN + '\n* * * * * /usr/bin/python3 ' + shlex.quote(str(ENGINE)) + ' check >/dev/null 2>&1\n' + END + '\n'
    return s


def reconcile_cron():
    if not ROOT.exists():
        before = read_cron()
        after = cron_text(before, False)
        if after != before: write_cron(after)
        return
    private_root()
    with lock(ROOT / '.scheduler.lock'):
        before = read_cron()
        after = cron_text(before, bool(configs()))
        if after != before: write_cron(after)
        else:
            if read_cron() != after: raise RuntimeError('cron 校验时被并发修改')
    if after != before:
        print('网站备份定时任务块已修复；其他 cron 保留')


def prompt(label, default=None):
    while True:
        try:
            answer = input(label + (f'（回车 {default}）' if default is not None else '') + ': ')
            answer.encode('utf-8', errors='strict')
            break
        except (UnicodeDecodeError, UnicodeEncodeError):
            print('终端输入不是有效UTF-8，请重新输入；中文路径支持UTF-8。')
    return str(default) if answer == '' and default is not None else answer


def positive_prompt(label, default):
    while True:
        text = prompt(label, str(default)).strip()
        if text.isdigit() and 1 <= int(text) <= 86400: return int(text)
        print('请输入1~86400的整数')


def transfer_source():
    backups = [c for _, c in configs() if c.get('mode', 'backup') == 'backup']
    selected = None
    if len(backups) == 1:
        selected = backups[0]
    elif backups:
        for i, c in enumerate(backups, 1):
            print(f"{i}. {c['name']}：{c['local_dir']}")
        while True:
            choice = prompt('选择默认网站备份任务编号', '1')
            if choice.isdigit() and 1 <= int(choice) <= len(backups):
                selected = backups[int(choice)-1]
                break
            print('编号无效')
    default = selected['local_dir'] if selected else None
    while True:
        text = prompt('本地备份读取路径（可手动修改）', default)
        try:
            local = local_path(text)
            break
        except ValueError as ex:
            print(str(ex))
    matching = [c for c in backups if Path(c['local_dir']).resolve() == local]
    if len(matching) == 1:
        selected = matching[0]
    elif matching:
        raise ValueError('所选目录对应多个备份任务，请使用独立备份目录')
    elif selected is None:
        raise ValueError('没有可继承命名规则的网站备份任务，请先添加1号任务')
    rule = selected.get('backup_prefix')
    print('自动复用备份命名规则：' + (rule + '-xxxx-xx-xx-xxxxxx.tar.gz' if rule else 'web_时间戳.tar.gz'))
    return local, rule


def transfer_local(backup_prefix, label_title=None):
    if label_title:
        print(label_title)
    # 仅用注册表里的备份目录，不搜索其他位置。
    choices = list(dict.fromkeys(c['local_dir'] for _, c in configs()
                                if c.get('mode', 'backup') == 'backup' and c.get('backup_prefix') == backup_prefix))
    default = '/home/备份/' + backup_prefix + '/'
    if len(choices) == 1: default = choices[0]
    elif choices:
        for i, directory in enumerate(choices, 1): print(f'{i}. {directory}/')
        while True:
            selected = prompt('选择默认备份目录编号', '1')
            if selected.isdigit() and 1 <= int(selected) <= len(choices):
                default = choices[int(selected)-1]; break
            print('编号无效')
    while True:
        label = f'（回车默认已有网站备份{default.rstrip("/")}/）: ' if default else '（请手动指定本地备份目录）: '
        text = input(label)
        if not text and default: text = default
        try: return local_path(text)
        except ValueError as e: print(str(e))


def worker_unit():
    return ('[Unit]\nDescription=Named website archive transfer watcher\nAfter=network.target\n'
            '[Service]\nType=simple\nUser=root\nUMask=0077\nExecStart=/usr/bin/python3 '
            + str(ENGINE) + ' watch\nRestart=always\nRestartSec=3\n'
            '[Install]\nWantedBy=multi-user.target\n')


def reconcile_worker():
    enabled = any(c.get('mode') == 'transfer' for _, c in configs())
    # 不持有任何任务run.lock，避免stop等待任务锁。
    if not enabled and not SERVICE_FILE.exists(): return
    private_root()
    with lock(ROOT / '.worker-repair.lock'):
        if enabled:
            expected = worker_unit()
            if SERVICE_FILE.is_symlink(): raise ValueError('worker unit不能是符号链接')
            if not SERVICE_FILE.exists() or SERVICE_FILE.read_text() != expected:
                SERVICE_FILE.write_text(expected); SERVICE_FILE.chmod(0o644)
                if SERVICE_FILE.read_text() != expected: raise RuntimeError('worker unit readback失败')
                call(['systemctl', 'daemon-reload'], capture_output=True)
                call(['systemctl', 'restart', SERVICE], capture_output=True)
            call(['systemctl', 'enable', '--now', SERVICE], capture_output=True)
            heartbeat = ROOT / '.transfer-heartbeat.json'
            if heartbeat.exists():
                try: stale = time.time() - json.loads(heartbeat.read_text())['epoch'] > 120
                except (OSError, ValueError, KeyError, TypeError): stale = True
                if stale: call(['systemctl', 'restart', SERVICE], capture_output=True)
            call(['systemctl', 'is-enabled', SERVICE], capture_output=True)
            call(['systemctl', 'is-active', SERVICE], capture_output=True)
        else:
            call(['systemctl', 'disable', '--now', SERVICE], capture_output=True)
            for verb in ('is-active', 'is-enabled'):
                r = subprocess.run(['systemctl', verb, SERVICE], capture_output=True, timeout=15)
                if r.returncode == 0: raise RuntimeError('worker未停止/禁用')


def latest_archive(local, c):
    archive_pattern(c)  # validate even when directory is empty
    if not local.exists(): return None
    files = [p for p in local.iterdir() if archive_sort_key(p.name, c) is not None
             and not p.is_symlink() and p.is_file()]
    return max(files, key=lambda p: archive_sort_key(p.name, c), default=None)


def signature(p):
    st = p.stat()
    return [p.name, st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]


def checked_checksum(p):
    before = signature(p)
    digest = hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
    # 消耗gzip到EOF校验CRC，同时读遍tar每个成员；不创建或解压任何归档。
    with tarfile.open(p, 'r:gz') as archive:
        for member in archive:
            if member.isfile():
                data = archive.extractfile(member)
                if data:
                    while data.read(1024 * 1024): pass
    with gzip.open(p, 'rb') as data:
        while data.read(1024 * 1024): pass
    if signature(p) != before: raise ValueError('归档校验期间变化')
    return digest.hexdigest()


def upload_existing(task, c, p):
    if archive_sort_key(p.name, c) is None: raise ValueError('归档不属于本任务前缀')
    known = task / 'known_hosts'
    if not known.is_file() or not known.stat().st_size: raise ValueError('SSH未验证，未传送')
    options = ssh_args(task, c)
    destination = c.get('user', 'root') + '@' + c['host']
    remote = remote_path(c['remote_dir'])
    auth_call(['ssh'] + options + [destination, 'mkdir -p -- ' + shlex.quote(remote)], c)
    target = posixpath.join(remote, p.name)
    staging = target + '.partial-' + uuid.uuid4().hex
    command = ('umask 077; t=' + shlex.quote(staging) + '; trap \'rm -f -- "$t"\' EXIT; '
               'cat > "$t" && mv -- "$t" ' + shlex.quote(target))
    with p.open('rb') as data: auth_call(['ssh'] + options + [destination, command], c, stdin=data)


def transfer_tick(task, c, now=None, force=False):
    now = time.time() if now is None else now
    path = task / 'transfer-state.json'
    state = json.loads(path.read_text()) if path.exists() else {}
    p = latest_archive(local_path(c['local_dir']), c)
    if p is None: return
    sig = signature(p)
    if state.get('observed') != sig:
        state.update(observed=sig, changed_at=now)
        atomic_json(path, state)
        return  # 手动执行同样等待静默，不发送写入中的文件
    if state.get('validated') == sig and state.get('done') == [p.name, state.get('checksum')]:
        return  # 已成功传送的最新归档：纯本地判断，不校验、不写状态、不连接SSH。
    if now - state['changed_at'] < c.get('quiet_seconds', 5): return
    try:
        checksum = state.get('checksum') if state.get('validated') == sig else checked_checksum(p)
    except (OSError, ValueError, tarfile.TarError, EOFError): return
    if signature(p) != sig or latest_archive(p.parent, c) != p: return
    state.update(validated=sig, checksum=checksum)
    identity = [p.name, checksum]
    if state.get('identity') != identity:
        state.update(identity=identity, attempts=0, next_attempt=0)
    if state.get('done') == identity:
        atomic_json(path, state); return
    current_slot = slot(c, now)
    fallback = (state.get('attempts', 0) >= c.get('retries', 3) and
                current_slot is not None and current_slot > state.get('fallback_slot', -1))
    normal = state.get('attempts', 0) < c.get('retries', 3) and now >= state.get('next_attempt', 0)
    if not (normal or fallback):
        atomic_json(path, state); return
    if fallback: state['fallback_slot'] = current_slot
    if normal: state['attempts'] = state.get('attempts', 0) + 1
    state['next_attempt'] = now + c.get('retry_seconds', 60)
    # 尝试前持久化，进程异常也不会产生无限重试。
    atomic_json(path, state)
    try:
        (s3_module().upload_existing if c.get('mode') == 's3' else upload_existing)(task, c, p)
        if signature(p) != sig: return
    except (OSError, ValueError, subprocess.SubprocessError): return
    state['done'] = identity
    state['completed_at'] = now
    atomic_json(path, state)


def transfer_once(identifier):
    task = task_by_id(identifier)
    try:
        with lock(task / 'run.lock', blocking=False):
            c = load_task(task)
            if c.get('mode') == 'transfer': transfer_tick(task, c)
    except (BlockingIOError, FileNotFoundError): pass
    except Exception:
        print(identifier + ': 传送监控失败（未输出配置或凭据）', file=sys.stderr)


def watch():
    private_root()
    with lock(ROOT / '.transfer-worker.lock', blocking=False):
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            pending = {}
            while True:
                rows = [(t, c) for t, c in configs() if c.get('mode') == 'transfer']
                if not rows: return
                atomic_json(ROOT / '.transfer-heartbeat.json', {'epoch': int(time.time()), 'pid': os.getpid()})
                for task, _ in rows:
                    if task.name not in pending or pending[task.name].done():
                        pending[task.name] = pool.submit(transfer_once, task.name)
                time.sleep(1)


def dispatch_check():
    # cron只启动独立backup进程，不等待打包、SSH或其他任务。
    for task, c in configs():
        if c.get('mode', 'backup') == 'backup':
            subprocess.Popen(['/usr/bin/python3', str(ENGINE), 'scheduled-run', task.name],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    if any(c.get('mode') == 'transfer' for _, c in configs()): reconcile_worker()
    if any(c.get('mode') == 's3' for _, c in configs()): s3_module().repair(sys.modules[__name__])


def create(mode="backup"):
    name = prompt('任务名称').strip()
    if not name or len(name) > 80 or '/' in name or '\\' in name or name in ('.', '..') or any(ord(c) < 32 for c in name):
        raise ValueError('任务名不能为空/不能含控制字符，最多80字符')
    task_id = name if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', name) else 'task-' + uuid.uuid4().hex
    if mode == 'transfer':
        task_id = 'transfer-' + name if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,54}', name) else 'transfer-' + uuid.uuid4().hex
    host = prompt('远程服务器 IP 或域名').strip()
    validate_host(host)
    user = prompt('SSH 用户', 'root').strip()
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_-]*', user): raise ValueError('SSH用户名无效')
    port = prompt('SSH 端口', '22').strip()
    if not port.isdigit() or not 1 <= int(port) <= 65535: raise ValueError('SSH端口无效')
    auth = prompt('认证方式：1. 私钥  2. 密码', '1').strip()
    if auth not in ('1', '2'): raise ValueError('认证方式无效')
    password = None; key = None
    if auth == '1':
        key = str(Path(prompt('SSH 私钥路径', '/root/.ssh/id_ed25519')).expanduser().resolve())
        if not Path(key).is_file(): raise ValueError('SSH私钥不存在')
    else:
        print('无人值守需要本地保存密码：单独文件、root所有、0600；不是加密存储。')
        if prompt('确认保存密码请输入 yes') != 'yes': return
        password = getpass.getpass('远程服务器密码（隐藏输入）: ')
        if not password or len(password.encode()) > 4096 or any(c in password for c in '\n\r\0'):
            raise ValueError('密码不能为空/含换行或NUL/超过4096字节')
    interval = prompt('间隔仅支持 1h/2h/4h/6h/12h/1d/2d/3d/5d/7d', '2d').strip()
    while interval not in INTERVALS:
        print('不支持的间隔，仅支持 1h/2h/4h/6h/12h/1d/2d/3d/5d/7d')
        interval = input('请输入完整间隔（例如：2d）: ').strip()
    if interval.endswith('h'):
        h = '0'
        print('小时周期按UTC整点对齐，例如2h为00、02、04等小时。')
    else:
        h = prompt('几点 0-23，UTC', '5')
    m = prompt('几分 0-59', '0')
    if not re.fullmatch(r'\d{1,2}', h) or not 0 <= int(h) <= 23: raise ValueError('小时无效')
    if not re.fullmatch(r'\d{1,2}', m) or not 0 <= int(m) <= 59: raise ValueError('分钟无效')
    if mode == 'transfer':
        local, backup_prefix = transfer_source()
    else:
        backup_prefix = backup_prefix_prompt()
        local = backup_local(backup_prefix)
    remote = remote_path(prompt('远程目录', str(local)))
    retention_text = '3' if mode == 'transfer' else prompt('本地保留备份数量', '3').strip()
    while not retention_text.isdigit() or not 1 <= int(retention_text) <= 100000:
        print('保留数量必须为 1~100000 的整数')
        retention_text = prompt('本地保留备份数量', '3').strip()
    retention = int(retention_text)
    quiet = retry_delay = retries = None
    suffix = '-chuansong' if mode == 'transfer' else ''
    if mode == 'transfer':
        quiet = positive_prompt('文件静默秒数', 5)
        retry_delay = positive_prompt('失败重试间隔秒数', 60)
        retries = positive_prompt('总尝试次数（包含首次）', 3)
        print('仅扫描选中目录第一层最新归档；不打包、不清理本地。定时为额外兜底，时区UTC。')
    else:
        print('网站保持运行：热备不能保证数据库/正在写入文件的一致性；tar 失败不会上传或清理。')
        print(f'本地专用目录成功上传后保留最新{retention}个备份。')
    print(str(local / (name + suffix + '.sh')) + '，权限0700，明文保存；依赖共享engine和任务注册表。')
    if password is not None: print(str(local / (name + suffix + '.password')) + '，权限0600，明文密码文件。')
    if prompt('确认专用目录并保存任务，输入 yes') != 'yes':
        print('已取消'); return
    private_root()
    with lock(ROOT / '.scheduler.lock'), contextlib.ExitStack() as task_locks:
        task = ROOT / task_id
        if task.is_symlink(): raise ValueError('任务路径不能是符号链接')
        if task.exists():
            if not task.is_dir() or any(p.name != 'run.lock' for p in task.iterdir()):
                raise ValueError('任务配置或未知文件仍存在，拒绝覆盖')
            task_locks.enter_context(lock(task / 'run.lock', blocking=False))
        for _, c in configs():
            other = Path(c['local_dir']).resolve()
            if mode == 'backup' and c.get('mode', 'backup') == 'backup' and (local == other or local in other.parents or other in local.parents):
                raise ValueError('目录与其他任务重叠')
        if local.exists() and (not local.is_dir() or (mode == 'backup' and any(
                x.is_symlink() or not x.is_file() or not (archive_pattern({'backup_prefix': backup_prefix}).fullmatch(x.name) or
                    (x.name == '.beifen-web-owner' and x.read_text().strip() == task_id))
                for x in local.iterdir()))):
            raise ValueError('专用目录必须为空；拒绝接管已有备份/其他任务目录')
        local.mkdir(parents=True, exist_ok=True, mode=0o700)
        script_candidate = local / (name + suffix + '.sh')
        secret_candidate = local / (name + suffix + '.password')
        if script_candidate.exists() or script_candidate.is_symlink() or secret_candidate.exists() or secret_candidate.is_symlink():
            raise ValueError('任务脚本或密码路径已存在，拒绝覆盖')
        task.mkdir(mode=0o700, exist_ok=True)
        marker = local / '.beifen-web-owner'
        try:
            if mode == 'backup':
                if not marker.exists():
                    with marker.open('x') as f: f.write(task_id + '\n')
                marker.chmod(0o600)
            config = dict(id=task_id, name=name, host=host, user=user, port=int(port), auth='key' if auth=='1' else 'password', key=key,
                          interval=interval, interval_seconds=INTERVALS[interval],
                          hour=int(h), minute=int(m), anchor_epoch=schedule_anchor(interval, int(h), int(m)),
                          local_dir=str(local), remote_dir=remote, retention=retention)
            config['mode'] = mode
            if backup_prefix is not None: config['backup_prefix'] = backup_prefix
            config['schedule_version'] = 2
            if mode == 'transfer': config.update(quiet_seconds=quiet, retry_seconds=retry_delay, retries=retries)
            script = local / (name + suffix + '.sh')
            content = '#!/bin/bash\n# BEIFEN_CONFIG ' + json.dumps(config, ensure_ascii=False) + '\nexec /usr/bin/python3 ' + shlex.quote(str(ENGINE)) + ' run ' + shlex.quote(task_id) + '\n'
            with script.open('x') as f: f.write(content)
            script.chmod(0o700)
            if password is not None:
                secret = local / (name + suffix + '.password')
                fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'w') as f: f.write(password + '\n')
                config['password_file'] = str(secret)
                content = '#!/bin/bash\n# BEIFEN_CONFIG ' + json.dumps(config, ensure_ascii=False) + '\nexec /usr/bin/python3 ' + shlex.quote(str(ENGINE)) + ' run ' + shlex.quote(task_id) + '\n'
                script.write_text(content)
            atomic_json(task / 'location.json', {'local_dir': str(local), 'config_file': script.name})
        except BaseException:
            if mode == 'backup': marker.unlink(missing_ok=True)
            raise
    print('任务已保存: ' + task_id + '（SSH 尚未验证；请在菜单8选择任务核对指纹后执行）')
    print('首个锚点(UTC): ' + dt.datetime.fromtimestamp(config['anchor_epoch'], dt.timezone.utc).isoformat())
    reconcile_cron()
    reconcile_worker()


def task_by_id(identifier):
    identifier = identifier.removeprefix('new:')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', identifier): raise ValueError('任务 ID 无效')
    p = ROOT / identifier
    if p.is_symlink(): raise ValueError('任务不能是符号链接')
    return p


def load_task(task):
    p = config_path(task)
    if p.is_symlink(): raise ValueError('配置不能是符号链接')
    c = read_config(p)
    if c['id'] != task.name: raise ValueError('任务ID不一致')
    archive_pattern(c)
    if c.get('mode') == 's3': s3_module().validate(c)
    else: validate_host(c['host'])
    if c['interval_seconds'] != INTERVALS[c['interval']]: raise ValueError('间隔配置不一致')
    if not isinstance(c.get('retention', 3), int) or not 1 <= c.get('retention', 3) <= 100000:
        raise ValueError('本地保留数量无效')
    return c


def validate_host(host):
    if not host or host.startswith('-') or not re.fullmatch(r'[A-Za-z0-9_.:-]+', host):
        raise ValueError('SSH主机无效')


def auth_call(args, c, **kwargs):
    timeout = kwargs.pop('timeout', 1800)
    if c.get('auth', 'password') == 'key':
        return call(args, timeout=timeout, **kwargs)
    if c.get('password_file'):
        fd = os.open(c['password_file'], os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(fd)
            if st.st_mode & 0o077: raise ValueError('密码文件权限必须0600')
            return call(['sshpass', '-d', str(fd)] + args, pass_fds=(fd,), timeout=timeout, **kwargs)
        finally: os.close(fd)
    return password_call(args, c['password'], timeout=timeout, **kwargs)


def ssh_args(task, c):
    args = ['-p', str(c.get('port', 22)), '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=' + str(task / 'known_hosts'),
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=15',
            '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=2', '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'BatchMode=' + ('yes' if c.get('auth')=='key' else 'no')]
    if c.get('auth') == 'key':
        args += ['-i', c['key'], '-o', 'PreferredAuthentications=publickey']
    else:
        args += ['-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no']
    return args


def password_call(args, password, **kwargs):
    timeout = kwargs.pop('timeout', 1800)
    r, w = os.pipe()
    try:
        os.write(w, (password + '\n').encode()); os.close(w); w = None
        # 密码仅通过继承的 fd；不进 argv/env/日志。
        call(['sshpass', '-d', str(r)] + args, pass_fds=(r,), timeout=timeout, **kwargs)
    finally:
        os.close(r)
        if w is not None: os.close(w)


def archive_and_transfer(task, c):
    local = local_path(c['local_dir']); remote = remote_path(c['remote_dir'])
    if (local / '.beifen-web-owner').read_text().strip() != c['id']:
        raise ValueError('备份目录所有权标记不一致，拒绝运行/清理')
    if not (task / 'known_hosts').is_file() or not (task / 'known_hosts').stat().st_size:
        raise ValueError('SSH 未信任，请先核对指纹并运行 trust；未备份/传送')
    print('热备：不停网站，数据库/活跃文件一致性不保证。', flush=True)
    fd, temporary = tempfile.mkstemp(prefix='.web-', suffix='.partial', dir=local)
    os.close(fd)
    # Reserve final name atomically; same-second collisions wait for next second.
    name = archive_name(c)
    final = local / name
    try:
        args = ['tar', '-czf', temporary]
        # 任务配置含明文密码，不能随 web 归档上传；锁/state 同样排除。
        try:
            rel = ROOT.resolve().relative_to(SOURCE.resolve())
            args += ['--exclude=web/' + str(rel)]
        except ValueError: pass
        args += ['-C', str(SOURCE.parent), SOURCE.name]
        call(args, timeout=7200)
        with open(temporary, 'rb') as f: os.fsync(f.fileno())
        while True:
            try:
                os.link(temporary, final)
                break
            except FileExistsError:
                time.sleep(1)
                name = archive_name(c)
                final = local / name
        os.unlink(temporary)
        options = ssh_args(task, c)
        destination = c.get('user', 'root') + '@' + c['host']
        auth_call(['ssh'] + options + [destination, 'mkdir -p -- ' + shlex.quote(remote)], c)
        # 使用 SSH stdin + 远端原子发布，避免 scp 的 shell/SFTP 路径引号差异。
        target = posixpath.join(remote, name)
        staging = target + '.partial-' + uuid.uuid4().hex
        command = ('umask 077; t=' + shlex.quote(staging) + '; trap \'rm -f -- "$t"\' EXIT; '
                   'cat > "$t" && mv -- "$t" ' + shlex.quote(target))
        with final.open('rb') as data:
            auth_call(['ssh'] + options + [destination, command], c, stdin=data)
        # 仅该任务专用目录下的正规本任务命名归档；不触及其他 tar.gz。
        files = [p for p in local.iterdir() if archive_sort_key(p.name, c) is not None
                 and p.is_file() and not p.is_symlink()]
        for p in sorted(files, key=lambda p: archive_sort_key(p.name, c), reverse=True)[int(c.get('retention', 3)):]: p.unlink()
        print('本次已上传: ' + str(final))
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def run_new(identifier, scheduled=False, now=None):
    task = task_by_id(identifier)
    with lock(task / 'run.lock', blocking=not scheduled):
        c = load_task(task)
        state = task / 'state.json'
        current = time.time() if now is None else now
        if scheduled and c.get('mode', 'backup') != 'backup': return
        if scheduled:
            s = slot(c, current)
            if s is None: return
            old = json.loads(state.read_text()) if state.exists() else {}
            if old.get('last_attempt_slot', -1) >= s: return
            # 每个 anchor slot 最多尝试一次；错过多个周期只补执行一次，不累计风暴。
            atomic_json(state, dict(last_attempt_slot=s, attempted_at=int(current)))
        if c.get('mode', 'backup') in ('transfer', 's3'):
            if scheduled: return  # 传送只由worker进行，绝不能走archive_and_transfer
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                transfer_tick(task, c, force=True)
                state_path = task / 'transfer-state.json'
                observed = json.loads(state_path.read_text()) if state_path.exists() else {}
                if observed.get('validated') == observed.get('observed') and observed.get('validated'):
                    print('最新归档已处理；完成/重试状态已持久化，失败由worker继续处理。')
                    return
                time.sleep(1)
            raise ValueError('归档持续变化或校验失败，未传送；worker继续监控')
        elif c.get('mode', 'backup') == 'backup':
            archive_and_transfer(task, c)
        else: raise ValueError('未知任务模式，拒绝归档')


def legacy_entries():
    entries = []
    for line in read_cron().splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        try: tokens = shlex.split(line)
        except ValueError: continue
        for p in LEGACY:
            if str(p) in tokens:
                ident = 'legacy:' + hashlib.sha256(line.encode()).hexdigest()
                if not any(e['id'] == ident for e in entries):
                    entries.append(dict(id=ident, name=str(p), kind='legacy', path=p, line=line))
                break
    return entries


def entries():
    rows = [dict(id='new:' + c['id'], name=c['name'], kind='new', config=c)
            for _, c in configs()] + legacy_entries()
    return sorted(rows, key=lambda row: {'backup': 0, 'transfer': 1, 's3': 2}.get(task_group(row), 3))


def listing(rows):
    for n, e in enumerate(rows, 1):
        desc = e['config']['interval'] + (' / S3' if task_group(e) == 's3' else ' / SSH') if e['kind'] == 'new' else '旧任务，保持原行为'
        print(f"{n}. {e['name']} [{e['id']}] {desc}")
    if not rows: print('没有网站任务')


def find_legacy(identifier):
    for e in legacy_entries():
        if e['id'] == identifier: return e
    raise ValueError('旧任务已改变/不存在，请重新选择')


def run(identifier):
    if identifier.startswith('legacy:'):
        e = find_legacy(identifier)
        call([str(e['path'])], timeout=7200)  # .x 直接运行，不交给 bash
    else: run_new(identifier)


def delete(identifier):
    if prompt('仅删除选中任务及凭据（保留本地归档/锁），输入 yes') != 'yes': return
    private_root()
    if identifier.startswith('legacy:'):
        with lock(ROOT / '.scheduler.lock'):
            e = find_legacy(identifier)
            before = read_cron(); lines = before.splitlines(keepends=True)
            for i, line in enumerate(lines):
                if line.rstrip('\r\n') == e['line']: del lines[i]; break
            after = ''.join(lines); write_cron(after)
            # 仅当此白名单脚本不再被 cron 引用时删除；不处理 systemd。
            if not any(str(e['path']) in shlex.split(l) for l in after.splitlines() if l and not l.startswith('#')):
                e['path'].unlink(missing_ok=True)
                if e['path'].suffix == '.sh':
                    Path(str(e['path']) + '.conf').unlink(missing_ok=True)
                    e['path'].with_suffix('.payload.sh').unlink(missing_ok=True)
    else:
        task = task_by_id(identifier)
        with lock(task / 'run.lock'):
            c = load_task(task)
            if c.get('mode') == 's3':
                secret = Path(c['credential_file'])
                if secret != config_path(task).with_suffix('.credentials'):
                    raise ValueError('S3凭据路径异常，拒绝删除')
                secret.unlink(missing_ok=True)
            if c.get('password_file'):
                secret = Path(c['password_file'])
                if secret == config_path(task).with_suffix('.password'): secret.unlink(missing_ok=True)
            # 留存目录和锁，避免删除后 inode 分叉；无需卸载归档。
            actual = config_path(task)
            actual.unlink(missing_ok=True)
            if c.get('mode', 'backup') == 'backup':
                owner = Path(c['local_dir']) / '.beifen-web-owner'
                if owner.is_file() and not owner.is_symlink() and owner.read_text().strip() == c['id']:
                    owner.unlink()
            for name in ('config.json', 'location.json', 'state.json', 'transfer-state.json', 'known_hosts'):
                (task / name).unlink(missing_ok=True)
        reconcile_cron()
        reconcile_worker()  # 已释放run.lock，停止worker不会死锁
        s3_module().repair(sys.modules[__name__])
    print('选中任务已删除；调度 readback 完成，旧任务服务未停止/迁移')


def trust(identifier):
    task = task_by_id(identifier)
    with lock(task / 'run.lock'):
        c = load_task(task)
        if c.get('mode') == 's3': raise ValueError('S3不使用SSH信任')
        scan = call(['ssh-keyscan', '-T', '10', '-p', str(c.get('port', 22)), c['host']], capture_output=True, timeout=30)
        if not scan.stdout.strip(): raise ValueError('没有收到主机公钥')
        fd, tmp = tempfile.mkstemp(prefix='.hosts-', dir=task)
        try:
            with os.fdopen(fd, 'wb') as f: f.write(scan.stdout)
            call(['ssh-keygen', '-lf', tmp], timeout=15)
            print('ssh-keyscan 本身不可信！必须通过服务器控制台/可信渠道核对上述指纹。')
            if prompt('已独立核对指纹，输入 yes') != 'yes': return
            os.replace(tmp, task / 'known_hosts')
            print('首次信任已保存；后续严格匹配主机密钥，不自动接受变更')
        finally:
            if os.path.exists(tmp): os.unlink(tmp)


def task_group(row):
    if row['kind'] == 'legacy' and 'chuansong' in str(row['path']):
        return 'transfer'
    return row.get('config', {}).get('mode', 'backup')


def connection_cache_path():
    token = os.environ.get('WEB_CONNECTION_SESSION', 'default')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', token): raise ValueError('连接缓存ID无效')
    return ROOT / ('.connection-' + token + '.json')


def cached_connections():
    try: return json.loads(connection_cache_path().read_text()).get('results', {})
    except (OSError, ValueError): return {}


def probe_row(row):
    if row['kind'] == 'legacy': return 'unknown'
    task = task_by_id(row['id'])
    try:
        c = load_task(task)
        if c.get('mode') == 's3':
            result = call(['/usr/bin/python3', str(ENGINE), 'probe-s3', c['id']], capture_output=True, text=True, timeout=6)
            status = result.stdout.strip()
            return status if status in ('ok', 'failed', 'unknown') else 'unknown'
        known = task / 'known_hosts'
        if not known.is_file() or not known.stat().st_size: return 'unknown'
        options = ssh_args(task, c)
        options = ['ConnectTimeout=2' if x == 'ConnectTimeout=15' else x for x in options]
        auth_call(['ssh'] + options + [c.get('user', 'root') + '@' + c['host'], 'true'],
                  c, timeout=5, capture_output=True)
        return 'ok'
    except subprocess.TimeoutExpired: return 'unknown'
    except subprocess.CalledProcessError: return 'failed'
    except Exception: return 'unknown'


def probe_cache(rows=None):
    rows = entries() if rows is None else rows
    result = cached_connections()
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        for row, status in zip(rows, pool.map(probe_row, rows)): result[row['id']] = status
    private_root()
    atomic_json(connection_cache_path(), {'epoch': int(time.time()), 'results': result})
    return result


def connection_label(status):
    return {'ok': '\033[32m连接正常\033[0m', 'failed': '\033[31m连接失败\033[0m'}.get(status, '\033[33m检测异常\033[0m')


def menu_summary(count_only=False):
    rows = entries()
    if count_only:
        print(f'\033[32m已有 {len(rows)} 个\033[0m' if rows else '\033[31m暂无\033[0m')
        return
    connections = cached_connections()  # redraw never initiates a network probe
    for group, title in [('backup', '备份任务'), ('transfer', '备份传送'), ('s3', 'S3 API 兼容传送任务')]:
        print(title)
        print('备注名   状态')
        selected = [(i, r) for i, r in enumerate(rows, 1) if task_group(r) == group]
        if not selected: print('\033[31m暂无\033[0m')
        for index, row in selected:
            if row['kind'] == 'new':
                c = row['config']
                unit = '天' if c['interval'].endswith('d') else '小时'
                action = '备份' if group == 'backup' else '传送'
                known = task_by_id(row['id']) / 'known_hosts'
                verified = connections.get(row['id']) == 'ok' if group == 's3' else known.is_file() and known.stat().st_size > 0
                state = '\033[32m已验证\033[0m' if verified else '\033[31m未验证\033[0m'
                name = ''.join(x for x in row['name'] if x.isprintable())
                timing = (f"每 {c['interval'][:-1]} 小时第 {c['minute']} 分" if c['interval'].endswith('h')
                          else f"每 {c['interval'][:-1]} 天 {c['hour']}点 {c['minute']}分")
                print(f"{index}. {name}   {connection_label(connections.get(row['id']))} {timing}{action}（{state}）")
            else:
                print(f"{index}. {row['name']}   {connection_label('unknown')} 旧任务（原定时规则；\033[31m未验证\033[0m）")
        if group != 's3': print('------------------------')


def select_test():
    rows = entries()
    listing(rows)
    if not rows: return
    choice = input('选择任务编号（回车全部测试 0 取消）: ').strip()
    if choice == '0': return
    if choice:
        if not choice.isdigit() or not 1 <= int(choice) <= len(rows): raise ValueError('编号无效')
        rows = [rows[int(choice)-1]]
    for row in rows:
        if row['kind'] != 'new' or task_group(row) == 's3': continue
        known = task_by_id(row['id']) / 'known_hosts'
        if not known.is_file() or not known.stat().st_size:
            print(row['name'] + '：未验证，需先核对主机指纹')
            trust(row['id'])
    result = probe_cache(rows)
    for row in rows: print(row['name'] + '：' + connection_label(result.get(row['id'])))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['create','list','run','delete','select-run','select-delete','check','trust','install-cron','summary','count','select-test','create-transfer','watch','scheduled-run','create-s3','watch-s3','probe','probe-s3'])
    parser.add_argument('id', nargs='?')
    a = parser.parse_args()
    if a.command == 'create': create()
    elif a.command == 'create-transfer': create('transfer')
    elif a.command == 'create-s3': s3_module().create(sys.modules[__name__])
    elif a.command == 'watch-s3': s3_module().watch(sys.modules[__name__])
    elif a.command == 'probe': probe_cache()
    elif a.command == 'probe-s3':
        if not a.id: parser.error('必须指定任务ID')
        print(s3_module().probe(load_task(task_by_id(a.id))))
    elif a.command == 'watch': watch()
    elif a.command == 'scheduled-run':
        if not a.id: parser.error('必须指定任务 ID')
        try: run_new(a.id, scheduled=True)
        except BlockingIOError: pass
    elif a.command == 'list': listing(entries())
    elif a.command == 'summary': menu_summary()
    elif a.command == 'select-test': select_test()
    elif a.command == 'count': menu_summary(True)
    elif a.command in ('select-run', 'select-delete'):
        rows = entries(); listing(rows)
        if not rows: return
        n = prompt('选择任务编号（0取消）')
        if n == '0': return
        if not n.isdigit() or not 1 <= int(n) <= len(rows): raise ValueError('编号无效')
        selected = rows[int(n)-1]['id']
        if a.command == 'select-run' and not selected.startswith('legacy:') and task_group(rows[int(n)-1]) != 's3':
            task = task_by_id(selected)
            if not (task / 'known_hosts').is_file():
                print('此任务尚未验证 SSH 主机，先核对并确认指纹。')
                trust(selected)
                if not (task / 'known_hosts').is_file():
                    print('未确认主机指纹，已取消执行。')
                    return
        (run if a.command == 'select-run' else delete)(selected)
    elif a.command == 'check': dispatch_check()
    elif a.command == 'install-cron':
        reconcile_cron()
        reconcile_worker()
        s3_module().repair(sys.modules[__name__])
    else:
        if not a.id: parser.error('必须指定任务 ID')
        {'run': run, 'delete': delete, 'trust': trust}[a.command](a.id)


if __name__ == '__main__':
    try: main()
    except (Exception, KeyboardInterrupt) as e:
        print('失败: ' + str(e), file=sys.stderr)
        sys.exit(1)
SINGLEFILE_SOURCE_BEIFENHEBING_WEB_PY
# SINGLEFILE_HELPER beifenhebing-web-s3.py SINGLEFILE_SOURCE_BEIFENHEBING_WEB_S3_PY
    cat <<'SINGLEFILE_SOURCE_BEIFENHEBING_WEB_S3_PY'
#!/usr/bin/env python3
"""Named website S3 transfer: latest only, independent credentials and worker."""
import concurrent.futures
import getpass
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid
from urllib.parse import urlparse

S3_MULTIPART_THRESHOLD_MB = 8
S3_MULTIPART_CHUNK_MB = 8
S3_UPLOAD_CONCURRENCY = 2
SERVICE = 'beifenhebing-web-s3.service'
SERVICE_FILE = Path('/etc/systemd/system') / SERVICE
ENGINE = Path('/root/yingyong/beifenhebing-web.py')


def engine():
    spec = importlib.util.spec_from_file_location('web_engine_s3', ENGINE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalize_endpoint(value):
    value = value.strip().rstrip('/')
    if '://' not in value: value = 'https://' + value
    p = urlparse(value)
    if (p.scheme != 'https' or not p.hostname or p.username or p.password or
            p.query or p.fragment or p.path or any(c.isspace() for c in value)):
        raise ValueError('Endpoint必须为HTTPS主机地址（可省略https://，可带结尾/）')
    try: p.port
    except ValueError: raise ValueError('Endpoint端口无效')
    return value


def normalize_prefix(value):
    value = value.strip().strip('/')
    if not value or any(c in value for c in '\r\n\0') or '..' in value.split('/'):
        raise ValueError('保存路径无效')
    return '/'.join(part for part in value.split('/') if part) + '/'


def repair_dependency():
    def available():
        return subprocess.run(['/usr/bin/python3', '-c', 'import boto3,botocore'],
                              capture_output=True, timeout=15).returncode == 0
    if available(): return
    if os.geteuid() != 0: raise ValueError('缺少python3-boto3，请以root安装')
    if shutil.which('apt-get'):
        subprocess.run(['apt-get', 'update', '-qq'], check=True, timeout=300)
        subprocess.run(['apt-get', 'install', '-y', '-qq', 'python3-boto3'], check=True, timeout=300)
    elif shutil.which('dnf'):
        subprocess.run(['dnf', 'install', '-y', '-q', 'python3-boto3'], check=True, timeout=300)
    else: raise ValueError('缺少python3-boto3，当前仅支持apt/dnf自动安装')
    if not available(): raise ValueError('python3-boto3安装后检查失败')


def validate(c):
    if c.get('mode') != 's3' or not c['id'].startswith('s3-'): raise ValueError('S3命名空间无效')
    if normalize_endpoint(c['endpoint']) != c['endpoint']: raise ValueError('Endpoint配置无效')
    if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', c['bucket']): raise ValueError('Bucket名称无效')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', c['region']): raise ValueError('Region无效')
    if c['style'] not in ('path', 'virtual'): raise ValueError('寻址方式无效')
    prefix = c['prefix']
    if not prefix or not prefix.endswith('/') or prefix.startswith('/') or '..' in prefix.split('/') or any(ord(x) < 32 for x in prefix):
        raise ValueError('S3前缀无效')
    if 'backup_prefix' in c: engine().validate_backup_prefix(c['backup_prefix'])
    if not isinstance(c['retention'], int) or not 1 <= c['retention'] <= 100000: raise ValueError('保留数量无效')


def client(c, check=False):
    import boto3
    from botocore.config import Config
    validate(c)
    expected = Path(c['local_dir']) / (c['name'] + '-s3.credentials')
    if Path(c['credential_file']) != expected: raise ValueError('凭据路径无效')
    fd = os.open(expected, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        if os.fstat(f.fileno()).st_mode & 0o077: raise ValueError('凭据权限必须0600')
        secret = json.load(f)
    return boto3.client('s3', endpoint_url=c['endpoint'], region_name=c['region'],
                        aws_access_key_id=secret['access'], aws_secret_access_key=secret['secret'],
                        config=Config(connect_timeout=2 if check else 8, read_timeout=2 if check else 60,
                                      retries={'max_attempts': 0}, s3={'addressing_style': c['style']}))


def ensure_bucket(s3, c):
    from botocore.exceptions import ClientError
    try: s3.head_bucket(Bucket=c['bucket'])
    except ClientError as e:
        # A permission-denied response is never evidence that a bucket is absent.
        status = e.response.get('ResponseMetadata', {}).get('HTTPStatusCode')
        code = str(e.response.get('Error', {}).get('Code', ''))
        if status == 403 or code in ('403', 'AccessDenied'): raise
        if status != 404 and code not in ('404', 'NoSuchBucket', 'NotFound'): raise
        args = {'Bucket': c['bucket']}
        if c['region'] != 'us-east-1': args['CreateBucketConfiguration'] = {'LocationConstraint': c['region']}
        s3.create_bucket(**args)
        s3.head_bucket(Bucket=c['bucket'])


def owned_objects(s3, c):
    e = engine()
    rows = []
    for page in s3.get_paginator('list_objects_v2').paginate(Bucket=c['bucket'], Prefix=c['prefix']):
        for item in page.get('Contents', []):
            key = item['Key']
            if key.startswith(c['prefix']) and e.archive_sort_key(key[len(c['prefix']):], c) is not None: rows.append(item)
    return sorted(rows, key=lambda x: e.archive_sort_key(x['Key'][len(c['prefix']):], c), reverse=True)


def upload_existing(task, c, p):
    try: return upload_verified(task, c, p)
    except Exception as ex:
        # Never expose credential-bearing SDK request URLs or provider messages.
        raise ValueError('S3上传/读回/清理未完成：' + type(ex).__name__) from None


def upload_verified(task, c, p):
    e = engine()
    if e.archive_sort_key(p.name, c) is None: raise ValueError('归档不属于本任务前缀')
    before = e.signature(p)
    checksum = e.checked_checksum(p)
    s3 = client(c)
    ensure_bucket(s3, c)
    key = c['prefix'] + p.name
    from boto3.s3.transfer import TransferConfig
    transfer_config = TransferConfig(multipart_threshold=S3_MULTIPART_THRESHOLD_MB * 1024 * 1024,
                                     multipart_chunksize=S3_MULTIPART_CHUNK_MB * 1024 * 1024,
                                     max_concurrency=S3_UPLOAD_CONCURRENCY, num_download_attempts=1)
    s3.upload_file(str(p), c['bucket'], key, ExtraArgs={'Metadata': {'sha256': checksum}}, Config=transfer_config)
    head = s3.head_object(Bucket=c['bucket'], Key=key)
    if head.get('ContentLength') != p.stat().st_size or head.get('Metadata', {}).get('sha256') != checksum:
        raise ValueError('远端元数据不匹配，未清理')
    body = s3.get_object(Bucket=c['bucket'], Key=key)['Body']
    digest = hashlib.sha256()
    try:
        while True:
            block = body.read(1024 * 1024)
            if not block: break
            digest.update(block)
    finally: body.close()
    if digest.hexdigest() != checksum or e.signature(p) != before or e.latest_archive(p.parent, c) != p:
        raise ValueError('远端真实读回校验失败或本地文件变化，未清理')
    for item in owned_objects(s3, c)[c['retention']:]:
        s3.delete_object(Bucket=c['bucket'], Key=item['Key'])
    if len(owned_objects(s3, c)) > c['retention']: raise ValueError('远端清理未完成')


def probe(c):
    try:
        client(c, check=True).head_bucket(Bucket=c['bucket'])  # read-only, NEVER create
        return 'ok'
    except Exception as ex:
        from botocore.exceptions import BotoCoreError, ClientError
        return 'failed' if isinstance(ex, (BotoCoreError, ClientError)) else 'unknown'


def create(e=None):
    e = e or engine()
    repair_dependency()
    name = e.prompt('任务备注名').strip()
    if not name or len(name) > 80 or name in ('.', '..') or any(x in name for x in '/\\') or any(ord(x) < 32 for x in name):
        raise ValueError('任务名无效')
    ident = 's3-' + name if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,59}', name) else 's3-' + uuid.uuid4().hex
    endpoint = normalize_endpoint(e.prompt('S3 API Endpoint（https://...）'))
    bucket = e.prompt('Bucket 名称').strip()
    region = e.prompt('Region', 'us-east-1').strip()
    style = e.prompt('寻址方式 1.path 2.virtual', '1').strip()
    if style not in ('1', '2'): raise ValueError('寻址方式无效')
    interval = e.prompt('间隔 1h/2h/4h/6h/12h/1d/2d/3d/5d/7d', '2d').strip()
    while interval not in e.INTERVALS: interval = e.prompt('请输入完整间隔（例如：2d）').strip()
    hour = 0 if interval.endswith('h') else int(e.prompt('几点 0-23，UTC', '5'))
    minute = int(e.prompt('几分 0-59', '0'))
    if not 0 <= hour <= 23 or not 0 <= minute <= 59: raise ValueError('时间无效')
    local, backup_prefix = e.transfer_source()
    default_prefix = '/备份/' + (backup_prefix or 'web')
    prefix_text = e.prompt('S3桶内保存路径（回车默认 ' + default_prefix + ' ）').strip()
    if not prefix_text: prefix_text = default_prefix
    while not prefix_text.strip('/'):
        prefix_text = e.prompt('S3桶内保存路径不能为空请重新输入（例如：/备份/备注名）').strip()
    prefix = normalize_prefix(prefix_text)
    retention = e.positive_prompt('远端保留数量', 3)
    c = dict(id=ident, name=name, mode='s3', endpoint=endpoint, bucket=bucket, region=region,
             style='path' if style == '1' else 'virtual', prefix=prefix, retention=retention,
             local_dir=str(local), credential_file=str(local / (name + '-s3.credentials')),
             interval=interval, interval_seconds=e.INTERVALS[interval], hour=hour, minute=minute,
             anchor_epoch=e.schedule_anchor(interval, hour, minute), schedule_version=2,
             quiet_seconds=e.positive_prompt('文件静默秒数', 5),
             retry_seconds=e.positive_prompt('失败重试间隔秒数', 60), retries=e.positive_prompt('总尝试次数（包含首次）', 3))
    if backup_prefix is not None: c['backup_prefix'] = backup_prefix
    validate(c)
    script = local / (name + '-s3.sh')
    print(str(script) + '，0700；独立凭据' + c['credential_file'] + '，0600，明文保存。')
    print('仅第一层最新web归档，不打包/不清本地。仅上传并真实读回SHA256成功后清理本前缀；应使用专用前缀。')
    print('仅Bucket404时创建；403不创建。版本化桶删除仅创建删除标记，不清理历史versions，需配置生命周期。')
    print('HTTPS严格校验；8MiB分片、并发2。超过10000分片时SDK自动扩大part，极大文件可能超过100MB代理限制。')
    print('Cloudflare橙云timeout/WAF仍可能失败，不保证100%通过；必要时使用DNS-only直连Endpoint。')
    if e.prompt('确认保存凭据并启用远端清理请输入 yes') != 'yes': return
    access = getpass.getpass('Access Key ID（隐藏输入）: ')
    secret = getpass.getpass('Secret Access Key（隐藏输入）: ')
    if not access or not secret: raise ValueError('凭据不能为空')
    save(e, c, {'access': access, 'secret': secret})
    e.reconcile_cron()
    repair(e)


def save(e, c, secret):
    validate(c)
    local = e.local_path(c['local_dir'])
    script = local / (c['name'] + '-s3.sh')
    credential = local / (c['name'] + '-s3.credentials')
    if str(credential) != c['credential_file']: raise ValueError('凭据路径无效')
    e.private_root()
    import contextlib
    with e.lock(e.ROOT / '.scheduler.lock'), contextlib.ExitStack() as held:
        task = e.task_by_id(c['id'])
        if task.is_symlink(): raise ValueError('任务路径不能是符号链接')
        if task.exists():
            if not task.is_dir() or any(p.name != 'run.lock' for p in task.iterdir()):
                raise ValueError('任务配置或未知文件仍存在，拒绝覆盖')
            held.enter_context(e.lock(task / 'run.lock', blocking=False))
        local.mkdir(parents=True, exist_ok=True, mode=0o700)
        if any(p.exists() or p.is_symlink() for p in (script, credential)): raise ValueError('配置路径已存在，拒绝覆盖')
        task.mkdir(mode=0o700, exist_ok=True)
        try:
            fd = os.open(credential, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as f: json.dump(secret, f)
            import shlex
            content = '#!/bin/bash\n# BEIFEN_CONFIG ' + json.dumps(c, ensure_ascii=False) + '\nexec /usr/bin/python3 ' + shlex.quote(str(e.ENGINE)) + ' run ' + shlex.quote(c['id']) + '\n'
            fd = os.open(script, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
            with os.fdopen(fd, 'w') as f: f.write(content)
            e.atomic_json(task / 'location.json', {'local_dir': str(local), 'config_file': script.name})
        except BaseException:
            script.unlink(missing_ok=True); credential.unlink(missing_ok=True)
            raise
    print('S3任务已保存（未发起连接）；定时兜底UTC，成功归档重启后也跳过。')


def worker_unit(e):
    return ('[Unit]\nDescription=Named website S3 latest archive watcher\nAfter=network.target\n'
            '[Service]\nType=simple\nUser=root\nUMask=0077\nExecStart=/usr/bin/python3 '
            + str(e.ENGINE) + ' watch-s3\nRestart=always\nRestartSec=3\n'
            '[Install]\nWantedBy=multi-user.target\n')


def repair(e=None):
    e = e or engine()
    enabled = any(c.get('mode') == 's3' for _, c in e.configs())
    if not enabled and not SERVICE_FILE.exists(): return
    if enabled: repair_dependency()
    e.private_root()
    with e.lock(e.ROOT / '.s3-worker-repair.lock'):
        if enabled:
            expected = worker_unit(e)
            if SERVICE_FILE.is_symlink(): raise ValueError('S3 unit不能是符号链接')
            if not SERVICE_FILE.exists() or SERVICE_FILE.read_text() != expected:
                SERVICE_FILE.write_text(expected); SERVICE_FILE.chmod(0o644)
                if SERVICE_FILE.read_text() != expected: raise ValueError('S3 unit readback失败')
                e.call(['systemctl', 'daemon-reload'], capture_output=True)
                e.call(['systemctl', 'restart', SERVICE], capture_output=True)
            e.call(['systemctl', 'enable', '--now', SERVICE], capture_output=True)
            heartbeat = e.ROOT / '.s3-heartbeat.json'
            if heartbeat.exists():
                try: stale = time.time() - json.loads(heartbeat.read_text())['epoch'] > 120
                except (ValueError, OSError, KeyError): stale = True
                if stale: e.call(['systemctl', 'restart', SERVICE], capture_output=True)
            for verb in ('is-enabled', 'is-active'): e.call(['systemctl', verb, SERVICE], capture_output=True)
        else:
            e.call(['systemctl', 'disable', '--now', SERVICE], capture_output=True)
            for verb in ('is-enabled', 'is-active'):
                r = subprocess.run(['systemctl', verb, SERVICE], capture_output=True, timeout=15)
                if r.returncode == 0: raise ValueError('S3 worker未停止/禁用')


def watch(e=None):
    e = e or engine()
    e.private_root()
    def once(ident):
        try:
            task = e.task_by_id(ident)
            with e.lock(task / 'run.lock', blocking=False):
                c = e.load_task(task)
                if c.get('mode') == 's3': e.transfer_tick(task, c)
        except (BlockingIOError, FileNotFoundError): pass
        except Exception: print('S3监控异常（未输出凭据）', file=__import__('sys').stderr)
    with e.lock(e.ROOT / '.s3-worker.lock', blocking=False):
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            pending = {}
            while True:
                rows = [(t, c) for t, c in e.configs() if c.get('mode') == 's3']
                if not rows: return
                e.atomic_json(e.ROOT / '.s3-heartbeat.json', {'epoch': int(time.time()), 'pid': os.getpid()})
                for task, _ in rows:
                    if task.name not in pending or pending[task.name].done(): pending[task.name] = pool.submit(once, task.name)
                time.sleep(1)
SINGLEFILE_SOURCE_BEIFENHEBING_WEB_S3_PY
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    singlefile_bootstrap || exit 1
    central_data_migrate || exit 1
    main "$@"
fi
