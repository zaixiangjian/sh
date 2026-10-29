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

set -Eeuo pipefail

APP_NAME="dujiao-next"
APP_DIR="/home/docker/${APP_NAME}"
BACKUP_DIR="/home/备份/dujiao-next"
DUJIAO_BACKUP_PREFIX="dujiao-next"
BACKUP_PREFIX="$DUJIAO_BACKUP_PREFIX"
COMPOSE_SQLITE="docker-compose.sqlite.yml"
ENV_FILE=".env"
CONFIG_FILE="config/config.yml"
DEFAULT_PORT="8501"
CUSTOM_IMAGE_REPO="zaixiangjian/dujiao-next"
OFFICIAL_IMAGE_REPO="dujiaonext/dujiao-next"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

msg() { echo -e "$*"; }
success() { msg "${GREEN}$*${PLAIN}"; }
warn() { msg "${YELLOW}$*${PLAIN}"; }
error() { msg "${RED}$*${PLAIN}"; }

pause() {
  read -r -p "按回车键继续..." _ || true
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "请使用 root 用户运行此脚本"
    exit 1
  fi
}

rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    random_chars 'A-Fa-f0-9' 64
  fi
}

random_chars() {
  local charset="$1"
  local length="$2"
  # set -o pipefail 下，head 读够后会关闭管道，tr 可能收到 SIGPIPE 返回 141。
  # 随机字符串生成不应因此中断整个安装流程，所以这里临时关闭 pipefail。
  set +o pipefail
  LC_ALL=C tr -dc "${charset}" </dev/urandom | head -c "${length}"
  local rc=$?
  set -o pipefail
  echo
  return "${rc}"
}

random_lower() {
  random_chars 'a-z0-9' "${1:-6}"
}

random_alnum() {
  random_chars 'A-Za-z0-9' "${1:-16}"
}

generate_admin_password() {
  # 20位强密码：包含大写、小写、数字，并补足随机字符。
  echo "Dj$(random_alnum 15)$(random_chars 'A-Z' 1)$(random_chars 'a-z' 1)$(random_chars '0-9' 1)"
}

valid_admin_password() {
  local pass="$1"
  [ "${#pass}" -ge 20 ] || return 1
  [[ "${pass}" =~ [A-Z] ]] || return 1
  [[ "${pass}" =~ [a-z] ]] || return 1
  [[ "${pass}" =~ [0-9] ]] || return 1
}

prompt_admin_password() {
  local pass=""
  while true; do
    read -r -p "请输入默认管理员密码 [默认: 随机生成20位强密码]: " pass
    if [ -z "${pass}" ]; then
      generate_admin_password
      return 0
    fi
    if valid_admin_password "${pass}"; then
      echo "${pass}"
      return 0
    fi
    error "密码不符合要求：至少 20 位，并包含大写字母、小写字母和数字。"
  done
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    error "未检测到 docker compose 插件或 docker-compose"
    return 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    warn "未检测到 Docker，开始安装 Docker..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      . /etc/os-release
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y dnf-plugins-core curl
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
      yum install -y yum-utils curl
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      error "无法自动安装 Docker：未识别的包管理器"
      return 1
    fi
  fi

  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true

  if ! docker info >/dev/null 2>&1; then
    error "Docker 已安装但无法连接 Docker daemon，请检查 Docker 服务状态"
    return 1
  fi

  if ! compose_cmd >/dev/null; then
    error "Docker Compose 不可用，请安装 docker compose 插件后重试"
    return 1
  fi
}

write_compose_file() {
  cat > "${APP_DIR}/${COMPOSE_SQLITE}" <<'YAML'
services:
  redis:
    image: redis:7-alpine
    container_name: dujiaonext-redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command: ["redis-server", "--dir", "/data", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  dujiao-next:
    image: ${IMAGE_REPO}:${TAG}
    container_name: dujiao-next
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      DJ_DEFAULT_ADMIN_USERNAME: ${DJ_DEFAULT_ADMIN_USERNAME}
      DJ_DEFAULT_ADMIN_PASSWORD: ${DJ_DEFAULT_ADMIN_PASSWORD}
    expose:
      - "8080"
    volumes:
      - ./config/config.yml:/app/config.yml:ro
      - ./data/db:/app/db
      - ./data/uploads:/app/uploads
      - ./data/logs:/app/logs
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 10s
      timeout: 3s
      retries: 10
    networks:
      - dujiao-net

  dujiao-next-proxy:
    image: nginx:1.27-alpine
    container_name: dujiao-next-proxy
    restart: unless-stopped
    ports:
      - "${APP_PORT}:80"
    volumes:
      - ./data/admin-assets/dujiao-next-proxy.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      dujiao-next:
        condition: service_healthy
    networks:
      - dujiao-net

networks:
  dujiao-net:
    driver: bridge
YAML
}

write_config_file() {
  local redis_pass="$1"
  local app_secret="$2"
  local jwt_secret="$3"
  local user_jwt_secret="$4"
  local admin_path="$5"

  cat > "${APP_DIR}/${CONFIG_FILE}" <<YAML
app:
 secret_key: ${app_secret}
 totp_issuer: Dujiao-Next

server:
 host: 0.0.0.0
 port: 8080
 mode: release
 trusted_proxies:
 - 127.0.0.1/32
 - ::1/128

web:
 admin_path: "${admin_path}"

log:
 dir: /app/logs
 filename: app.log
 max_size_mb: 100
 max_backups: 7
 max_age_days: 30
 compress: true

database:
 driver: sqlite
 dsn: /app/db/dujiao.db
 pool:
  max_open_conns: 1
  max_idle_conns: 1
  conn_max_lifetime_seconds: 0
  conn_max_idle_time_seconds: 0

jwt:
 secret: ${jwt_secret}
 expire_hours: 24

user_jwt:
 secret: ${user_jwt_secret}
 expire_hours: 24
 remember_me_expire_hours: 168

bootstrap:
 default_admin_username: "${admin_user}"
 default_admin_password: "${admin_pass}"

redis:
 enabled: true
 host: redis
 port: 6379
 password: "${redis_pass}"
 db: 0
 prefix: "dj"

queue:
 enabled: true
 host: redis
 port: 6379
 password: "${redis_pass}"
 db: 1
 concurrency: 10
 queues:
  default: 10
  critical: 5

upload:
 max_size: 10485760
 allowed_types:
 - image/jpeg
 - image/png
 - image/gif
 - image/webp
 - image/svg+xml
 allowed_extensions:
 - .jpg
 - .jpeg
 - .png
 - .gif
 - .webp
 - .svg
 max_width: 4096
 max_height: 4096

cors:
 allowed_origins:
 - "*"
 allowed_methods:
 - GET
 - POST
 - PUT
 - PATCH
 - DELETE
 - OPTIONS
 allowed_headers:
 - Content-Type
 - Content-Length
 - Accept-Encoding
 - Authorization
 - Cache-Control
 - X-Requested-With
 - X-CSRF-Token
 allow_credentials: true
 max_age: 600
YAML
}

write_env_file() {
  local image_repo="$1"
  local app_port="$2"
  local admin_user="$3"
  local admin_pass="$4"
  local redis_pass="$5"

  cat > "${APP_DIR}/${ENV_FILE}" <<EOF
IMAGE_REPO=${image_repo}
TAG=latest
TZ=Asia/Shanghai
APP_PORT=${app_port}
DJ_DEFAULT_ADMIN_USERNAME=${admin_user}
DJ_DEFAULT_ADMIN_PASSWORD=${admin_pass}
REDIS_PASSWORD=${redis_pass}
EOF
  chmod 600 "${APP_DIR}/${ENV_FILE}"
}

write_proxy_conf() {
  mkdir -p "${APP_DIR}/data/admin-assets"
  if [ -d "${APP_DIR}/data/admin-assets/dujiao-next-proxy.conf" ]; then
    rm -rf "${APP_DIR}/data/admin-assets/dujiao-next-proxy.conf"
  fi
  cat > "${APP_DIR}/data/admin-assets/dujiao-next-proxy.conf" <<'NGINX'
server {
    listen 80;
    server_name _;

    client_max_body_size 20m;

    location / {
        proxy_pass http://dujiao-next:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
}

ensure_dirs() {
  mkdir -p "${APP_DIR}/config" "${APP_DIR}/data/db" "${APP_DIR}/data/uploads" "${APP_DIR}/data/logs" "${APP_DIR}/data/redis" "${APP_DIR}/data/admin-assets"
  chmod -R 0777 "${APP_DIR}/data/logs" "${APP_DIR}/data/db" "${APP_DIR}/data/uploads" "${APP_DIR}/data/redis"
  write_proxy_conf
}

show_status() {
  echo
  msg "${BLUE}Dujiao-Next 管理脚本${PLAIN}"
  echo "安装目录：${APP_DIR}"
  echo "备份目录：${BACKUP_DIR}/${BACKUP_PREFIX}_*.tar.gz"
  if [ -d "${APP_DIR}" ]; then
    success "状态：目录已存在"
  else
    warn "状态：未安装"
  fi
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'dujiao-next'; then
    success "容器：dujiao-next 运行中"
  elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'dujiao-next'; then
    warn "容器：dujiao-next 已创建但未运行"
  else
    warn "容器：未创建"
  fi
  echo
}

dujiao_proxy_manual_hint() {
  warn '安装/更新或可信代理同步失败，请手动获取实际地址，核对 config/config.yml 的 server.trusted_proxies：'
  cat <<'HINT'
docker inspect dujiao-next dujiao-next-proxy --format '{{.Name}} {{range $name, $net := .NetworkSettings.Networks}}网络={{$name}} IP={{$net.IPAddress}} 网关={{$net.Gateway}} {{end}}'
HINT
}

dujiao_sync_trusted_proxies() {
  python3 - "$APP_DIR/$CONFIG_FILE" <<'PY_PROXY'
import subprocess,json,ipaddress,pathlib,re
p=pathlib.Path(__import__('sys').argv[1])
items=json.loads(subprocess.run(['docker','inspect','dujiao-next','dujiao-next-proxy'],check=True,capture_output=True,text=True).stdout)
byname={x['Name'].lstrip('/'):x for x in items}
app=byname['dujiao-next']['NetworkSettings']['Networks']; proxy=byname['dujiao-next-proxy']['NetworkSettings']['Networks']
common=set(app)&set(proxy)
if len(common)!=1:raise ValueError('无法唯一确定应用与代理的共同网络')
net=proxy[common.pop()]; addresses=[]
for key in ['IPAddress','Gateway','GlobalIPv6Address','IPv6Gateway']:
 value=net.get(key)
 if value:
  ip=ipaddress.ip_address(value)
  if ip.is_unspecified or ip.is_loopback:raise ValueError('代理地址异常')
  addresses.append(str(ip)+'/'+str(ip.max_prefixlen))
if not net.get('IPAddress') or not net.get('Gateway'):raise ValueError('代理IPv4或网关为空')
if p.is_symlink() or not p.is_file():raise ValueError('配置文件不存在或是符号链接')
text=p.read_text(); lines=text.splitlines(True)
starts=[i for i,l in enumerate(lines) if re.match(r'^server:\s*(?:#.*)?$',l.strip('\n'))]
if len(starts)!=1:raise ValueError('server配置结构不明确')
a=starts[0]+1;b=next((i for i in range(a,len(lines)) if re.match(r'^[^\s#][^:]*:',lines[i])),len(lines))
keys=[i for i in range(a,b) if re.match(r'^\s+trusted_proxies:\s*(?:#.*)?$',lines[i].rstrip('\n'))]
if len(keys)!=1:raise ValueError('trusted_proxies不是受支持的块列表，请人工核对')
k=keys[0];end=k+1
while end<b and (re.match(r'^\s*-\s+',lines[end]) or not lines[end].strip() or lines[end].lstrip().startswith('#')):end+=1
old=lines[k+1:end]; indent=re.match(r'^(\s*)',lines[k]).group(1)
kept=[l for l in old if '# dujiao-managed-proxy' not in l]
existing=set()
for l in kept:
 m=re.match(r'^\s*-\s*[\'"]?([^\s\'"#]+)',l)
 if m:existing.add(m.group(1))
added=[indent+'- '+v+' # dujiao-managed-proxy\n' for v in dict.fromkeys(addresses) if v not in existing]
new=''.join(lines[:k+1]+kept+added+lines[end:])
# Preserve inode for the existing Docker file bind mount. Do not print configuration/secrets.
if new!=text:
 with p.open('r+') as f:
  f.write(new);f.truncate();f.flush();__import__('os').fsync(f.fileno())
print('可信代理已核对：'+', '.join(addresses))
PY_PROXY
  local rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  docker restart dujiao-next >/dev/null || return 1
}

install_dujiao() {
  local image_repo="${1:-${CUSTOM_IMAGE_REPO}}"
  local mode_name="${2:-镜像}"
  require_root
  install_docker

  local app_port admin_path admin_user admin_pass redis_pass app_secret jwt_secret user_jwt_secret
  if [ -e "${APP_DIR}/${COMPOSE_SQLITE}" ]; then
    warn "检测到 ${APP_DIR} 已存在，安装操作将保留现有配置并切换/启动服务。"
    read -r -p "是否继续？[Y/n]: " yn
    case "${yn:-Y}" in
      y|Y) ;;
      *) return 0 ;;
    esac
    ensure_dirs
    write_compose_file
    if [ -f "${APP_DIR}/${ENV_FILE}" ]; then
      if grep -q "^IMAGE_REPO=" "${APP_DIR}/${ENV_FILE}"; then
        sed -i "s#^IMAGE_REPO=.*#IMAGE_REPO=${image_repo}#" "${APP_DIR}/${ENV_FILE}"
      else
        sed -i "1iIMAGE_REPO=${image_repo}" "${APP_DIR}/${ENV_FILE}"
      fi
    else
      read -r -p "请输入公网访问端口 [默认: ${DEFAULT_PORT}]: " app_port
      app_port="${app_port:-${DEFAULT_PORT}}"
      read -r -p "请输入默认管理员账号 [默认: admin]: " admin_user
      admin_user="${admin_user:-admin}"
      admin_pass="$(prompt_admin_password)"
      redis_pass="$(rand_hex)"
      write_env_file "${image_repo}" "${app_port}" "${admin_user}" "${admin_pass}" "${redis_pass}"
    fi
  else
    read -r -p "请输入公网访问端口 [默认: ${DEFAULT_PORT}]: " app_port
    app_port="${app_port:-${DEFAULT_PORT}}"
    local default_admin_path
    default_admin_path="/dj-mgmt-$(random_lower 6)"
    read -r -p "请输入后台入口路径 [默认: ${default_admin_path}]: " admin_path
    if [ -z "${admin_path}" ]; then
      admin_path="${default_admin_path}"
    fi
    [[ "${admin_path}" == /* ]] || admin_path="/${admin_path}"
    read -r -p "请输入默认管理员账号 [默认: admin]: " admin_user
    admin_user="${admin_user:-admin}"
    admin_pass="$(prompt_admin_password)"

    redis_pass="$(rand_hex)"
    app_secret="$(rand_hex)"
    jwt_secret="$(rand_hex)"
    user_jwt_secret="$(rand_hex)"

    ensure_dirs
    write_env_file "${image_repo}" "${app_port}" "${admin_user}" "${admin_pass}" "${redis_pass}"
    write_config_file "${redis_pass}" "${app_secret}" "${jwt_secret}" "${user_jwt_secret}" "${admin_path}"
    write_compose_file
  fi
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" pull || { dujiao_proxy_manual_hint; return 1; }
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" up -d || { dujiao_proxy_manual_hint; return 1; }
  dujiao_sync_trusted_proxies || { dujiao_proxy_manual_hint; return 1; }

  success "Dujiao-Next ${mode_name}安装/启动完成"
  echo
  app_port="$(grep -E '^APP_PORT=' "${APP_DIR}/${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  admin_path="$(grep -E '^web:[[:space:]]*$|^[[:space:]]*admin_path:' "${APP_DIR}/${CONFIG_FILE}" 2>/dev/null | awk -F': ' '/admin_path:/ {gsub(/"/, "", $2); print $2; exit}' || true)"
  admin_user="$(grep -E '^DJ_DEFAULT_ADMIN_USERNAME=' "${APP_DIR}/${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  admin_pass="$(grep -E '^DJ_DEFAULT_ADMIN_PASSWORD=' "${APP_DIR}/${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  echo "访问地址：http://服务器IP:${app_port:-${DEFAULT_PORT}}"
  [ -n "${admin_path}" ] && echo "后台路径：http://服务器IP:${app_port:-${DEFAULT_PORT}}${admin_path}"
  [ -n "${admin_user}" ] && echo "默认管理员账号：${admin_user}"
  [ -n "${admin_pass}" ] && echo "默认管理员密码：${admin_pass}"
  echo "安装目录：${APP_DIR}"
  echo "配置文件：${APP_DIR}/${CONFIG_FILE}"
  echo "镜像：${image_repo}:latest"
  echo "更新命令：bash /root/dujiao-next.sh 选择 2或者12"
}

update_dujiao() {
  local image_repo="${1:-}"
  require_root
  install_docker
  if [ ! -f "${APP_DIR}/${COMPOSE_SQLITE}" ]; then
    error "未找到 ${APP_DIR}/${COMPOSE_SQLITE}，请先安装"
    return 1
  fi
  if [ -n "${image_repo}" ]; then
    if grep -q "^IMAGE_REPO=" "${APP_DIR}/${ENV_FILE}"; then
      sed -i "s#^IMAGE_REPO=.*#IMAGE_REPO=${image_repo}#" "${APP_DIR}/${ENV_FILE}"
    else
      sed -i "1iIMAGE_REPO=${image_repo}" "${APP_DIR}/${ENV_FILE}"
    fi
  elif ! grep -q "^IMAGE_REPO=" "${APP_DIR}/${ENV_FILE}"; then
    sed -i "1iIMAGE_REPO=${CUSTOM_IMAGE_REPO}" "${APP_DIR}/${ENV_FILE}"
  fi
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" pull || { dujiao_proxy_manual_hint; return 1; }
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" up -d || { dujiao_proxy_manual_hint; return 1; }
  dujiao_sync_trusted_proxies || { dujiao_proxy_manual_hint; return 1; }
  success "更新完成"
}


docker_login() {
  require_root
  install_docker
  docker login
}

push_custom_image() {
  require_root
  install_docker
  local src_image="${OFFICIAL_IMAGE_REPO}:latest"
  local dst_image="${CUSTOM_IMAGE_REPO}:latest"

  warn "将官方镜像 ${src_image} 打标签为 ${dst_image} 后推送。"
  warn "已有同名目标标签会更新，不直接推送旧的目标镜像。"
  warn "请确认已执行 3 登录 Docker，并且当前账号有 ${CUSTOM_IMAGE_REPO} 的推送权限。"
  read -r -p "确认推送？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消推送"; return 0 ;;
  esac
  if ! docker image inspect "$src_image" >/dev/null 2>&1; then
    warn "本地没有 ${src_image}，先拉取官方镜像..."
    docker pull "$src_image" || { error '官方镜像拉取失败，未打标签或推送'; return 1; }
  fi
  docker tag "$src_image" "$dst_image" || { error '打标签失败，未推送'; return 1; }
  docker push "$dst_image" || { error '镜像推送失败'; return 1; }
  success "已打标签并推送镜像：${dst_image}"
}

is_stack_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^(dujiao-next|dujiaonext-redis)$'
}

stop_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_SQLITE}" ] && command -v docker >/dev/null 2>&1; then
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd 2>/dev/null || true)"
    if [ -n "${dc}" ]; then
      ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" down || true
      return 0
    fi
  fi
  docker stop dujiao-next dujiaonext-redis >/dev/null 2>&1 || true
}

start_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_SQLITE}" ]; then
    install_docker
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd)"
    ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" up -d
  fi
}

backup_dujiao() {
  require_root
  if [ ! -d "${APP_DIR}" ]; then
    error "未找到安装目录：${APP_DIR}"
    return 1
  fi

  mkdir -p "${BACKUP_DIR}"
  local ts archive was_running=0
  ts="$(date +%Y%m%d-%H%M%S)"
  archive="${BACKUP_DIR}/${BACKUP_PREFIX}-${ts}.tar.gz"

  local partial="${archive}.partial"
  native_archive_reserve "$partial" || return 1

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证备份一致性..."
    stop_stack
  fi

  local rc=0
  (umask 077; tar -C "$(dirname "$APP_DIR")" -czf "$partial" "$(basename "$APP_DIR")") || rc=$?
  if [ "$rc" -eq 0 ]; then native_archive_publish "$partial" "$archive" || rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$partial"
    if [ "$was_running" -eq 1 ]; then start_stack || error '备份失败且服务恢复启动失败'; fi
    return "$rc"
  fi

  if [ "${was_running}" -eq 1 ]; then
    warn "备份完成，正在恢复启动服务..."
    start_stack || return 1
  fi

  AI_NEW_ARCHIVE="$archive"
  success "备份完成：${archive}"
}

select_backup() {
  python3 - "$BACKUP_DIR" <<'PY_SELECT'
import pathlib,sys
roots={pathlib.Path('/home'),pathlib.Path(sys.argv[1])}
files=sorted({p for root in roots if root.is_dir() for p in root.glob('*.tar.gz') if p.is_file() and not p.is_symlink()},key=lambda p:p.stat().st_mtime_ns,reverse=True)
if not files: print('未找到备份文件',file=sys.stderr);sys.exit(1)
for i,p in enumerate(files,1):print(str(i)+'. '+str(p),file=sys.stderr)
with open('/dev/tty','r+') as tty:
 tty.write('回车恢复最新备份，输入序号选择，0返回：');tty.flush();choice=tty.readline().strip()
if choice=='0':sys.exit(1)
if not choice:print(files[0])
elif choice.isdigit() and 1<=int(choice)<=len(files):print(files[int(choice)-1])
else:print('序号无效',file=sys.stderr);sys.exit(1)
PY_SELECT
}

restore_dujiao() {
  require_root
  install_docker
  local archive
  archive="$(select_backup)" || return 1

  python3 - "$archive" "$APP_NAME" <<'PY_VALIDATE' || return 1
import sys,tarfile,pathlib,gzip
with gzip.open(sys.argv[1],'rb') as f:
 while f.read(1048576):pass
with tarfile.open(sys.argv[1],'r:gz') as t:
 members=t.getmembers()
 if not members:raise ValueError('空备份')
 for m in members:
  p=pathlib.PurePosixPath(m.name)
  if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0]!=sys.argv[2] or not (m.isdir() or m.isfile()):raise ValueError('备份路径或类型不安全')
PY_VALIDATE
  warn "即将从备份恢复：${archive}"
  warn "当前目录会移动为 ${APP_DIR}.before_restore_时间戳"
  read -r -p "确认恢复？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消恢复"; return 0 ;;
  esac

  stop_stack

  mkdir -p "/home/docker"
  local ts old_dir
  ts="$(date +%Y%m%d%H%M%S)"
  old_dir="${APP_DIR}.before_restore_${ts}"
  if [ -e "${APP_DIR}" ]; then
    mv "${APP_DIR}" "${old_dir}"
  fi

  if tar -C "/home/docker" -xzf "${archive}"; then
    if [ ! -d "${APP_DIR}" ]; then
      error "备份结构不正确：解压后未找到 ${APP_DIR}"
      rm -rf "${APP_DIR}"
      [ -d "${old_dir}" ] && mv "${old_dir}" "${APP_DIR}"
      return 1
    fi
    start_stack
    success "恢复完成，已启动服务"
    [ -d "${old_dir}" ] && warn "旧目录保留在：${old_dir}"
  else
    error "解压失败，正在回滚..."
    rm -rf "${APP_DIR}"
    [ -d "${old_dir}" ] && mv "${old_dir}" "${APP_DIR}"
    return 1
  fi
}

uninstall_dujiao() {
  require_root
  warn "此操作将停止并删除 Dujiao-Next 容器与安装目录：${APP_DIR}"
  warn "不会删除 /home 下已有备份文件。"
  read -r -p "确认卸载？请输入 yes：" confirm
  if [ "${confirm}" != "yes" ]; then
    warn "已取消卸载"
    return 0
  fi
  bsl_engine purge || { error "本地定时备份清理失败，取消卸载"; return 1; }
  stop_stack
  docker rm -f dujiao-next dujiaonext-redis >/dev/null 2>&1 || true
  rm -rf "${APP_DIR}"
  success "卸载完成"
}

# Reusable adaptation of CLIProxyAPI.sh original single-kind SSH/S3 engine.
# Parent supplies BACKUP_DIR BACKUP_PREFIX (including separator), REMOTE_DIR,
# LOCK_FILE RETENTION_FILE AI_APP_ID AI_APP_LABEL and ai_local_backup.
# Set AI_MANAGER_SCRIPT to the installed parent manager for systemd ExecStart.
# Source only defines functions; never installs timers or executes backups.
air_init() {
    [[ ${AI_APP_ID:-} == openclaw || ${AI_APP_ID:-} == hermes || ${AI_APP_ID:-} == dujiao-next ]] || return 1
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
            keep=d.get('keep',3)
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
        echo "$AI_APP_LABEL ${scope^^} 远程备份配置"
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
                air_named_task_available "$name" || continue
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
    BACKUP_PREFIX="${DUJIAO_BACKUP_PREFIX}-"
    REMOTE_DIR="$BACKUP_DIR/config"
    LOCK_FILE="$BACKUP_DIR/backup.lock"
    RETENTION_FILE="$REMOTE_DIR/local-retention.json"
    AI_APP_ID=dujiao-next
    AI_APP_LABEL=Dujiao-Next
    AI_MANAGER_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
    air_init
}
ai_local_backup() {
    AI_NEW_ARCHIVE=
    local prefix="$BACKUP_PREFIX" rc=0
    BACKUP_PREFIX="$DUJIAO_BACKUP_PREFIX"
    backup_dujiao || rc=$?
    BACKUP_PREFIX="$prefix"
    [ "$rc" -eq 0 ] && [ -n "$AI_NEW_ARCHIVE" ] && [ -f "$AI_NEW_ARCHIVE" ]
}
main_menu() {
  require_root
  air_manager_init || return 1
  air_ensure_environment || return 1
  air_repair_remote_schedules || warn '部分定时任务修复失败'
  while true; do
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    echo '=================================='
    echo '    Dujiao-Next 管理脚本'
    echo '数字商品自动交付与订单管理系统'
    echo '开源地址'
    echo 'https://github.com/dujiao-next/dujiao-next'
    echo '=================================='
    echo "备份目录：$BACKUP_DIR"
    air_named_summary all
    echo '1. 安装（zaixiangjian/dujiao-next）'
    echo '2. 更新（zaixiangjian/dujiao-next）'
    echo '3. 登录docker'
    echo '4. 推送到docker（zaixiangjian/dujiao-next）'
    echo '5. SSH 远程备份配置'
    echo '6. S3 API 兼容备份配置'
    echo '7. 备份'
    echo '8. 恢复'
    echo '9. 卸载'
    echo '------------------------------------------------'
    echo '11. 安装官方'
    echo '12. 更新官方'
    echo '------------------------------------------------'
    echo '0. 退出'
    read -r -p '请输入选项并回车：' choice || return 0
    case "$choice" in
      1) install_dujiao "$CUSTOM_IMAGE_REPO" '镜像' || error '安装失败'; pause ;;
      2) update_dujiao "$CUSTOM_IMAGE_REPO" || error '更新失败'; pause ;;
      3) docker_login || error '登录失败'; pause ;;
      4) push_custom_image || error '推送失败'; pause ;;
      5) air_remote_menu ssh ;;
      6) air_remote_menu s3 ;;
      7) ( exec 9>"$LOCK_FILE"; flock -n 9 || { error '已有备份或清理任务正在执行'; exit 1; }; ai_local_backup ) || error '备份失败'; pause ;;
      8) restore_dujiao || warn '恢复取消或失败'; pause ;;
      9) uninstall_dujiao || error '卸载失败'; pause ;;
      11) install_dujiao "$OFFICIAL_IMAGE_REPO" '官方' || error '安装失败'; pause ;;
      12) update_dujiao "$OFFICIAL_IMAGE_REPO" || error '更新失败'; pause ;;
      0) return 0 ;;
      *) error '无效选项'; pause ;;
    esac
  done
}

# Local-only scheduled backups: embedded engine, no SSH/S3 credentials.
BSL_ID='dujiao-next'
BSL_LABEL='Dujiao-Next'
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
    python3 - "$BACKUP_DIR" 'dujiao-next-\d{8}-\d{6}\.tar\.gz\.partial' <<'PY_PARTIAL_CLEAN'
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
    BSL_DATA_DIR="$APP_DIR"
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
    if [[ ${1:-} == --remote-task || ${1:-} == --remote ]]; then
        require_root
        air_manager_init || exit 1
        air_ensure_environment || exit 1
        if [[ $1 == --remote-task ]]; then air_remote_locked_run "${3:-}@${2:-}" "${4:-}"
        else air_remote_locked_run "${2:-}" "${3:-}"; fi
    else main_menu; fi
fi
