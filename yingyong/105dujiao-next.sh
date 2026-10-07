#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="dujiao-next"
APP_DIR="/home/docker/${APP_NAME}"
BACKUP_DIR="/home"
BACKUP_PREFIX="dujiao"
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
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" pull
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" up -d

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
  if [ "${image_repo}" = "${OFFICIAL_IMAGE_REPO}" ]; then
    echo "更新命令：bash /root/dujiao-next.sh 选择 12"
  else
    echo "更新命令：bash /root/dujiao-next.sh 选择 2"
  fi
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
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" pull
  ${dc} --env-file "${ENV_FILE}" -f "${COMPOSE_SQLITE}" up -d
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

  if docker image inspect "${dst_image}" >/dev/null 2>&1; then
    warn "检测到本地镜像：${dst_image}"
  else
    if ! docker image inspect "${src_image}" >/dev/null 2>&1; then
      warn "本地没有 ${src_image}，先拉取官方镜像..."
      docker pull "${src_image}"
    fi
    docker tag "${src_image}" "${dst_image}"
  fi

  warn "准备推送镜像：${dst_image}"
  warn "请确认已执行 5 登录 Docker，并且当前账号有 ${CUSTOM_IMAGE_REPO} 的推送权限。"
  read -r -p "确认推送？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消推送"; return 0 ;;
  esac
  docker push "${dst_image}"
  success "已推送镜像：${dst_image}"
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
  ts="$(date +%Y%m%d%H%M%S)"
  archive="${BACKUP_DIR}/${BACKUP_PREFIX}_${ts}.tar.gz"

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证备份一致性..."
    stop_stack
  fi

  tar -C "/home/docker" -czf "${archive}" "${APP_NAME}"

  if [ "${was_running}" -eq 1 ]; then
    warn "备份完成，正在恢复启动服务..."
    start_stack
  fi

  success "备份完成：${archive}"
}

select_backup() {
  shopt -s nullglob
  local files=("${BACKUP_DIR}/${BACKUP_PREFIX}_"*.tar.gz)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    error "未找到备份文件：${BACKUP_DIR}/${BACKUP_PREFIX}_*.tar.gz"
    return 1
  fi

  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -r)
  echo "检测到以下备份：" >&2
  local i
  for i in "${!files[@]}"; do
    if [ "$i" -lt 10 ]; then
      printf '%s. %s\n' "$((i+1))" "${files[$i]}" >&2
    fi
  done
  echo >&2
  read -r -p "请输入备份序号或完整路径（回车默认最新）：" choice >&2 || true
  if [ -z "${choice:-}" ]; then
    echo "${files[0]}"
    return 0
  fi
  if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#files[@]}" ]; then
    echo "${files[$((choice-1))]}"
    return 0
  fi
  if [ -f "${choice}" ]; then
    echo "${choice}"
    return 0
  fi
  error "无效的备份选择：${choice}"
  return 1
}

restore_dujiao() {
  require_root
  install_docker
  local archive
  archive="$(select_backup)" || return 1

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
  stop_stack
  docker rm -f dujiao-next dujiaonext-redis >/dev/null 2>&1 || true
  rm -rf "${APP_DIR}"
  success "卸载完成"
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    show_status
    echo "1. 安装（${CUSTOM_IMAGE_REPO}）"
    echo "2. 更新（${CUSTOM_IMAGE_REPO}）"
    echo "3. 备份（/home/${BACKUP_PREFIX}_YYYYmmddHHMMSS.tar.gz）"
    echo "4. 恢复（从 /home/${BACKUP_PREFIX}_*.tar.gz 获取，回车默认最新）"
    echo "5. 登录docker"
    echo "7. 推送到docker（${CUSTOM_IMAGE_REPO}）"
    echo "8. 卸载"
    echo "------------------------------------------------"
    echo "11. 安装官方"
    echo "12. 更新官方"
    echo "13. 备份（/home/${BACKUP_PREFIX}_YYYYmmddHHMMSS.tar.gz）"
    echo "14. 恢复（从 /home/${BACKUP_PREFIX}_*.tar.gz 获取，回车默认最新）"
    echo "19. 卸载"
    echo "0. 退出"
    echo
    read -r -p "请输入选项并回车：" choice || exit 0
    case "${choice}" in
      1) install_dujiao "${CUSTOM_IMAGE_REPO}" "镜像"; pause ;;
      2) update_dujiao "${CUSTOM_IMAGE_REPO}"; pause ;;
      3|13) backup_dujiao; pause ;;
      4|14) restore_dujiao; pause ;;
      5) docker_login; pause ;;
      7) push_custom_image; pause ;;
      8|19) uninstall_dujiao; pause ;;
      11) install_dujiao "${OFFICIAL_IMAGE_REPO}" "官方"; pause ;;
      12) update_dujiao "${OFFICIAL_IMAGE_REPO}"; pause ;;
      0) exit 0 ;;
      *) error "无效选项"; pause ;;
    esac
  done
}

main_menu "$@"
