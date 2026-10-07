#!/usr/bin/env bash
# 从 kejilion.sh 75 号提取 OpenList 官方 Docker 安装方式。
# 文件名按用户要求保留 openliat；应用实际名称为 OpenList。
set -o pipefail
APP_DIR=/home/docker/openlist
NAME=openlist
IMAGE=openlistteam/openlist:v4.2.6
pause() { IFS= read -r -p "按回车继续..." _; }
confirm() {
    local answer
    IFS= read -r -p "确认请输入小写 yes：" answer || return 1
    [ "$answer" = yes ]
}
require_docker() {
    command -v docker >/dev/null && docker info >/dev/null 2>&1 || {
        echo "请先安装并启动 Docker。"; return 1;
    }
}
ready() {
    local i
    for i in {1..30}; do
        [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || { sleep 1; continue; }
        if docker exec "$NAME" /opt/openlist/openlist version >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "容器启动验证未通过，请检查 docker logs openlist。"; return 1
}
addresses() {
    local mapping host_port host_ip
    mapping=$(docker port "$NAME" 5244/tcp 2>/dev/null | head -n 1)
    host_port=${mapping##*:}
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "网页端口：${mapping:-未检测到映射}"
    if [ -n "$mapping" ]; then
        echo "访问地址：http://${host_ip:-服务器IP}:$host_port"
        case "$mapping" in 127.0.0.1:*) echo "仅本机绑定，远程访问需 SSH 隧道或反向代理。" ;; esac
    fi
}
show_initial_password() {
    # 仅读取初始化日志；不重置、不猜测密码，不输出整份日志。
    python3 - "$NAME" <<'PYPASSWORD'
import subprocess,re,sys,time
for _ in range(10):
    p=subprocess.run(['docker','logs','--tail','200',sys.argv[1]],capture_output=True,text=True)
    text=re.sub(r'\x1b\[[0-9;]*m','',p.stdout+p.stderr)
    m=re.search(r'initial password is:\s*([^\s]+)',text,re.IGNORECASE)
    if m:
        print('管理员账号：admin')
        print('初始密码：'+m.group(1))
        print('请妥善保存并在登录后修改；这里显示的是初始密码，不代表修改后的密码。')
        break
    if p.returncode: break
    time.sleep(1)
else:
    print('未读取到初始密码。可在服务器运行：docker logs openlist')
PYPASSWORD
}
install_official() {
    require_docker || return 1
    if [ -e "$APP_DIR" ] || docker container inspect "$NAME" >/dev/null 2>&1; then
        echo "目录或同名容器已存在，不覆盖。已有安装请使用 12 号更新。"; return 1
    fi
    local host_port bind
    IFS= read -r -p "请输入地址（回车默认 127.0.0.1；可选 127.0.0.1 或 0.0.0.0）：" bind || return 1
    bind=${bind:-127.0.0.1}
    [[ "$bind" = 127.0.0.1 || "$bind" = 0.0.0.0 ]] || { echo "绑定地址无效。"; return 1; }
    IFS= read -r -p "网页端口（回车默认 5244）：" host_port || return 1
    host_port=${host_port:-5244}
    [[ "$host_port" =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$host_port <= 65535)) || { echo "端口无效。"; return 1; }
    docker pull "$IMAGE" || return 1
    mkdir -p "$APP_DIR/data" || return 1
    chown 1000:1000 "$APP_DIR/data" || return 1
    chmod 755 "$APP_DIR/data"
    docker run -d \
        --name "$NAME" \
        --restart always \
        -p "$bind:$host_port:5244" \
        -v "$APP_DIR/data:/opt/openlist/data" \
        --user 1000:1000 \
        "$IMAGE" || return 1
    ready || return 1
    echo "安装完成（容器运行与程序可执行检查通过，未验证网页登录）。"
    addresses
    show_initial_password
}
install_custom() {
    local IMAGE=zaixiangjian/openliat:latest
    install_official
}
update_custom() {
    local IMAGE=zaixiangjian/openliat:latest
    update_official
}
login_docker() {
    require_docker || return 1
    docker login
}
push_custom() {
    require_docker || return 1
    local source target=zaixiangjian/openliat:latest local_id
    source=$(docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null)
    source=${source:-$IMAGE}
    local_id=$(docker image inspect "$source" -f '{{.Id}}') || { echo "没有可用源镜像，请先安装。"; return 1; }
    echo "将推送本地镜像 $local_id 到 $target，不修改容器。"
    docker tag "$source" "$target" && docker push "$target" || return 1
    docker manifest inspect --verbose "$target" | python3 -c '
import json,sys
x=json.load(sys.stdin)
if not isinstance(x,list): x=[x]
d=[i.get("SchemaV2Manifest",i.get("OCIManifest",{})).get("config",{}).get("digest") for i in x]
if sys.argv[1] not in d:sys.exit("远端摘要不匹配，无法确认推送结果。")
print("远端摘要与本地一致，推送验证通过。")
' "$local_id"
}
update_official() {
    require_docker || return 1
    echo "将更新当前实例，镜像来源：$IMAGE"
    echo "按所选菜单的镜像来源更新；保留实际端口、账号配置及数据。更新前建议自行备份。"
    confirm || { echo "已取消"; return 0; }
    python3 - "$NAME" "$APP_DIR" "$IMAGE" <<'PY'
import subprocess,json,os,tempfile,time
import urllib.request
import pathlib
name,root,image=__import__('sys').argv[1:]
x=json.loads(subprocess.check_output(['docker','inspect',name]))[0]
mounts=x['Mounts'];hc=x['HostConfig'];cfg=x['Config']
if hc['NetworkMode']!='bridge' or len(mounts)!=1 or mounts[0]['Type']!='bind' or mounts[0]['Source']!=root+'/data' or mounts[0]['Destination']!='/opt/openlist/data':
    raise SystemExit('实例挂载/网络与本管理器不符，拒绝自动重建。')
if not cfg['Image'].startswith(('openlistteam/openlist:','zaixiangjian/openliat:')):
    raise SystemExit('非本脚本支持的 OpenList 实例，拒绝自动覆盖。')
if cfg.get('User')!='1000:1000' or hc.get('Privileged') or hc.get('CapAdd') or hc.get('Devices'):
    raise SystemExit('检测到额外运行配置，拒绝自动重建。')
subprocess.run(['docker','pull',image],check=True)
running=x['State']['Running']
backup=tempfile.mkdtemp(prefix='openlist.before-update.',dir=root)
os.chmod(backup,0o700)
f=pathlib.Path(backup)/'container.json';f.write_text(json.dumps(x));f.chmod(0o600)
old=name+'-before-update-'+pathlib.Path(backup).name.rsplit('.',1)[-1]
created=False;renamed=False
try:
    if running:subprocess.run(['docker','stop','--time','30',name],check=True)
    subprocess.run(['docker','rename',name,old],check=True);renamed=True
    env=pathlib.Path(backup)/'runtime.env';env.write_text('\n'.join(cfg['Env'])+'\n');env.chmod(0o600)
    args=['docker','create','--name',name,'--restart',hc['RestartPolicy']['Name'] or 'no','--user',cfg['User'],'--env-file',str(env),'-v',root+'/data:/opt/openlist/data']
    for port,binds in (hc.get('PortBindings') or {}).items():
        for b in binds:
            ip=b['HostIp'];ip=('['+ip+']') if ':' in ip else ip
            args+=['-p',(ip+':' if ip else '')+b['HostPort']+':'+port]
    if cfg.get('Entrypoint'):
        if len(cfg['Entrypoint'])!=1:raise ValueError('不支持多参数 entrypoint')
        args+=['--entrypoint',cfg['Entrypoint'][0]]
    args+=[image]+(cfg.get('Cmd') or [])
    subprocess.run(args,check=True);created=True;env.unlink()
    if running:
        subprocess.run(['docker','start',name],check=True)
        time.sleep(3)
        y=json.loads(subprocess.check_output(['docker','inspect',name]))[0]
        if not y['State']['Running']:raise RuntimeError('更新后容器退出')
    print('更新完成；原容器已停止并保留：'+old+'；原配置：'+str(f))
    print('原先停止的实例保持停止；启动检查不代表网页功能全部验证。')
except BaseException:
    if created:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL)
    if renamed:subprocess.run(['docker','rename',old,name],check=True)
    if running:subprocess.run(['docker','start',name],check=True)
    print('更新失败，已尝试恢复原容器；配置备份：'+backup)
    raise
PY
}
uninstall_app() {
    require_docker || return 1
    echo "支持 1 号自定义安装及 11 号官方安装。"
    echo "将删除 openlist 容器及 $APP_DIR 全部数据。"
    echo "保留 Docker、镜像和 /home 下独立备份。"
    confirm || { echo "已取消"; return 0; }
    if docker container inspect "$NAME" >/dev/null 2>&1; then
        docker rm -f "$NAME" || return 1
    fi
    if [ -L "$APP_DIR" ]; then echo "拒绝删除符号链接应用目录。"; return 1; fi
    rm -rf -- "$APP_DIR" || return 1
    echo "已卸载。更新时保留的旧容器不会自动删除，请确认后自行处理。"
}
main() {
    [ "$(id -u)" -eq 0 ] || { echo "请使用 root 运行。"; return 1; }
    command -v python3 >/dev/null || { echo "缺少 python3。"; return 1; }
    while true; do
        [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && clear
        echo "=================================="
        echo "        OpenList 管理脚本"
        echo "开源网盘聚合程序，支持多种存储"
        echo "开源地址："
        echo "https://github.com/OpenListTeam/OpenList"
        echo "官方镜像：$IMAGE"
        echo "=================================="
        echo "1. 自己安装zaixiangjian/openliat:latest"
        echo "2. 从zaixiangjian更新"
        echo "3. 登录 Docker Hub"
        echo "4. 打上标签推送到zaixiangjian/openliat:latest"
        echo "-----------------------------------"
        echo "9. 卸载（需 yes 确认）"
        echo "-----------------------------------"
        echo "11. 官方安装（默认端口 5244）"
        echo "12. 官方更新"
        echo "-----------------------------------"
        echo "0. 退出"
        echo "-----------------------------------"
        IFS= read -r -p "请输入选项：" choice || return 0
        case "$choice" in
            1) install_custom ;;
            2) update_custom ;;
            3) login_docker ;;
            4) push_custom ;;
            9) uninstall_app ;;
            11) install_official ;;
            12) update_official ;;
            0) echo "已退出"; return 0 ;;
            *) echo "无效选项" ;;
        esac
        pause || return 0
    done
}
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then main "$@"; fi
