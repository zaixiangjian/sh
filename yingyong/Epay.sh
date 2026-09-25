#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Epay"
CONTAINER_PREFIX="epay"
APP_DIR="/home/docker/${APP_NAME}"
HTML_DIR="${APP_DIR}/html"
MYSQL_DIR="${APP_DIR}/mysql"
BACKUP_DIR="/home"
BACKUP_PREFIX="Epay"
COMPOSE_FILE="docker-compose.yaml"
REPO_URL="https://github.com/zaixiangjian/Epay.git"
CUSTOM_IMAGE="zaixiangjian/epay:latest"
DEFAULT_PORT="8502"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

msg() { echo -e "$*"; }
success() { msg "${GREEN}$*${PLAIN}"; }
warn() { msg "${YELLOW}$*${PLAIN}"; }
error() { msg "${RED}$*${PLAIN}"; }
pause() { read -r -p "按回车键继续..." _ || true; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "请使用 root 用户运行此脚本"
    exit 1
  fi
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    set +o pipefail
    LC_ALL=C tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 32
    set -o pipefail
    echo
  fi
}

install_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  else
    error "无法自动安装依赖：未识别的包管理器"
    return 1
  fi
}

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    warn "未检测到 git，开始安装..."
    install_pkg git ca-certificates curl
  fi
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
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && compose_cmd >/dev/null; then
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    warn "未检测到 Docker，开始安装 Docker..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      . /etc/os-release
      curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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
  compose_cmd >/dev/null
}

write_dockerfile() {
  cat > "${APP_DIR}/Dockerfile" <<'EOF'
FROM php:8.2-fpm-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libfreetype6-dev libjpeg62-turbo-dev libpng-dev libzip-dev libonig-dev unzip git ca-certificates curl; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli gd zip mbstring bcmath opcache; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
EOF
}

write_nginx_conf() {
  cat > "${APP_DIR}/nginx.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 50m;

    location / {
        if (!-e $request_filename) {
            rewrite ^/([a-zA-Z0-9\-_]+)\.html$ /index.php?mod=$1 last;
        }
        rewrite ^/pay/(.*)$ /pay.php?s=$1 last;
        rewrite ^/api/(.*)$ /api.php?s=$1 last;
        rewrite ^/doc/([a-zA-Z0-9\-_]+)\.html$ /index.php?doc=$1 last;
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ^~ /plugins { deny all; }
    location ^~ /includes { deny all; }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME $fastcgi_script_name;
        fastcgi_pass php:9000;
    }
}
EOF
}

write_env() {
  local port="$1"
  if [ ! -f "${APP_DIR}/.env" ]; then
    cat > "${APP_DIR}/.env" <<EOF
APP_PORT=${port}
MYSQL_DATABASE=epay
MYSQL_USER=epay
MYSQL_PASSWORD=$(random_hex)
MYSQL_ROOT_PASSWORD=$(random_hex)
EOF
    chmod 600 "${APP_DIR}/.env"
  else
    if grep -q '^APP_PORT=' "${APP_DIR}/.env"; then
      sed -i "s/^APP_PORT=.*/APP_PORT=${port}/" "${APP_DIR}/.env"
    else
      echo "APP_PORT=${port}" >> "${APP_DIR}/.env"
    fi
  fi
}

write_compose() {
  local mode="${1:-source}"
  local php_image_block
  if [ "${mode}" = "image" ]; then
    php_image_block="    image: ${CUSTOM_IMAGE}"
  else
    php_image_block="    build:
      context: .
      dockerfile: Dockerfile"
  fi

  cat > "${APP_DIR}/${COMPOSE_FILE}" <<EOF
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: epay-nginx
    restart: unless-stopped
    depends_on:
      - php
    ports:
      - "0.0.0.0:\${APP_PORT}:80"
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

  php:
${php_image_block}
    container_name: epay-php
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./html:/var/www/html

  mysql:
    image: mysql:8.4
    container_name: epay-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      TZ: Asia/Shanghai
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_general_ci
    volumes:
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"\$\${MYSQL_ROOT_PASSWORD}\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 30s
EOF
}

fix_permissions() {
  mkdir -p "${HTML_DIR}" "${MYSQL_DIR}"
  docker run --rm -v "${HTML_DIR}:/data" alpine:3.20 sh -c 'chown -R 33:33 /data && find /data -type d -exec chmod 755 {} \; && find /data -type f -exec chmod 644 {} \;' >/dev/null 2>&1 || true
  [ -f "${HTML_DIR}/config.php" ] && chmod 666 "${HTML_DIR}/config.php" || true
  [ -d "${HTML_DIR}/install" ] && chmod -R 777 "${HTML_DIR}/install" || true
}

show_status() {
  echo
  msg "${BLUE}Epay 彩虹易支付 管理脚本${PLAIN}"
  echo "安装目录：${APP_DIR}"
  echo "备份目录：${BACKUP_DIR}/${BACKUP_PREFIX}-*.tar.gz"
  if [ -d "${APP_DIR}" ]; then
    success "状态：目录已存在"
  else
    warn "状态：未安装"
  fi
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'epay-nginx'; then
    success "容器：epay-nginx 运行中"
  elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'epay-nginx'; then
    warn "容器：epay-nginx 已创建但未运行"
  else
    warn "容器：未创建"
  fi
  echo
}

install_app() {
  local mode="${1:-source}"
  require_root
  install_docker
  ensure_git

  local port
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    warn "检测到 ${APP_DIR} 已存在，安装操作将保留现有源码、数据库和配置并重建/启动服务。"
    read -r -p "是否继续？[Y/n]: " yn
    case "${yn:-Y}" in
      y|Y) ;;
      *) return 0 ;;
    esac
  fi

  read -r -p "请输入公网访问端口 [默认: ${DEFAULT_PORT}]: " port
  port="${port:-${DEFAULT_PORT}}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    error "端口无效：${port}"
    return 1
  fi

  mkdir -p "${APP_DIR}"
  if [ ! -d "${HTML_DIR}/.git" ]; then
    if [ -e "${HTML_DIR}" ] && [ -n "$(ls -A "${HTML_DIR}" 2>/dev/null || true)" ]; then
      error "${HTML_DIR} 已存在但不是 git 仓库，请先备份/移走后重试。"
      return 1
    fi
    rm -rf "${HTML_DIR}"
    git clone --depth=1 "${REPO_URL}" "${HTML_DIR}"
  fi

  write_env "${port}"
  write_dockerfile
  write_nginx_conf
  write_compose "${mode}"
  fix_permissions

  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  if [ "${mode}" = "image" ]; then
    ${dc} --env-file .env -f "${COMPOSE_FILE}" pull php || true
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d
  else
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  fi

  success "Epay 安装/启动完成"
  echo
  echo "访问地址：http://服务器IP:${port}"
  echo "安装向导：http://服务器IP:${port}/install/"
  echo "数据库地址：mysql"
  echo "数据库端口：3306"
  echo "数据库名：$(grep '^MYSQL_DATABASE=' .env | cut -d= -f2-)"
  echo "数据库用户：$(grep '^MYSQL_USER=' .env | cut -d= -f2-)"
  echo "数据库密码：保存在 ${APP_DIR}/.env 的 MYSQL_PASSWORD"
  echo "数据表前缀：pay"
}

update_app() {
  local mode="${1:-source}"
  require_root
  install_docker
  ensure_git
  if [ ! -d "${HTML_DIR}/.git" ]; then
    error "未找到 ${HTML_DIR}，请先安装"
    return 1
  fi

  cd "${HTML_DIR}"
  local tmp_config tmp_lock
  tmp_config="$(mktemp)"
  tmp_lock="$(mktemp)"
  [ -f config.php ] && cp -a config.php "${tmp_config}" || true
  [ -f install/install.lock ] && cp -a install/install.lock "${tmp_lock}" || true
  git fetch --depth=1 origin main
  git reset --hard origin/main
  [ -s "${tmp_config}" ] && cp -a "${tmp_config}" config.php || true
  [ -s "${tmp_lock}" ] && mkdir -p install && cp -a "${tmp_lock}" install/install.lock || true
  rm -f "${tmp_config}" "${tmp_lock}"

  cd "${APP_DIR}"
  write_dockerfile
  write_nginx_conf
  write_compose "${mode}"
  fix_permissions
  local dc
  dc="$(compose_cmd)"
  if [ "${mode}" = "image" ]; then
    ${dc} --env-file .env -f "${COMPOSE_FILE}" pull php || true
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d
  else
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  fi
  success "更新完成"
}

is_stack_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^(epay-nginx|epay-php|epay-mysql)$'
}

stop_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ] && command -v docker >/dev/null 2>&1; then
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd 2>/dev/null || true)"
    if [ -n "${dc}" ]; then
      ${dc} --env-file .env -f "${COMPOSE_FILE}" down || true
      return 0
    fi
  fi
  docker stop epay-nginx epay-php epay-mysql >/dev/null 2>&1 || true
}

start_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    install_docker
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd)"
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  fi
}

backup_app() {
  require_root
  if [ ! -d "${APP_DIR}" ]; then
    error "未找到安装目录：${APP_DIR}"
    return 1
  fi

  mkdir -p "${BACKUP_DIR}"
  local ts archive was_running=0
  ts="$(date +%Y%m%d%H%M%S)"
  archive="${BACKUP_DIR}/${BACKUP_PREFIX}-${ts}.tar.gz"

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证 MySQL 数据备份一致性..."
    stop_stack
  fi

  tar -C "$(dirname "${APP_DIR}")" -czf "${archive}" "$(basename "${APP_DIR}")"

  if [ "${was_running}" -eq 1 ]; then
    warn "备份完成，正在恢复启动服务..."
    start_stack
  fi

  success "备份完成：${archive}"
}

select_backup() {
  shopt -s nullglob
  local files=("${BACKUP_DIR}/${BACKUP_PREFIX}-"*.tar.gz)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    error "未找到备份文件：${BACKUP_DIR}/${BACKUP_PREFIX}-*.tar.gz" >&2
    return 1
  fi

  mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -r)
  echo "检测到以下备份：" >&2
  local i
  for i in "${!files[@]}"; do
    [ "$i" -ge 10 ] && break
    printf '%s. %s\n' "$((i+1))" "${files[$i]}" >&2
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
  error "无效的备份选择：${choice}" >&2
  return 1
}

restore_app() {
  require_root
  install_docker
  local archive ts old_dir
  archive="$(select_backup)" || return 1

  warn "即将从备份恢复：${archive}"
  warn "当前目录会移动为 ${APP_DIR}.before_restore_时间戳"
  read -r -p "确认恢复？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消恢复"; return 0 ;;
  esac

  stop_stack

  mkdir -p "$(dirname "${APP_DIR}")"
  ts="$(date +%Y%m%d%H%M%S)"
  old_dir="${APP_DIR}.before_restore_${ts}"
  if [ -e "${APP_DIR}" ]; then
    mv "${APP_DIR}" "${old_dir}"
  fi

  if tar -C "$(dirname "${APP_DIR}")" -xzf "${archive}"; then
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

uninstall_app() {
  local mode="${1:-source}"
  require_root
  warn "此操作将停止并删除 Epay 容器与安装目录：${APP_DIR}"
  warn "不会删除 /home 下已有备份文件。"
  read -r -p "确认卸载？请输入 yes：" confirm
  if [ "${confirm}" != "yes" ]; then
    warn "已取消卸载"
    return 0
  fi
  stop_stack
  docker rm -f epay-nginx epay-php epay-mysql >/dev/null 2>&1 || true
  rm -rf "${APP_DIR}"
  success "卸载完成"
}

docker_login_app() {
  require_root
  install_docker
  warn "即将执行 docker login，请按提示输入 Docker Hub 用户名和密码/Token。"
  docker login
}

docker_push_app() {
  require_root
  install_docker
  if [ ! -f "${APP_DIR}/Dockerfile" ]; then
    error "未找到 ${APP_DIR}/Dockerfile，请先执行 1 或 11 安装生成构建文件。"
    return 1
  fi
  warn "即将构建并推送镜像：${CUSTOM_IMAGE}"
  warn "需要当前 Docker Hub 账号拥有该仓库推送权限。"
  read -r -p "确认推送？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消推送"; return 0 ;;
  esac
  cd "${APP_DIR}"
  docker build -t "${CUSTOM_IMAGE}" -f Dockerfile .
  docker push "${CUSTOM_IMAGE}"
  success "推送完成：${CUSTOM_IMAGE}"
}

restore_custom_app() {
  restore_app
  if [ -d "${APP_DIR}" ]; then
    warn "恢复完成，切换为 ${CUSTOM_IMAGE} 并按 2 更新/启动流程启动..."
    update_app image
  fi
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    show_status
    echo "1. 安装（zaixiangjian/epay这里就使用官方容器名一致）"
    echo "2. 更新（zaixiangjian/epay这里就使用官方容器名一致）"
    echo "3. 备份（/home/${BACKUP_PREFIX}-YYYYmmddHHMMSS.tar.gz）"
    echo "4. 恢复（从 /home/${BACKUP_PREFIX}-*.tar.gz 获取，回车默认最新）"
    echo "5. 登录docker"
    echo "6. 推送到docker（zaixiangjian/epay）"
    echo "7. 卸载"
    echo "------------------------------------------------"
    echo
    echo "11. 安装"
    echo "12. 更新"
    echo "13. 备份（/home/${BACKUP_PREFIX}-YYYYmmddHHMMSS.tar.gz）"
    echo "14. 恢复（从 /home/${BACKUP_PREFIX}-*.tar.gz 获取，回车默认最新）"
    echo "19. 卸载"
    echo "0. 退出"
    echo
    read -r -p "请输入选项并回车：" choice || exit 0
    case "${choice}" in
      1) install_app image; pause ;;
      2) update_app image; pause ;;
      3) backup_app; pause ;;
      4) restore_custom_app; pause ;;
      5) docker_login_app; pause ;;
      6) docker_push_app; pause ;;
      7) uninstall_app; pause ;;
      11) install_app; pause ;;
      12) update_app; pause ;;
      13) backup_app; pause ;;
      14) restore_app; pause ;;
      19) uninstall_app; pause ;;
      0) exit 0 ;;
      *) error "无效选项"; pause ;;
    esac
  done
}

main_menu "$@"
