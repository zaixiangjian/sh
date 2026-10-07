#!/usr/bin/env bash
# 从 /root/kejilion.sh 86 号原样导出。

# 官方镜像来源：https://github.com/garethgeorge/backrest#docker
# 所有模式共用同一个 backrest 实例，不自动切换镜像来源。
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
    local image=$1
    mkdir -p "$app_base_dir"/{data,config,cache,tmp,rclone} || return 1
    sudo docker run -d --name "$docker_name" --hostname "$docker_name" --restart unless-stopped \
        -v "$app_base_dir/data:/data" -v "$app_base_dir/config:/config" \
        -v "$app_base_dir/cache:/cache" -v "$app_base_dir/tmp:/tmp" \
        -v "$app_base_dir/rclone:/root/.config/rclone" -v /home:/userdata/home \
        -e BACKREST_DATA=/data -e BACKREST_CONFIG=/config/config.json \
        -e XDG_CACHE_HOME=/cache -e TMPDIR=/tmp -e "TZ=$host_tz" \
        -p "$host_port:$container_port" "$image" >/dev/null && br_ready
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
br_official_update() {
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    br_matches "$official_docker_img" || return 1
    # 读取现有 Docker 配置；不生成/重置 config.json 或账号密码。
    python3 - "$docker_name" "$official_docker_img" "$app_base_dir" <<'PY'
import json, subprocess, sys, time, uuid
name, image, base = sys.argv[1:]
def docker(*args, capture=False):
    return subprocess.check_output(['sudo','docker',*args], text=True) if capture else subprocess.check_call(['sudo','docker',*args], stdout=subprocess.DEVNULL)
try:
    c = json.loads(docker('container','inspect',name,capture=True))[0]
    if c['Config']['Image'] != image: raise ValueError('镜像来源不匹配')
    expected = {'/data':base+'/data','/config':base+'/config','/cache':base+'/cache','/tmp':base+'/tmp','/root/.config/rclone':base+'/rclone','/userdata/home':'/home'}
    mounts = c['Mounts']
    if {m['Destination']:m['Source'] for m in mounts} != expected or any(m['Type']!='bind' for m in mounts):
        raise ValueError('挂载不属于本脚本布局，拒绝自动重建')
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
    docker('rename',name,old)
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
    print('✅ 官方镜像已拉取并重建；保留现有环境、挂载、端口和配置。')
except Exception as e:
    # 不打印 Docker JSON/环境变量，避免暴露凭据。
    print('❌ 官方更新失败：'+(str(e) if isinstance(e,(ValueError,RuntimeError)) else 'Docker 操作失败，请检查实例状态。'),file=sys.stderr)
    sys.exit(1)
PY
}
br_backup() (
    local image=$1 prefix=$2 running=false backup_file
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    br_exists && br_matches "$image" || return 1
    [ -d "$app_base_dir" ] && [ ! -L "$app_base_dir" ] || return 1
    if br_running; then sudo docker stop "$docker_name" >/dev/null || return 1; running=true; fi
    trap 'if $running; then sudo docker start "$docker_name" >/dev/null || echo "❌ 备份后重启失败，请手动检查。"; fi' EXIT
    backup_file=$(python3 - "$prefix" <<'PY'
import os,sys,time
while True:
    p='/home/'+sys.argv[1]+'-'+time.strftime('%Y%m%d%H%M%S')+'.tar.gz'
    try:
        fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600); os.close(fd); print(p); break
    except FileExistsError: time.sleep(1)
PY
    ) || return 1
    if ! tar -czf "$backup_file" --exclude='docker/backrest/cache' --exclude='docker/backrest/tmp' --exclude='docker/backrest/logs' -C "$(dirname "$(dirname "$app_base_dir")")" docker/backrest; then
        rm -f -- "$backup_file"; echo "❌ 备份失败。"; return 1
    fi
    chmod 600 "$backup_file" || return 1
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
br_restore() (
    local image=$1 prefix=$2 selection confirm stage rollback running=false existed=false file
    local -a files=()
    command -v python3 >/dev/null || { echo "❌ 需要 Python 3。"; return 1; }
    if br_exists; then existed=true; br_matches "$image" || return 1; br_running && running=true; fi
    mapfile -t files < <(compgen -G "/home/$prefix-*.tar.gz" | LC_ALL=C sort -r)
    [ ${#files[@]} -gt 0 ] || { echo "没有找到备份。"; return 1; }
    echo "检测到以下备份文件："
    local i
    for i in "${!files[@]}"; do echo "$((i+1)). ${files[i]##*/}"; done
    IFS= read -r -p "请选择要恢复的备份编号（回车恢复最新备份，0 取消）: " selection || return 1
    selection=${selection:-1}
    [[ $selection =~ ^[1-9][0-9]*$ ]] && [ ${#selection} -le 6 ] && [ "$selection" -le "${#files[@]}" ] || { echo "已取消或编号无效。"; return 1; }
    file=${files[selection-1]}
    [ -f "$file" ] && [ ! -L "$file" ] || { echo "❌ 不接受链接备份。"; return 1; }
    echo "将用 ${file##*/} 替换 $app_base_dir；保留恢复前数据，不修改 /home 备份。"
    IFS= read -r -p "输入小写 yes 确认恢复: " confirm || return 1
    [ "$confirm" = yes ] || { echo "已取消恢复。"; return 1; }
    [ ! -L "$app_base_dir" ] || return 1
    stage=$(mktemp -d "${TMPDIR:-/root/.hermes/cache/scratch}/backrest-restore.XXXXXX") || return 1
    trap 'rm -rf -- "$stage"' EXIT
    cp -- "$file" "$stage/archive.tar.gz" && chmod 600 "$stage/archive.tar.gz" || return 1
    br_extract "$stage/archive.tar.gz" "$stage" || return 1
    mkdir -p "$stage/docker/backrest"/{data,config,cache,tmp,rclone} || return 1
    # 回滚数据含凭据；放在 /root，避免 /home:/userdata/home 将其暴露给容器。
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
    echo "将删除容器 $docker_name 和 $app_base_dir 全部数据；保留 /home 备份、源码构建目录、Docker/共享依赖及镜像。"
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

while true; do
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then clear; fi
    echo "------------------------------------------------"
    echo "      Backrest 资源备份工具 管理脚本"
    echo "------------------------------------------------"
    echo "【源码与镜像管理】"
    echo "1. 安装环境并修复 Docker"
    echo "2. 一键克隆源码并完整编译 (前端+后端+Docker)"
    echo "3. 登录 Docker Hub"
    echo "4. 推送镜像到 Docker Hub"
    echo "------------------------------------------------"
    echo "【容器部署管理】"
    echo "11. 部署/启动 Backrest (/home/docker/backrest)"
    echo "12. 更新镜像"
    echo "13. 备份数据"
    echo "14. 恢复备份"
    echo "15. 卸载 Backrest（自制/官方）"
    echo "------------------------------------------------"
    echo "【官方镜像管理】"
    echo "21. 官方安装"
    echo "22. 官方更新"
    echo "23. 备份（官方版）"
    echo "24. 恢复备份（官方版）"

    echo "------------------------------------------------"
    echo "在rclone目录创建"
    echo "rclone.conf"
    echo "添加下面s3代码"
    echo "唯一名称r2"
    echo "[r2]
type = s3
provider = 备注名
access_key_id = 访问id
secret_access_key = 访问密钥
endpoint = s3地址"

    echo "------------------------------------------------"
    echo "0) 返回上一级"
    echo "------------------------------------------------"
    IFS= read -r -p "请输入操作编号: " br_choice || break

    my_github_url="https://github.com/zaixiangjian/backrest.git"
    my_docker_img="zaixiangjian/backrest:latest"
    build_dir="/home/docker/backrest_build"
    app_base_dir="/home/docker/backrest"
    docker_name="backrest"
    host_tz=$(br_timezone)
    host_port="9898"
    container_port="9898"
    data_volume="/data"

    case $br_choice in

    1)
        echo "修复系统环境..."
        sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock
        sudo dpkg --configure -a
        sudo apt --fix-broken install -y
        sudo apt update
        sudo apt install -y git curl ca-certificates

        if ! command -v docker &>/dev/null; then
            curl -fsSL https://get.docker.com | bash -
        fi
        sudo systemctl enable --now docker
        sudo chmod 666 /var/run/docker.sock
        echo "✅ 环境准备完成"
        read -n1 -r -p "回车继续..."
        ;;

    2)
        echo "开始完整构建流程..."

        mkdir -p "$build_dir"
        cd "$build_dir"
        [ -d backrest ] && rm -rf backrest

        git clone --depth 1 "$my_github_url" || {
            echo "❌ Git 克隆失败"
            read -n1 -r -p "回车继续..."
            break
        }

        cd backrest

        # 安装 Node 20
        if ! command -v node &>/dev/null; then
            echo "安装 Node.js 20..."
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt install -y nodejs
        fi

        # 构建前端
        echo "构建 WebUI..."
        cd webui || { echo "找不到 webui 目录"; break; }
        npm install
        npm run build

        if [ ! -d dist ]; then
            echo "❌ 前端构建失败"
            read -n1 -r -p "回车继续..."
            break
        fi

        cd ..

        # 安装 Go
        if ! command -v go &>/dev/null; then
            echo "安装 Go..."
            sudo apt install -y golang
        fi

        # 编译后端
        echo "编译 Go 二进制..."
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -ldflags="-s -w" -o backrest ./cmd/backrest

        if [ ! -f backrest ]; then
            echo "❌ Go 编译失败"
            read -n1 -r -p "回车继续..."
            break
        fi

        # 构建 Docker
        echo "构建 Docker 镜像..."
        sudo docker build \
            --pull \
            --no-cache \
            -t "$my_docker_img" \
            -f Dockerfile.alpine \
            .

        if [ $? -eq 0 ]; then
            echo "✅ 镜像构建成功"
        else
            echo "❌ Docker 构建失败"
        fi

        read -n1 -r -p "回车继续..."
        ;;

    3)
        sudo docker login
        read -n1 -r -p "回车继续..."
        ;;

    4)
        sudo docker push "$my_docker_img"
        read -n1 -r -p "回车继续..."
        ;;

    11)
        if br_exists && ! br_matches "$my_docker_img"; then
            read -n1 -r -p "回车继续..."
            continue
        fi
        echo "正在部署 Backrest..."
        sudo docker rm -f $docker_name &>/dev/null

        mkdir -p "$app_base_dir/data" \
                 "$app_base_dir/config" \
                 "$app_base_dir/cache" \
                 "$app_base_dir/tmp" \
                 "$app_base_dir/rclone"


        sudo docker run -d \
            --name $docker_name \
            --hostname $docker_name \
            --restart unless-stopped \
            -v "$app_base_dir/data:/data" \
            -v "$app_base_dir/config:/config" \
            -v "$app_base_dir/cache:/cache" \
            -v "$app_base_dir/tmp:/tmp" \
            -v "$app_base_dir/rclone:/root/.config/rclone" \
            -v /home:/userdata/home \
            -e BACKREST_DATA=/data \
            -e BACKREST_CONFIG=/config/config.json \
            -e XDG_CACHE_HOME=/cache \
            -e TMPDIR=/tmp \
            -e TZ=$host_tz \
            -p "$host_port:$container_port" \
            $my_docker_img

        if [ $? -eq 0 ]; then
            ip=$(hostname -I | awk '{print $1}')
            echo "✅ 启动成功"
            echo "访问地址: http://$ip:$host_port"
        else
            echo "❌ 启动失败"
        fi
        read -n1 -r -p "回车继续..."
        ;;
    12)
        echo "正在从 Docker Hub 拉取最新镜像..."
        sudo docker pull "$my_docker_img"
        echo "✅ 更新完成"
        read -n1 -r -p "回车继续..."
        ;;
    13)
        br_backup "$my_docker_img" backrest-backup
        read -n1 -r -p "回车继续..."
        ;;
    14)
        br_restore "$my_docker_img" backrest-backup
        read -n1 -r -p "回车继续..."
        ;;
    15)
        br_uninstall
        read -n1 -r -p "回车继续..."
        ;;
    21)
        br_install "$official_docker_img"
        read -n1 -r -p "回车继续..."
        ;;
    22)
        br_official_update
        read -n1 -r -p "回车继续..."
        ;;
    23)
        br_backup "$official_docker_img" Backrest-official
        read -n1 -r -p "回车继续..."
        ;;
    24)
        br_restore "$official_docker_img" Backrest-official
        read -n1 -r -p "回车继续..."
        ;;

    0) break ;;
    *) echo "无效选择"; sleep 1 ;;
    esac
done
