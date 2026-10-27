#!/usr/bin/env bash
# Backrest 独立管理脚本：自制/官方镜像共用实例，禁止隐式切换来源。
my_docker_img="zaixiangjian/backrest:latest"
app_base_dir="/home/docker/backrest"
docker_name="backrest"
host_port="9898"
container_port="9898"
# 备份输出目录；恢复仅查找下列目录的直接子文件，不递归。
BACKUP_DIR="/home/备份/backrest"
RESTORE_DIRS=("$BACKUP_DIR" "/home")
# 数据挂载：宿主机目录:容器目录；可添加多行，容器目录必须位于 /userdata/ 下。
# /home 包含 /home/备份，二者会重复可见；/root 可能含密钥，请谨慎选择备份范围。
DATA_MOUNTS=(
    "/home/备份:/userdata/home"
    "/home:/userdata/all-home"
    "/root:/userdata/root"
)

# 仅锁定实际操作，允许多个终端打开菜单。
br_operate() (
    command -v flock >/dev/null || { echo "❌ 缺少 flock（util-linux）。"; return 1; }
    [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行此操作。"; return 1; }
    # 生命周期操作与远程打包/归档轮转共用生产者锁，顺序固定为生产者锁→应用锁。
    case "$1" in
        br_install|br_update|br_backup|br_restore|br_uninstall)
            mkdir -p "$BACKUP_DIR/config" || return 1
            exec 6>"$BACKUP_DIR/config/backup.lock" || return 1
            flock -n 6 || { echo "❌ 备份或归档清理正在进行。"; return 1; }
            ;;
    esac
    exec 9>/run/lock/backrest-manager.lock || return 1
    flock -n 9 || { echo "❌ 另一项 Backrest 操作正在进行。"; return 1; }
    if [[ $1 != br_cloud_delete ]]; then
        sudo docker info >/dev/null 2>&1 || { echo "❌ Docker 不可用，请先安装并启动 Docker。"; return 1; }
    fi
    host_tz=$(br_timezone)
    "$@"
)

# 官方镜像来源：https://github.com/garethgeorge/backrest#docker
official_docker_img="ghcr.io/garethgeorge/backrest:latest"

br_timezone() {
    local tz
    if [ -r /etc/timezone ]; then IFS= read -r tz < /etc/timezone; fi
    if [ -z "${tz:-}" ] && command -v timedatectl >/dev/null; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    fi
    printf '%s\n' "${tz:-UTC}"
}
br_exists() { sudo docker container inspect "$docker_name" >/dev/null 2>&1; }
br_running() { [ "$(sudo docker inspect -f '{{.State.Running}}' "$docker_name" 2>/dev/null)" = true ]; }
br_matches() {
    local actual
    actual=$(sudo docker inspect -f '{{.Config.Image}}' "$docker_name" 2>/dev/null) || return 1
    [ "$actual" = "$1" ] || { echo "❌ 当前实例不是所选镜像来源，拒绝覆盖。"; return 1; }
}
br_ready() {
    local n
    for n in 1 2 3; do br_running || return 1; sleep 1; done
}
br_run() {
    local image=$1 entry source target
    local -a data_args=()
    local -A destinations=()
    for entry in "${DATA_MOUNTS[@]}"; do
        source=${entry%%:*}; target=${entry#*:}
        if [[ $entry != *:* || $source != /* || $target != /userdata/* || $target == *:* || $target == *'/../'* || $target == */.. || $target == *'/./'* || $target == */. || $target == */ || -n ${destinations[$target]:-} ]]; then
            echo "❌ DATA_MOUNTS 格式无效或目标重复：$entry"; return 1
        fi
        destinations[$target]=1
        mkdir -p -- "$source" || return 1
        data_args+=(-v "$entry")
    done
    mkdir -p "$app_base_dir"/{data,config,cache,tmp,rclone} || return 1
    sudo docker run -d \
        --name "$docker_name" \
        --hostname "$docker_name" \
        --restart unless-stopped \
        -v "$app_base_dir/data:/data" \
        -v "$app_base_dir/config:/config" \
        -v "$app_base_dir/cache:/cache" \
        -v "$app_base_dir/tmp:/tmp" \
        -v "$app_base_dir/rclone:/root/.config/rclone" \
        "${data_args[@]}" \
        -e BACKREST_DATA=/data \
        -e BACKREST_CONFIG=/config/config.json \
        -e XDG_CACHE_HOME=/cache \
        -e TMPDIR=/tmp \
        -e "TZ=$host_tz" \
        -p "$host_port:$container_port" \
        "$image" >/dev/null && br_ready
}
br_install() {
    local image=$1
    sudo docker info >/dev/null 2>&1 || { echo "❌ Docker 不可用，请先检查环境。"; return 1; }
    if br_exists || [ -e "$app_base_dir" ] || [ -L "$app_base_dir" ]; then
        echo "❌ 已有 Backrest 容器或安装目录；不覆盖、不自动切换来源。"; return 1
    fi
    sudo docker pull "$image" || return 1
    if br_run "$image"; then echo "✅ 启动成功，端口 $host_port"; else echo "❌ 启动失败，保留目录供检查。"; return 1; fi
}
br_update() {
    local image=$1
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    br_matches "$image" || return 1
    # 读取现有 Docker 配置；不生成/重置 config.json 或账号密码。
    python3 - "$docker_name" "$image" "$app_base_dir" "${DATA_MOUNTS[@]}" <<'PY'
import json, subprocess, sys, time, uuid
name, image, base = sys.argv[1:4]
def docker(*args, capture=False):
    return subprocess.check_output(['sudo','docker',*args], text=True) if capture else subprocess.check_call(['sudo','docker',*args], stdout=subprocess.DEVNULL)
try:
    c = json.loads(docker('container','inspect',name,capture=True))[0]
    if c['Config']['Image'] != image: raise ValueError('镜像来源不匹配')
    from pathlib import Path
    desired = {}
    for entry in sys.argv[4:]:
        source, sep, target = entry.partition(':')
        if not sep or not source.startswith('/') or not target.startswith('/userdata/') or ':' in target or '..' in target.split('/') or '.' in target.split('/') or target.endswith('/') or target in desired:
            raise ValueError('DATA_MOUNTS 格式无效或目标重复')
        desired[target] = source
    expected = {'/data':base+'/data','/config':base+'/config','/cache':base+'/cache','/tmp':base+'/tmp','/root/.config/rclone':base+'/rclone'}
    mounts = c['Mounts']
    actual = {m['Destination']:m['Source'] for m in mounts if not m['Destination'].startswith('/userdata/')}
    if actual != expected or any(m['Type']!='bind' for m in mounts):
        raise ValueError('挂载不属于本脚本布局，拒绝自动重建')
    current_data = {m['Destination']:m['Source'] for m in mounts if m['Destination'].startswith('/userdata/')}
    migrating = current_data != desired
    if migrating:
        print('将按顶部 DATA_MOUNTS 重建数据挂载；请检查原备份计划的路径。')
    previous_modes = {m['Destination']:m for m in mounts}
    mounts = [m for m in mounts if not m['Destination'].startswith('/userdata/')]
    for target,source in desired.items():
        Path(source).mkdir(parents=True, exist_ok=True)
        previous = previous_modes.get(target, {})
        mounts.append({'Source':source,'Destination':target,'Mode':previous.get('Mode',''),'RW':previous.get('RW',True)})
    cfg,hc = c['Config'],c['HostConfig']
    if hc.get('Privileged') or hc.get('Devices') or hc.get('CapAdd') or hc.get('AutoRemove') or hc.get('Links') or hc.get('VolumesFrom') or len(c.get('NetworkSettings',{}).get('Networks',{}))>1:
        raise ValueError('发现额外运行配置，请手动更新以免丢失')
    args=['run','-d','--name',name,'--hostname',cfg.get('Hostname') or name]
    restart=hc.get('RestartPolicy',{})
    policy=restart.get('Name') or 'no'
    if policy=='on-failure' and restart.get('MaximumRetryCount'): policy+=':'+str(restart['MaximumRetryCount'])
    args += ['--restart',policy]
    for m in mounts: args += ['-v',m['Source']+':'+m['Destination']+(':'+m['Mode'] if m.get('Mode') else (':ro' if not m['RW'] else ''))]
    for env in cfg.get('Env') or []: args += ['-e',env]
    for k,v in (cfg.get('Labels') or {}).items(): args += ['--label',k+'='+v]
    for p,bindings in (hc.get('PortBindings') or {}).items():
        for b in bindings or []:
            ip=b.get('HostIp',''); port=b['HostPort']
            if ':' in ip: ip='['+ip+']'
            args += ['-p',(ip+':' if ip else '')+port+':'+p]
    for key,flag in [('User','--user'),('WorkingDir','--workdir')]:
        if cfg.get(key): args += [flag,cfg[key]]
    if hc.get('NetworkMode'): args += ['--network',hc['NetworkMode']]
    if hc.get('ReadonlyRootfs'): args += ['--read-only']
    for opt in hc.get('SecurityOpt') or []: args += ['--security-opt',opt]
    for host in hc.get('ExtraHosts') or []: args += ['--add-host',host]
    for k,v in (hc.get('Tmpfs') or {}).items(): args += ['--tmpfs',k+':'+v]
    ep=cfg.get('Entrypoint') or []
    if ep: args += ['--entrypoint',ep[0]]
    args += [image]+ep[1:]+(cfg.get('Cmd') or [])
    docker('pull',image)
    old=name+'-before-update-'+uuid.uuid4().hex[:12]
    running=c['State']['Running']
    if running: docker('stop',name)
    try:
        docker('rename',name,old)
    except Exception:
        if running: docker('start',name)
        raise
    try:
        docker(*args)
        for _ in range(3):
            time.sleep(1)
            if docker('inspect','-f','{{.State.Running}}',name,capture=True).strip()!='true': raise RuntimeError('新容器启动失败')
        if not running: docker('stop',name)
    except Exception:
        subprocess.run(['sudo','docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        docker('rename',old,name)
        if running: docker('start',name)
        raise
    docker('rm',old)
    print('✅ 镜像已更新并重建；保留现有环境、端口、配置及运行/停止状态。' + ('数据挂载已按 DATA_MOUNTS 更新。' if migrating else '挂载保持不变。'))
except Exception as e:
    # 不打印 Docker JSON/环境变量，避免暴露凭据。
    print('❌ 镜像更新失败：'+(str(e) if isinstance(e,(ValueError,RuntimeError)) else 'Docker 操作失败，请检查实例状态。'),file=sys.stderr)
    sys.exit(1)
PY
}
br_current_image() {
    local image
    image=$(sudo docker inspect -f '{{.Config.Image}}' "$docker_name" 2>/dev/null) || {
        echo "❌ 无法读取现有 Backrest 容器镜像。" >&2; return 1;
    }
    case "$image" in
        "$my_docker_img"|"$official_docker_img") printf '%s\n' "$image" ;;
        *) echo "❌ 未知镜像来源，拒绝操作。" >&2; return 1 ;;
    esac
}

br_backup() (
    local image running=false backup_file
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    image=$(br_current_image) || return 1
    echo "当前镜像：$image"
    [ -d "$app_base_dir" ] && [ ! -L "$app_base_dir" ] || return 1
    if br_running; then sudo docker stop "$docker_name" >/dev/null || return 1; running=true; fi
    trap 'if $running; then sudo docker start "$docker_name" >/dev/null || echo "❌ 备份后重启失败，请手动检查。"; fi' EXIT
    backup_file=$(python3 - "$BACKUP_DIR" "$app_base_dir" <<'PY'
import os,pathlib,sys,time
try:
    directory=pathlib.Path(sys.argv[1])
    if not directory.is_absolute() or any(p.is_symlink() for p in (directory,*directory.parents)):
        raise ValueError('备份目录必须为绝对路径且不能含符号链接')
    if directory.resolve().is_relative_to(pathlib.Path(sys.argv[2]).resolve()):
        raise ValueError('备份目录不能放在应用数据目录内')
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    while True:
        p=directory/('backrest-'+time.strftime('%Y%m%d-%H%M%S')+'.tar.gz')
        try:
            fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
            os.close(fd); print(p); break
        except FileExistsError: time.sleep(1)
except Exception as e:
    print('❌ '+(str(e) if isinstance(e,ValueError) else '无法创建备份文件，请检查备份目录。'),file=sys.stderr)
    sys.exit(1)
PY
    ) || return 1
    if ! tar -czf "$backup_file" --exclude='docker/backrest/cache' --exclude='docker/backrest/tmp' --exclude='docker/backrest/logs' -C "$(dirname "$(dirname "$app_base_dir")")" docker/backrest; then
        rm -f -- "$backup_file"; echo "❌ 备份失败。"; return 1
    fi
    chmod 600 "$backup_file" || return 1
    if $running; then
        sudo docker start "$docker_name" >/dev/null || { running=false; echo "❌ 归档已保存，但备份后启动容器失败。"; return 1; }
        running=false
        br_ready || { echo "❌ 归档已保存，但容器未通过启动检查。"; return 1; }
    fi
    if [[ -n ${BR_BACKUP_RESULT_FILE:-} ]]; then
        printf '%s\n' "$backup_file" > "$BR_BACKUP_RESULT_FILE" || return 1
    fi
    echo "✅ 备份完成（含配置和凭据，请妥善保管）：$backup_file"
)
br_extract() {
    python3 - "$1" "$2" <<'PY'
import tarfile,sys,pathlib
try:
    with tarfile.open(sys.argv[1],'r:gz') as t:
        members=t.getmembers(); seen=set()
        for m in members:
            name=m.name
            parts=pathlib.PurePosixPath(name).parts
            if name.startswith('/') or '..' in parts or parts[:2]!=('docker','backrest') or not (m.isdir() or m.isfile()) or name in seen:
                raise ValueError('不安全的归档成员')
            seen.add(name)
        if not any(m.isfile() and m.name=='docker/backrest/config/config.json' for m in members):
            raise ValueError('缺少 config/config.json')
        t.extractall(sys.argv[2],members=members,filter='data')
except Exception:
    print('❌ 备份结构无效或解压失败（拒绝路径穿越、链接和特殊文件）。',file=sys.stderr); sys.exit(1)
PY
}
br_list_backups() {
    python3 - "${RESTORE_DIRS[@]}" <<'PY'
import datetime,os,pathlib,re,sys
try:
    files={}
    pattern=re.compile(r'(?:backrest|backrest-backup|Backrest-official)-(\d{8})-?(\d{6})\.tar\.gz')
    for raw in sys.argv[1:]:
        directory=pathlib.Path(raw)
        if not directory.is_absolute() or any(p.is_symlink() for p in (directory,*directory.parents)):
            raise ValueError('恢复目录必须为绝对路径且不能含符号链接')
        if not directory.exists(): continue
        for p in directory.iterdir():
            m=pattern.fullmatch(p.name)
            if not m or p.is_symlink() or not p.is_file(): continue
            stamp=''.join(m.groups())
            try: datetime.datetime.strptime(stamp,'%Y%m%d%H%M%S')
            except ValueError: continue
            files[str(p.resolve())]=stamp
    for p in sorted(files,key=lambda p:(files[p],p),reverse=True):
        sys.stdout.buffer.write(os.fsencode(p)+b'\0')
except Exception:
    print('❌ 无法读取恢复目录，请检查 RESTORE_DIRS 路径和权限。',file=sys.stderr)
    sys.exit(1)
PY
}

br_restore() (
    local image source_choice selection confirm stage rollback running=false existed=false file listing
    local -a files=()
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    if br_exists; then
        existed=true
        image=$(br_current_image) || return 1
        br_running && running=true
        echo "恢复将保留当前镜像来源：$image"
    else
        # 区分真正没有容器和 Docker 查询故障，禁止将后者当作首次恢复。
        local containers
        containers=$(sudo docker container ls -a --format '{{.Names}}') || {
            echo "❌ 无法查询 Docker 容器，已取消恢复。"; return 1;
        }
        if [[ $'\n'$containers$'\n' == *$'\n'"$docker_name"$'\n'* ]]; then
            echo "❌ 容器存在但读取失败，已取消恢复。"; return 1
        fi
    fi
    listing=$(mktemp "${TMPDIR:-/root/.hermes/cache/scratch}/backrest-list.XXXXXX") || return 1
    br_list_backups > "$listing" || { rm -f -- "$listing"; return 1; }
    mapfile -d '' -t files < "$listing"
    rm -f -- "$listing"
    [ ${#files[@]} -gt 0 ] || { echo "没有找到备份。"; return 1; }
    echo "检测到以下备份文件："
    local i
    for i in "${!files[@]}"; do echo "$((i+1)). ${files[i]##*/}"; done
    IFS= read -r -p "请选择要恢复的备份编号（回车恢复最新备份，0 取消）: " selection || return 1
    selection=${selection:-1}
    [[ $selection =~ ^[1-9][0-9]*$ ]] && [ ${#selection} -le 6 ] && [ "$selection" -le "${#files[@]}" ] || { echo "已取消或编号无效。"; return 1; }
    file=${files[selection-1]}
    [ -f "$file" ] && [ ! -L "$file" ] || { echo "❌ 不接受链接备份。"; return 1; }
    if ! $existed; then
        echo "未发现现有容器，请选择恢复使用的镜像："
        echo "1. $my_docker_img"
        echo "2. $official_docker_img"
        IFS= read -r -p "请选择镜像来源（1/2，0 取消）：" source_choice || return 1
        case "$source_choice" in
            1) image=$my_docker_img ;;
            2) image=$official_docker_img ;;
            *) echo "已取消恢复。"; return 1 ;;
        esac
    fi
    echo "恢复镜像来源：$image"
    echo "将用 ${file##*/} 替换 $app_base_dir；保留恢复前数据，不修改备份文件。"
    IFS= read -r -p "输入小写 yes 确认恢复: " confirm || return 1
    [ "$confirm" = yes ] || { echo "已取消恢复。"; return 1; }
    [ ! -L "$app_base_dir" ] || return 1
    stage=$(mktemp -d "${TMPDIR:-/root/.hermes/cache/scratch}/backrest-restore.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    cp -- "$file" "$stage/archive.tar.gz" && chmod 600 "$stage/archive.tar.gz" || return 1
    br_extract "$stage/archive.tar.gz" "$stage" || return 1
    mkdir -p "$stage/docker/backrest"/{data,config,cache,tmp,rclone} || return 1
    # 回滚数据含凭据；放在 /root，避免位于容器的数据挂载目录内。
    mkdir -p /root/.backrest-rollback && chmod 700 /root/.backrest-rollback || return 1
    rollback=$(mktemp -d /root/.backrest-rollback/before-restore.XXXXXX) || return 1
    if $running; then sudo docker stop "$docker_name" >/dev/null || return 1; fi
    if [ -e "$app_base_dir" ]; then
        mv -T -- "$app_base_dir" "$rollback/data" || { $running && sudo docker start "$docker_name" >/dev/null; return 1; }
    fi
    if ! mv -T -- "$stage/docker/backrest" "$app_base_dir"; then
        [ ! -e "$rollback/data" ] || mv -T -- "$rollback/data" "$app_base_dir"
        $running && sudo docker start "$docker_name" >/dev/null
        echo "❌ 替换失败，回滚数据：$rollback"; return 1
    fi
    local ok=true
    if $existed; then
        if $running; then sudo docker start "$docker_name" >/dev/null && br_ready || ok=false; fi
    else br_run "$image" || ok=false
    fi
    if ! $ok; then
        sudo docker stop "$docker_name" >/dev/null 2>&1
        mv -T -- "$app_base_dir" "$rollback/failed-restoration" || return 1
        if [ -e "$rollback/data" ]; then
            mv -T -- "$rollback/data" "$app_base_dir" || { echo "❌ 回滚失败，数据保留于 $rollback"; return 1; }
            $running && sudo docker start "$docker_name" >/dev/null
        fi
        echo "❌ 恢复启动失败，已尝试回滚；保留目录：$rollback"; return 1
    fi
    echo "✅ 恢复完成；恢复前数据保留于 $rollback"
)
br_uninstall() {
    local confirm image
    echo "将删除容器 $docker_name 和 $app_base_dir 全部数据；保留备份目录 $BACKUP_DIR、/home 历史备份、源码构建目录、Docker/共享依赖及镜像。"
    IFS= read -r -p "输入小写 yes 确认卸载: " confirm || return 1
    [ "$confirm" = yes ] || { echo "已取消卸载。"; return 1; }
    if br_exists; then
        image=$(sudo docker inspect -f '{{.Config.Image}}' "$docker_name") || return 1
        case "$image" in "$my_docker_img"|"$official_docker_img") ;; *) echo "❌ 未知镜像，拒绝删除。"; return 1;; esac
        sudo docker rm -f "$docker_name" >/dev/null || return 1
    fi
    [ "$app_base_dir" = /home/docker/backrest ] || { echo "❌ 目录不在卸载范围。"; return 1; }
    sudo rm -rf -- "$app_base_dir" || return 1
    echo "✅ 已卸载（镜像和备份保留）。"
}

br_push() {
    local source source_id target_id remote_json remote_id
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3 验证远端镜像。"; return 1; }
    source=$(br_current_image) || return 1
    # 使用容器实际关联的镜像 ID，避免 latest 标签移动后推错版本。
    source_id=$(sudo docker inspect --format '{{.Image}}' "$docker_name") || return 1
    [[ $source_id == sha256:* ]] || { echo "❌ 无法取得当前容器镜像 ID。"; return 1; }
    echo "源镜像：$source（当前容器使用的镜像）"
    echo "目标镜像：$my_docker_img"
    sudo docker image inspect --format '{{.Id}}' "$source_id" >/dev/null || return 1
    sudo docker tag "$source_id" "$my_docker_img" || return 1
    sudo docker push "$my_docker_img" || { echo "❌ 推送失败，请检查登录状态和仓库权限。"; return 1; }
    remote_json=$(sudo docker manifest inspect "$my_docker_img") || { echo "❌ 推送命令成功，但远端校验失败。"; return 1; }
    remote_id=$(printf '%s' "$remote_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("digest",""))') || return 1
    target_id=$(sudo docker image inspect --format '{{.Id}}' "$my_docker_img") || return 1
    [ "$remote_id" = "$source_id" ] && [ "$target_id" = "$source_id" ] || {
        echo "❌ 远端镜像与源镜像未能确认一致（多架构索引需另行核验）。"; return 1;
    }
    echo "✅ 已打标签并推送到 $my_docker_img，远端摘要校验通过。"
}

br_cloud_add() {
    local backend=$1 mount_source
    br_current_image >/dev/null || return 1
    br_running || { echo "❌ 请先启动 Backrest 容器。"; return 1; }
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    mount_source=$(sudo docker inspect -f '{{range .Mounts}}{{if eq .Destination "/root/.config/rclone"}}{{.Source}}{{end}}{{end}}' "$docker_name") || return 1
    [ "$mount_source" = "$app_base_dir/rclone" ] || { echo "❌ 容器 rclone 挂载路径不匹配，拒绝修改。"; return 1; }
    python3 - "$app_base_dir" "$docker_name" "$backend" 3<&0 <<'PY'
import configparser,getpass,json,os,pathlib,re,shutil,subprocess,sys,tempfile
base,container,backend=sys.argv[1:]
stage=pending=None

def ask(prompt,secret=False):
    print(prompt,end='',flush=True)
    if secret and os.isatty(3):
        value=getpass.getpass('',stream=sys.stdout)
    else:
        raw=bytearray()
        while True:
            c=os.read(3,1)
            if not c:
                if not raw: raise EOFError
                break
            if c==b'\n': break
            raw.extend(c)
        value=raw.decode().removesuffix('\r')
    if any(ord(c)<32 or ord(c)==127 for c in value): raise ValueError('答案不能含控制字符')
    if value in (':cancel', ':quit', '退出配置向导'): raise EOFError
    return value

def invoke(state=None,answer=None):
    if state is None:
        script='exec rclone config create "$1" "$2" --config "$3" --all --non-interactive'
        args=[name,backend,config];payload=None
    else:
        script='IFS= read -r state; IFS= read -r result; exec rclone config update "$1" --config "$2" --all --non-interactive --continue --state "$state" --result "$result"'
        args=[name,config];payload=state+'\n'+answer+'\n'
    p=subprocess.run(['sudo','docker','exec','-i',container,'sh','-c',script,'wizard',*args],input=payload,text=True,capture_output=True)
    if p.returncode: raise ValueError('rclone 配置失败，请检查网络、账号或授权结果（为保护凭据不打印原始诊断）')
    try: return json.loads(p.stdout)
    except Exception: raise ValueError('rclone 未返回有效配置向导结果')

try:
    if backend not in ('drive','onedrive','pcloud','pikpak','mega','dropbox','box'): raise ValueError('未知网盘类型')
    directory=pathlib.Path(base)/'rclone';path=directory/'rclone.conf'
    if not pathlib.Path(base).is_dir() or any(p.is_symlink() for p in (directory,*directory.parents)): raise ValueError('安装目录无效或含符号链接')
    if path.is_symlink() or (path.exists() and not path.is_file()): raise ValueError('配置必须是普通文件')
    original=path.read_bytes() if path.exists() else None
    text=(original or b'').decode()
    if text.startswith('RCLONE_ENCRYPT_V'): raise ValueError('加密配置请使用 rclone config 管理')
    lines=text.splitlines(keepends=True);header=re.compile(r'^\s*\[([^\]\r\n]+)\]\s*(?:[#;].*)?$')
    sections=[(i,m[1]) for i,line in enumerate(lines) if (m:=header.fullmatch(line.rstrip('\r\n')))]
    print('退出配置向导：任意输入处输入 :quit 或 退出配置向导，再按回车；也可按 Ctrl+C。')
    name=ask('请输入网盘名称（唯一名称例如 gdrive，0 取消）：')
    if name=='0': raise EOFError
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*',name): raise ValueError('名称只能使用字母、数字、下划线、点和连字符')
    matching=[i for i,n in sections if n==name]
    if matching:
        print('唯一名称 '+name)
        if ask('已存在输入yes修改（其他取消）：')!='yes': raise EOFError
    remark=ask('请输入备注名（回车使用唯一名称）：') or name
    directory.mkdir(mode=0o700,exist_ok=True)
    stage=pathlib.Path(tempfile.mkdtemp(prefix='.cloud-config.',dir=directory))
    config='/root/.config/rclone/'+stage.name+'/rclone.conf'
    print('进入 rclone 官方向导，回车使用默认值；输入 :quit / :cancel / 退出配置向导可取消，敏感输入处同样有效。')
    print('服务器无浏览器时，浏览器授权问题选择 false；按提示在电脑运行 rclone authorize，再粘贴授权结果。')
    response=invoke()
    for step in range(150):
        if not response.get('State'): break
        option=response.get('Option')
        if not option:
            if response.get('Error'):
                error=str(response['Error']).lower()
                # 不输出原始错误，可能包含用户提交的 token 或编码授权参数。
                if any(x in error for x in ('decode','base64','unmarshal','invalid character')):
                    raise ValueError('授权结果无法解析：请粘贴 rclone authorize 两个标记之间的完整单行结果；不要只填 access_token。电脑和服务器建议使用相同 rclone 版本。')
                if any(x in error for x in ('timeout','dial tcp','network','connection')):
                    raise ValueError('服务器在授权后访问网盘接口失败，请检查服务器到 Google/网盘服务的网络或代理。')
                raise ValueError('rclone 授权步骤失败，请重新生成完整授权结果；若仍失败需进一步检查返回状态（原始信息已隐藏以保护凭据）。')
            response=invoke(response['State'],str(response.get('Result') or ''))
            continue
        if response.get('Error'): print('❌ 上一步答案未被接受，请重新输入。')
        print('\n'+str(option.get('Help') or option.get('Name','配置项')))
        for e in option.get('Examples') or []: print(str(e.get('Value',''))+' : '+str(e.get('Help','')))
        default=option.get('Default')
        key=option.get('Name','')
        if backend=='drive' and key=='scope': default='drive'
        if key=='config_is_local': default=False
        labels={
            'client_id':'客户端 ID（Client ID；自建 OAuth 应用请填写，否则回车留空）',
            'client_secret':'客户端密钥（Client Secret；与上面的客户端 ID 配对，不是账号密码）',
            'scope':'访问权限 scope（完整备份/恢复输入 drive；只读输入 drive.readonly）',
            'config_fs_advanced':'是否编辑高级配置（通常回车选择 false）',
            'config_is_local':'是否在这台服务器打开浏览器授权（无浏览器输入 false）',
            'config_token':'授权结果（在有浏览器的电脑运行上方 rclone authorize 命令后粘贴）',
            'root_folder_id':'根文件夹 ID（通常回车留空，使用网盘根目录）',
            'service_account_file':'服务账号 JSON 文件路径（普通 Google 账号授权请回车留空）',
            'config_team_drive':'是否配置 Google 共享云端硬盘（普通个人网盘选择 false）',
            'user':'账号 / 登录邮箱',
            'pass':'账号密码',
        }
        label=labels.get(key,key or '配置项')
        if key=='scope' and backend!='drive': label=key
        secret=option.get('IsPassword',False) or key in ('pass','config_token') or any(x in key.lower() for x in ('token','secret','password'))
        print('当前配置项：'+label)
        display_default = '留空' if default is None or default=='' else str(default).lower() if isinstance(default,bool) else str(default)
        prompt_label='是否在这台服务器打开浏览器授权（有浏览器输入 true）' if key=='config_is_local' else label
        answer=ask('请输入 '+prompt_label+('（敏感内容不回显）' if secret else '（默认：'+display_default+'）')+'：',secret)
        if answer=='' and default is not None: answer=display_default if default!='' else ''
        response=invoke(response['State'],answer)
    else: raise ValueError('配置步骤过多，已取消')
    generated=stage/'rclone.conf';parser=configparser.RawConfigParser();parser.read(generated)
    if parser.sections()!=[name] or parser.get(name,'type',fallback='')!=backend: raise ValueError('向导未生成预期网盘配置')
    newtext=generated.read_text()
    newlines=newtext.splitlines(keepends=True)
    for i,line in enumerate(newlines):
        if header.fullmatch(line.rstrip('\r\n')):
            newlines.insert(i+1,'# backrest_remark = '+remark+'\n')
            break
    newtext=''.join(newlines);result=[];cursor=0
    for start in matching:
        end=next((i for i,_ in sections if i>start),len(lines));result.extend(lines[cursor:start])
        if start==matching[0]: result.append(newtext.rstrip('\n')+'\n\n')
        cursor=end
    if matching:
        result.extend(lines[cursor:]);updated=''.join(result)
    else: updated=text+('\n' if text and not text.endswith('\n') else '')+('\n' if text else '')+newtext
    if path.is_symlink() or (path.read_bytes() if path.exists() else None)!=original: raise ValueError('授权期间原配置发生变化，取消保存')
    fd,pending=tempfile.mkstemp(prefix='.rclone.conf.',dir=directory)
    with os.fdopen(fd,'wb') as f:
        os.fchmod(f.fileno(),0o600)
        if original is not None:
            info=path.stat();os.fchown(f.fileno(),info.st_uid,info.st_gid)
        f.write(updated.encode());f.flush();os.fsync(f.fileno())
    os.replace(pending,path);pending=None
    print('✅ 已保存网盘 ['+name+']（'+backend+'），其他配置保留。')
    print('Backrest 仓库可使用 rclone:'+name+':备份目录；尚未测试仓库读写。')
except (EOFError,KeyboardInterrupt): print('\n已取消，原配置未修改。')
except Exception as e:
    print('❌ '+(str(e) if isinstance(e,ValueError) else '网盘配置失败，请检查容器、目录和权限。'),file=sys.stderr);sys.exit(1)
finally:
    if pending: os.unlink(pending)
    if stage: shutil.rmtree(stage)
PY
}

br_cloud_cancel_other() {
    [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行此操作。"; return 1; }
    python3 - "$app_base_dir" "$docker_name" "${BASH_SOURCE[0]}" <<'PY_CANCEL'
import json,os,pathlib,signal,subprocess,sys,time
base,container,manager=sys.argv[1:]
manager=str(pathlib.Path(manager).resolve())
lock='/run/lock/backrest-manager.lock'
allowed={'drive','onedrive','pcloud','pikpak','mega','dropbox','box'}
def owners():
    result=subprocess.run(['lslocks','--json','--output','PID,COMMAND,PATH'],text=True,capture_output=True,check=True)
    return [int(x['pid']) for x in json.loads(result.stdout).get('locks',[]) if x.get('path')==lock]
def identity(pid):
    p=pathlib.Path('/proc')/str(pid)
    fields=(p/'stat').read_text().rsplit(')',1)[1].split()
    args=[os.fsdecode(a) for a in (p/'cmdline').read_bytes().split(b'\0') if a]
    return fields[19],int(fields[1]),args
try:
    held=owners()
    if not held:
        print('当前没有占用操作锁的网盘配置向导。');sys.exit(0)
    if len(held)!=1: raise ValueError('锁状态不明确，未终止任何进程。')
    parent=held[0];parent_info=identity(parent)
    if pathlib.Path(parent_info[2][0]).name not in ('bash','sh') or manager not in parent_info[2]:
        raise ValueError('当前锁并非可确认的本脚本网盘向导，未终止任何进程。')
    children=(pathlib.Path('/proc')/str(parent)/'task'/str(parent)/'children').read_text().split()
    candidates=[]
    for value in children:
        pid=int(value);info=identity(pid);args=info[2]
        if (info[1]==parent and len(args)==5 and pathlib.Path(args[0]).name in ('python3','python')
                and args[1:4]==['-',base,container] and args[4] in allowed):
            candidates.append((pid,info))
    if len(candidates)!=1: raise ValueError('当前可能在更新、备份或推送，未找到唯一网盘向导，未终止进程。')
    pid,info=candidates[0]
    # pidfd固定进程身份，防止检查后PID被其他进程复用。
    fd=os.pidfd_open(pid)
    try:
        if owners()!=held or identity(parent)!=parent_info or identity(pid)!=info:
            raise ValueError('进程或锁已变化，请重试。')
        signal.pidfd_send_signal(fd,signal.SIGINT)
    finally: os.close(fd)
    for _ in range(50):
        if parent not in owners():
            print('✅ 已退出 '+info[2][4]+' 配置向导，操作锁已释放；已保存配置不变。')
            break
        time.sleep(0.1)
    else: raise ValueError('已发送取消信号，但操作锁尚未释放；未强制杀死进程，请检查原终端。')
except (ProcessLookupError,FileNotFoundError):
    print('❌ 进程已变化或缺少检查工具，请重试。');sys.exit(1)
except Exception as e:
    print('❌ '+(str(e) if isinstance(e,ValueError) else '无法安全取消向导，未执行强制终止。'));sys.exit(1)
PY_CANCEL
}

br_cloud_menu() {
    local choice
    while true; do
        if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then clear; fi
        echo "=================================="
        echo "      添加网盘配置"
        echo "=================================="
        br_cloud_list
        echo "=================================="
        echo "仓库URL填写下面内容 更换唯一的名称 gdrive"
        echo "rclone:gdrive:备份目录（这里的 gdrive 对应的是唯一名称）"
        echo "=================================="
        echo "------------------------------------------------"
        echo "$env:HTTPS_PROXY = "http://127.0.0.1:10808""
        echo "------------------------------------------------"
        echo "=================================="
        echo "1. Google Drive"
        echo ".\rclone.exe authorize "drive" "你的VPS显示的那段授权参数""
        echo "----------------------------------"
        echo "2. OneDrive"

        echo "----------------------------------"
        echo "3. pCloud"
        echo ".\rclone.exe authorize "pcloud""
        echo "----------------------------------"
        echo "4. PikPak"

        echo "----------------------------------"
        echo "5. MEGA"

        echo "----------------------------------"
        echo "6. Dropbox"

        echo "----------------------------------"
        echo "7. Box"

        echo "----------------------------------"
        echo "9. 删除"
        echo "10. 退出配置向导"
        echo "0. 返回上一级"
        echo "------------------------------------------------"
        IFS= read -r -p "请输入操作编号: " choice || return 0
        case "$choice" in
            1) br_operate br_cloud_add drive ;;
            2) br_operate br_cloud_add onedrive ;;
            3) br_operate br_cloud_add pcloud ;;
            4) br_operate br_cloud_add pikpak ;;
            5) br_operate br_cloud_add mega ;;
            6) br_operate br_cloud_add dropbox ;;
            7) br_operate br_cloud_add box ;;
            9) br_operate br_cloud_delete ;;
            10) br_cloud_cancel_other ;;
            0|:quit|:cancel|退出配置向导) return 0 ;;
            *) echo "无效选择" ;;
        esac
        IFS= read -r -p "按回车继续..." _ || return 0
    done
}

br_cloud_delete() { br_cloud_list delete; }

br_cloud_list() {
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3 读取网盘配置。"; return 1; }
    python3 - "$app_base_dir" "${1:-list}" 3<&0 <<'PY'
import os,pathlib,re,sys,tempfile,unicodedata
mode=sys.argv[2]
pending=None
def ask(prompt):
    print(prompt,end='',flush=True)
    raw=bytearray()
    while True:
        c=os.read(3,1)
        if not c:
            if not raw: raise EOFError
            break
        if c==b'\n': break
        raw.extend(c)
    return raw.decode().removesuffix('\r')
providers={'drive':'Google Drive','onedrive':'OneDrive','pcloud':'pCloud','pikpak':'PikPak','mega':'MEGA','dropbox':'Dropbox','box':'Box'}
def safe(value): return ''.join(c for c in value if c.isprintable())
def width(value): return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in value)
def paint(value,color):
    return '\033['+color+'m'+value+'\033[0m' if sys.stdout.isatty() and os.environ.get('TERM','dumb')!='dumb' else value
try:
    directory=pathlib.Path(sys.argv[1])/'rclone';path=directory/'rclone.conf'
    if any(p.is_symlink() for p in (path,*path.parents)): raise ValueError
    original=path.read_bytes() if path.exists() else None
    text=(original or b'').decode('utf-8')
    if text.startswith('RCLONE_ENCRYPT_V'): raise ValueError
    remotes=[];name=None;fields={}
    for line in text.splitlines()+['[__end__]']:
        header=re.fullmatch(r'\s*\[([^\]]+)\]\s*(?:[#;].*)?',line)
        if header:
            if name is not None and fields.get('type') in providers:
                remotes.append((safe(name),safe(fields.get('remark') or fields.get('description') or '未填写'),providers[fields['type']]))
            name=header[1];fields={};continue
        # 仅读取展示字段，不输出账号、密码或 token。
        m=re.fullmatch(r'\s*#\s*backrest_remark\s*=\s*(.*)',line)
        if m: fields['remark']=m[1].strip();continue
        m=re.fullmatch(r'\s*(type|description)\s*=\s*(.*?)\s*',line)
        if m: fields[m[1]]=m[2]
    first=max([22]+[width(str(i)+'. '+n)+2 for i,(n,_,_) in enumerate(remotes,1)])
    second=max([20]+[width(r)+2 for _,r,_ in remotes])
    print('唯一名称'+' '*(first-width('唯一名称'))+'备注名'+' '*(second-width('备注名'))+'网盘服务商')
    if not remotes: print(paint('暂无','31'))
    for i,(name,remark,provider) in enumerate(remotes,1):
        label=str(i)+'. '+name
        print(paint(label,'32')+' '*(first-width(label))+paint(remark,'33')+' '*(second-width(remark))+paint(provider,'1;94'))
    if mode=='delete' and remotes:
        choice=ask('请选择要删除的网盘编号（0 取消）：')
        if not choice.isascii() or not choice.isdigit() or len(choice)>6 or not 1<=int(choice)<=len(remotes): raise EOFError
        name=remotes[int(choice)-1][0]
        print('将删除本地网盘配置 ['+name+']，不删除网盘中的文件。')
        if ask('输入小写 yes 确认删除（其他取消）：')!='yes': raise EOFError
        lines=text.splitlines(keepends=True)
        pattern=re.compile(r'\s*\[([^\]]+)\]\s*(?:[#;].*)?')
        sections=[(i,m[1]) for i,line in enumerate(lines) if (m:=pattern.fullmatch(line.rstrip('\r\n')))]
        if any(raw!=safe(raw) for _,raw in sections): raise ValueError
        result=[];cursor=0
        for start,remote in sections:
            if remote!=name: continue
            end=next((i for i,_ in sections if i>start),len(lines))
            result.extend(lines[cursor:start]);cursor=end
        result.extend(lines[cursor:])
        if path.is_symlink() or path.read_bytes()!=original: raise ValueError
        fd,pending=tempfile.mkstemp(prefix='.rclone.conf.',dir=directory)
        with os.fdopen(fd,'wb') as f:
            info=path.stat();os.fchown(f.fileno(),info.st_uid,info.st_gid);os.fchmod(f.fileno(),0o600)
            f.write(''.join(result).encode('utf-8'));f.flush();os.fsync(f.fileno())
        os.replace(pending,path);pending=None
        print('✅ 已删除网盘配置 ['+name+']，其他配置及远端文件保留。')
except (EOFError,KeyboardInterrupt):
    print('\n已取消，原配置未修改。')
except Exception:
    print('❌ 网盘配置操作失败，请检查文件权限、格式或是否加密。')
    sys.exit(1)
finally:
    if pending: os.unlink(pending)
PY
}

show_menu() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then clear; fi
    echo "=================================="
    echo "      Backrest 资源备份工具 管理脚本"
    echo "=================================="
    echo "对象存储添加配置"
    echo "------------------------------------------------"
    echo "仓库URL"
    echo "s3:https://us.example.com.xyz/cunchu/备份路径"
    echo "------------------------------------------------"
    echo "s3:https://实际S3 API 地址不是管理地址/你的存储桶/备份路径"
    echo "------------------------------------------------"
    echo "环境变量（每项单独添加）"
    echo "------------------------------------------------"
    echo "AWS_ACCESS_KEY_ID=访问密钥 ID"
    echo "AWS_SECRET_ACCESS_KEY=访问密钥"
    echo "AWS_DEFAULT_REGION=auto"
    echo "=================================="
    echo "网盘配置 rclone:gdrive:备份目录（这里的 gdrive 对应的是唯一名称）"
    br_cloud_list
    echo "=================================="
    echo "远程归档任务（与网页 Restic 仓库独立）"
    air_named_summary all
    echo "1. 安装 Backrest (使用zaixiangjian/backrest:latest)"
    echo "2. 更新镜像"
    echo "3. 登录 Docker Hub"
    echo "4. 打标签推送镜像到 zaixiangjian/backrest:latest"
    echo "5. SSH 远程备份配置"
    echo "6. S3 API 兼容备份配置"
    echo "8. 添加网盘配置"
    echo "9. 卸载（支持两个镜像源的方式）"
    echo "------------------------------------------------"
    echo "11. 官方安装"
    echo "12. 官方更新"
    echo "13. 备份（自制/官方通用）"
    echo "14. 恢复备份（保留当前镜像来源）"
    echo "------------------------------------------------"
    echo "0) 返回上一级"
    echo "------------------------------------------------"
}

main() {
    local br_choice
    air_manager_init || return 1
    # 仅修复已有完整任务的调度，不自动创建任务或立即执行备份。
    air_repair_remote_schedules || echo "❌ 部分远程任务调度修复失败。"
    while true; do
        show_menu
        IFS= read -r -p "请输入操作编号: " br_choice || { echo "已退出"; break; }
        case $br_choice in
            1) br_operate br_install "$my_docker_img" ;;
            2) br_operate br_update "$my_docker_img" ;;
            3) br_operate sudo docker login ;;
            4) br_operate br_push ;;
            5) air_remote_menu ssh; continue ;;
            6) air_remote_menu s3; continue ;;
            8) br_cloud_menu; continue ;;
            9) br_operate br_uninstall ;;
            11) br_operate br_install "$official_docker_img" ;;
            12) br_operate br_update "$official_docker_img" ;;
            13) br_operate br_backup ;;
            14) br_operate br_restore ;;
            0) echo "已退出"; break ;;
            *) echo "无效选择" ;;
        esac
        IFS= read -r -p "按回车继续..." _ || break
    done
}

# 远程备份引擎及启动分派在下方，支持 systemd 调用此单文件。

# Reusable adaptation of CLIProxyAPI.sh original single-kind SSH/S3 engine.
# Parent supplies BACKUP_DIR BACKUP_PREFIX (including separator), REMOTE_DIR,
# LOCK_FILE RETENTION_FILE AI_APP_ID AI_APP_LABEL and ai_local_backup.
# Set AI_MANAGER_SCRIPT to the installed parent manager for systemd ExecStart.
# Source only defines functions; never installs timers or executes backups.
air_init() {
    [[ ${AI_APP_ID:-} == openclaw || ${AI_APP_ID:-} == hermes || ${AI_APP_ID:-} == backrest ]] || return 1
    [[ -n ${AI_APP_LABEL:-} && ${BACKUP_DIR:-} == /* && -n ${BACKUP_PREFIX:-} && $BACKUP_PREFIX != */* ]] || return 1
    [[ ${REMOTE_DIR:-} == "$BACKUP_DIR/config" && ${LOCK_FILE:-} == "$BACKUP_DIR/config/backup.lock" && ${RETENTION_FILE:-} == "$REMOTE_DIR/local-retention.json" ]] || return 1
    declare -F ai_local_backup >/dev/null
}
air_error() { echo "错误：$*" >&2; }
air_locked() (
    umask 077
    mkdir -p "$(dirname "$LOCK_FILE")" || exit 1
    exec 9>"$LOCK_FILE" || exit 1
    flock -n 9 || { air_error "应用备份操作正在执行。"; exit 1; }
    exec 6>/run/lock/backrest-manager.lock || exit 1
    flock -n 6 || { air_error "另一项 Backrest 操作正在进行。"; exit 1; }
    "$@"
)
air_ensure_environment() {
    local cmd
    for cmd in python3 flock; do command -v "$cmd" >/dev/null || { air_error "请先安装$cmd"; return 1; }; done
    if [[ ${1:-} == remote ]]; then
        if ! command -v rclone >/dev/null || ! command -v ssh >/dev/null; then
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
import os,sys,pathlib,json,re,subprocess,urllib.parse,tempfile,time,hashlib,tarfile
sys.stdin=os.fdopen(3)
def input(prompt=''):
    print(prompt,end='',flush=True)
    raw=bytearray()
    while True:
        char=os.read(3,1)
        if not char:
            if not raw: raise EOFError
            break
        if char==b'\n': break
        raw.extend(char)
    return raw.decode().removesuffix('\r')
def hidden(prompt):
    if not os.isatty(3): return input(prompt)
    import termios
    previous=termios.tcgetattr(3)
    quiet=termios.tcgetattr(3); quiet[3] &= ~termios.ECHO
    termios.tcsetattr(3,termios.TCSADRAIN,quiet)
    try: return input(prompt)
    finally:
        termios.tcsetattr(3,termios.TCSADRAIN,previous)
        print()
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
        d={'kind':kind,'keep':0 if kind in ('ssh','ssh-backup') else 3,'action':'backup' if kind=='ssh-backup' else 'transfer'}
        if kind=='ssh':
            while True:
                local_keep=ask('检查本地备份数量（回车默认3）','3')
                if local_keep.isdigit() and 1<=int(local_keep)<=100000:
                    d['local_keep']=int(local_keep); break
                print('请输入1–100000的整数。')
        if kind in ('ssh-backup','ssh'):
            while True:
                keep=ask('远程保留数量（回车默认 3 输入 0 不删除远程备份）','3')
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
                password=valid(hidden('SSH密码（隐藏输入）：'))
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
            access=valid(hidden('Access Key ID（隐藏输入）：')); secret=valid(hidden('Secret Access Key（隐藏输入）：'))
            while True:
                local_keep=ask('检查本地备份数量（回车默认3）','3')
                if local_keep.isdigit() and 1<=int(local_keep)<=100000:
                    d['local_keep']=int(local_keep); break
                print('请输入1–100000的整数。')
            while True:
                keep=ask('S3远程保留数量（回车默认 3 输入 0 不删除远程备份）','3')
                if keep.isdigit() and 0<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入0–100000的整数，0表示不删除。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份'+label+'时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+access+'\nsecret_access_key = '+secret+'\nendpoint = '+endpoint+'\nregion = '+region+'\nforce_path_style = true\nsign_accept_encoding = false\n'
        if d['action']=='backup':
            while True:
                print('备份间隔（1h/2h/4h/6h/8h/12h，1d/2d/3d/5d/7d/14d/30d）')
                interval=input('h等于小时，d等于天[默认 7d]：').strip() or '7d'
                if interval in ('1h','2h','4h','6h','8h','12h','1d','2d','3d','5d','7d','14d','30d'): break
                print('请输入完整间隔，例如4h或7d。')
            d['interval']=interval
            if interval.endswith('h'):
                minute=ask('北京时间每个周期的分钟','0')
                if not minute.isdigit() or not 0<=int(minute)<=59: raise ValueError('分钟无效')
                d['calendar']='*-*-* 00/'+interval[:-1]+':'+f'{int(minute):02}'+':00 Asia/Shanghai'
            else:
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
        with tarfile.open(f,'r:gz') as archive: archive.getmembers()
        import gzip
        with gzip.open(f,'rb') as stream:
            while stream.read(1024*1024): pass
        digest_hash=hashlib.sha256()
        with f.open('rb') as stream:
            for chunk in iter(lambda:stream.read(1024*1024),b''): digest_hash.update(chunk)
        digest=digest_hash.hexdigest()
        state=root/(kind+'-sent.json')
        signature=[f.name,st.st_size,digest]
        if state.exists() and json.loads(state.read_text())==signature:
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
            keep=d.get('keep',3)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('远程保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        if f.stat().st_size!=st.st_size or f.stat().st_mtime_ns!=st.st_mtime_ns: raise ValueError('归档在传送中发生变化')
        save(state,json.dumps(signature))
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
    python3 - "$BACKUP_DIR/config" "$AI_LOG_MAX_BYTES" "$AI_LOG_BACKUPS" "$1" "$2" <<'PY'
import pathlib,sys,logging,logging.handlers,fcntl,os
root=pathlib.Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True,mode=0o700)
with (root/'log.lock').open('a') as lock:
    os.fchmod(lock.fileno(),0o600)
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
# Named-task context: old singleton configurations remain usable unchanged.
air_task_context() {
    local selector="$1"
    AIR_BASE_CONFIG="$BACKUP_DIR/config"
    AIR_BASE_APP_ID="${AIR_BASE_APP_ID:-$AI_APP_ID}"
    if [[ "$selector" == *@* ]]; then
        AIR_TASK_KIND="${selector%%@*}"
        AIR_TASK_NAME="${selector#*@}"
        [[ "$AIR_TASK_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { air_error '配置名称无效'; return 1; }
        [[ "$AIR_TASK_KIND" == ssh-backup || "$AIR_TASK_KIND" == ssh || "$AIR_TASK_KIND" == s3 ]] || return 1
        REMOTE_DIR="$AIR_BASE_CONFIG/tasks/$AIR_TASK_NAME"
        RETENTION_FILE="$REMOTE_DIR/local-retention.json"
        AI_APP_ID="$AIR_BASE_APP_ID-task-$AIR_TASK_NAME"
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
import sys,re
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
    local scope="${1:-all}" selector dir kind idx=0 title group
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
            python3 - "$dir/$kind.json" "$idx" "$selector" "$AI_APP_ID" <<'PY_NSUMMARY'
import sys,json,subprocess
p,index,selector,base_app=sys.argv[1:]; d=json.load(open(p));kind=selector.split('@')[0]
app=base_app+'-task-'+selector.split('@')[1] if '@' in selector else base_app
unit='ai-'+app+'-backup-'+kind+'.timer'
try: active=subprocess.run(['systemctl','is-active','--quiet',unit],capture_output=True,timeout=2).returncode==0
except (OSError,subprocess.TimeoutExpired): active=False
state='\033[32m正常（定时运行中）\033[0m' if active else '\033[33m异常（定时未运行）\033[0m'
name=''.join(c for c in str(d.get('name',selector)) if c.isprintable())
interval=str(d.get('interval','7d')); unit_label='小时' if interval.endswith('h') else '天'
timing='每30秒检测新备份并传送' if d.get('action')=='transfer' else '每'+interval[:-1]+unit_label+' '+str(d.get('calendar',''))+'（北京时间）'
print(index+'. '+name+'   '+state+'  '+timing)
PY_NSUMMARY
        done
        [ "$found" = 1 ] || printf '\033[31m暂无\033[0m\n'
        [ "$group" != ssh-backup ] && echo '==================================' || echo '------------------------'
    done
}
air_repair_remote_schedules() {
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
        echo "$AI_APP_LABEL ${scope^^} 远程备份配置"
        echo '=================================='
        air_named_summary "$scope"
        if [ "$scope" = ssh ]; then
            echo '1. 添加SSH备份任务（定时备份并上传）'
            echo '2. 添加传送任务（有新备份直接传送，不打包）'
        else echo '1. 添加S3任务（有新备份直接传送，不打包）'; fi
        echo '7. 测试远端读取';echo '8. 立即执行任务';echo '9. 删除任务（保留备份）';echo '0. 返回'
        read -r -p '请输入选项：' choice || return 0
        case "$choice" in
            1|2)
                if [ "$scope" = s3 ]; then [ "$choice" = 1 ] || continue; target=s3
                elif [ "$choice" = 1 ]; then target=ssh-backup; else target=ssh; fi
                read -r -p '配置名称（小写字母开头，数字/横线/下划线，最多32位）: ' name || return 0
                [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo '名称无效'; continue; }
                air_named_task_available "$name" || continue
                air_configuration_locked "$target@$name" air_named_configure "$target" || echo '任务添加未完成，已保存配置可在重开菜单时重试定时修复。'
                ;;
            7|8|9)
                mapfile -t selectors < <(air_task_selectors "$scope")
                read -r -p '任务编号（0返回）: ' selected || return 0
                [ "$selected" != 0 ] || continue
                [[ "$selected" =~ ^[1-9][0-9]*$ ]] && [ "$selected" -le "${#selectors[@]}" ] || { echo '编号无效'; continue; }
                target="${selectors[$((selected-1))]}"
                case "$choice" in
                    7) air_remote_engine test "$target" ;;
                    8) air_remote_locked_run "$target" ;;
                    9) IFS= read -r -p '输入yes删除该任务（保留备份）: ' confirm; [ "$confirm" != yes ] || air_configuration_locked "$target" air_delete_remote_task "${target%%@*}" ;;
                esac
                ;;
            0) return 0 ;;
            *) echo 无效选项 ;;
        esac
    done
}
air_named_task_available() {
    python3 - "$BACKUP_DIR/config/tasks/$1" <<'PY_AVAILABLE'
import os,sys,stat,fcntl,json
from pathlib import Path
p=Path(sys.argv[1]);held=[]
try:
    if p.is_symlink():raise ValueError('配置目录不能是链接')
    if not p.exists():sys.exit(0)
    if not p.is_dir():raise ValueError('配置路径不是目录')
    for f in p.iterdir():
        locks=('configuration.lock','ssh.lock','ssh-backup.lock','s3.lock')
        allowed=locks+('local-retention.json','ssh-known-hosts','ssh-backup-known-hosts','s3-known-hosts')
        if f.name not in allowed:raise ValueError('同名配置目录 '+str(p)+' 存在文件 '+repr(f.name)+'，未覆盖')
        fd=os.open(f,(os.O_RDWR if f.name in locks else os.O_RDONLY)|os.O_NOFOLLOW);held.append(fd)
        st=os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError('配置/锁文件不安全')
        if f.name in locks:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        elif f.name=='local-retention.json':
            if st.st_size>4096:raise ValueError('保留数量配置过大')
            with os.fdopen(os.dup(fd)) as stream:v=json.load(stream)
            if not isinstance(v,dict) or set(v)!={'keep'} or type(v['keep']) is not int or not 1<=v['keep']<=100000:raise ValueError('保留数量配置无效')
        elif st.st_size>1048576:raise ValueError('主机指纹文件过大')
except BlockingIOError:sys.exit('同名任务正在配置或执行，请稍后重试')
except (ValueError,OSError) as e:sys.exit(str(e))
finally:
    for fd in held:os.close(fd)
PY_AVAILABLE
}

air_named_configure() {
    local kind="$1" existing
    for existing in ssh ssh-backup s3; do
        if [[ -e "$REMOTE_DIR/$existing.json" || -e "$REMOTE_DIR/$existing.conf" ]]; then
            echo '本应用同名任务配置已存在，未覆盖。' >&2; return 1
        fi
    done
    if [ "$kind" = ssh-backup ]; then air_configure_local_retention || return 1; fi
    air_remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    air_remote_schedule_unlocked "$kind" enable
}




air_manager_init() {
    BACKUP_PREFIX="backrest-"
    REMOTE_DIR="$BACKUP_DIR/config"
    LOCK_FILE="$REMOTE_DIR/backup.lock"
    RETENTION_FILE="$REMOTE_DIR/local-retention.json"
    AI_APP_ID=backrest
    AIR_BASE_APP_ID=backrest
    AI_APP_LABEL=Backrest
    AI_MANAGER_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
    air_init
}

ai_local_backup() {
    local BR_BACKUP_RESULT_FILE rc=0
    BR_BACKUP_RESULT_FILE=$(mktemp "$REMOTE_DIR/.backrest-result.XXXXXX") || return 1
    AI_NEW_ARCHIVE=
    host_tz=$(br_timezone)
    br_backup || rc=$?
    if [ "$rc" -eq 0 ]; then
        IFS= read -r AI_NEW_ARCHIVE < "$BR_BACKUP_RESULT_FILE" || rc=1
    fi
    rm -f -- "$BR_BACKUP_RESULT_FILE"
    [ "$rc" -eq 0 ] && [ -n "$AI_NEW_ARCHIVE" ] && [ -f "$AI_NEW_ARCHIVE" ]
}

br_remote_dispatch() {
    [ "$EUID" -eq 0 ] || { echo "❌ 请使用 root 运行远程任务。"; return 1; }
    air_manager_init || return 1
    case "${1:-}" in
        --remote-task)
            [[ ${2:-} =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 1
            [[ ${3:-} == ssh-backup || ${3:-} == ssh || ${3:-} == s3 ]] || return 1
            [[ -z ${4:-} || ${4:-} == --scheduled ]] || return 1
            air_remote_locked_run "$3@$2" "${4:-}"
            ;;
        --remote)
            [[ ${2:-} == ssh-backup || ${2:-} == ssh || ${2:-} == s3 ]] || return 1
            [[ -z ${3:-} || ${3:-} == --scheduled ]] || return 1
            air_remote_locked_run "$2" "${3:-}"
            ;;
        *) return 1 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case "${1:-}" in
        --remote|--remote-task) br_remote_dispatch "$@" ;;
        "") main ;;
        *) echo "❌ 未知参数。" >&2; exit 1 ;;
    esac
fi
