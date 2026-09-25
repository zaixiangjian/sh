#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="acg-faka"
APP_DIR="/home/docker/${APP_NAME}"
SOURCE_DIR="${APP_DIR}/source"
REPO_URL="https://github.com/zaixiangjian/acg-faka.git"
BACKUP_DIR="/home"
BACKUP_PREFIX="faka"
COMPOSE_FILE="docker-compose.yml"
DEFAULT_PORT="8500"

DATA_DIR="${APP_DIR}/data"
SECRETS_DIR="${APP_DIR}/secrets"
MYSQL_DIR="${APP_DIR}/mysql"
REDIS_DIR="${APP_DIR}/redis"
PHP_VERSION="8.2"
MYSQL_IMAGE="mysql:8.0"
REDIS_IMAGE="redis:7.2-alpine"
PUBLISH_IMAGE="zaixiangjian/acg-faka"
PAY_PLUGINS="BEpusdt Epay Epusdt"
GENERAL_PLUGINS="ContactVerify DestroyOrder EmailNotification Font MakeOrder Mourn OrderEnhancer Refund TranslationBot"
BUILD_PAY_PLUGINS=1
BUILD_GENERAL_PLUGINS=1

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

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    warn "未检测到 git，开始安装..."
    install_pkg git ca-certificates curl
  fi
}

project_name() {
  basename "${APP_DIR}"
}

volume_names() {
  local p
  p="$(project_name)"
  printf '%s\n' "${p}_acg_secrets" "${p}_acg_data" "${p}_acg_mysql" "${p}_acg_redis"
}

write_env() {
  local port="$1"
  mkdir -p "${APP_DIR}"
  cat > "${APP_DIR}/.env" <<EOF
ACG_HTTP_PORT=${port}
EOF
}

write_secrets_init() {
  mkdir -p "${APP_DIR}/docker"
  cat > "${APP_DIR}/docker/secrets-init.sh" <<'EOF'
#!/bin/sh
set -e
mkdir -p /secrets
for name in mysql_root mysql_app; do
    file="/secrets/${name}"
    if [ -s "${file}" ]; then
        echo "已存在，保留：${file}"
        continue
    fi
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > "${file}"
    chmod 600 "${file}"
    echo "已生成：${file}"
done
EOF
  chmod +x "${APP_DIR}/docker/secrets-init.sh"
}

write_compose() {
  local mode="${1:-image}"
  mkdir -p "${APP_DIR}" "${DATA_DIR}" "${SECRETS_DIR}" "${MYSQL_DIR}" "${REDIS_DIR}"
  chmod 700 "${SECRETS_DIR}" || true
  write_secrets_init

  local app_image_block
  if [ "${mode}" = "source" ]; then
    app_image_block="    build:
      context: ./source
      dockerfile: Dockerfile
      args:
        PHP_VERSION: "${PHP_VERSION}"
    image: acg-faka:local"
  else
    app_image_block="    image: ${PUBLISH_IMAGE}:latest"
  fi

  cat > "${APP_DIR}/${COMPOSE_FILE}" <<EOF
services:
  secrets-init:
    image: ${MYSQL_IMAGE}
    container_name: acg-faka-secrets-init
    restart: "no"
    entrypoint: ["/bin/sh", "/secrets-init.sh"]
    volumes:
      - ./docker/secrets-init.sh:/secrets-init.sh:ro
      - ./secrets:/secrets

  app:
${app_image_block}
    container_name: acg-faka-app
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
    ports:
      - "\${ACG_HTTP_PORT:-8080}:80"
    environment:
      TZ: Asia/Shanghai
      ACG_DB_HOST: mysql
      ACG_DB_PORT: "3306"
      ACG_DB_DATABASE: acg_faka
      ACG_DB_USERNAME: acg
      ACG_DB_PASSWORD_FILE: /secrets/mysql_app
      ACG_DB_PREFIX: acg_
      ACG_REDIS_HOST: redis
      ACG_REDIS_PORT: "6379"
    volumes:
      - ./secrets:/secrets:ro
      - ./data:/data

  mysql:
    image: ${MYSQL_IMAGE}
    container_name: acg-faka-mysql
    restart: unless-stopped
    depends_on:
      secrets-init:
        condition: service_completed_successfully
    environment:
      MYSQL_ROOT_PASSWORD_FILE: /secrets/mysql_root
      MYSQL_DATABASE: acg_faka
      MYSQL_USER: acg
      MYSQL_PASSWORD_FILE: /secrets/mysql_app
      TZ: Asia/Shanghai
    command:
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_unicode_ci
      - --innodb-buffer-pool-size=256M
      - --max-connections=200
    volumes:
      - ./secrets:/secrets:ro
      - ./mysql:/var/lib/mysql
    healthcheck:
      test: ['CMD-SHELL', 'mysqladmin ping -h 127.0.0.1 -uroot -p"\$\$(cat /secrets/mysql_root)" --silent']
      interval: 5s
      timeout: 5s
      retries: 40
      start_period: 30s

  redis:
    image: ${REDIS_IMAGE}
    container_name: acg-faka-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ./redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
EOF
}
dir_is_empty() {
  local dir="$1"
  [ ! -d "${dir}" ] || [ -z "$(find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]
}

migrate_legacy_source_layout() {
  if [ -d "${APP_DIR}/.git" ] && [ ! -d "${SOURCE_DIR}/.git" ]; then
    local tmp
    tmp="${APP_DIR}.source_migrate_$(date +%Y%m%d%H%M%S)"
    warn "检测到旧版源码直接位于 ${APP_DIR}，正在整理到 ${SOURCE_DIR} ..."
    mkdir -p "${tmp}"
    find "${APP_DIR}" -mindepth 1 -maxdepth 1 \
      ! -name 'source' \
      ! -name 'data' \
      ! -name 'secrets' \
      ! -name 'mysql' \
      ! -name 'redis' \
      ! -name '.env' \
      ! -name 'docker-compose.override.yml' \
      -exec mv {} "${tmp}/" \;
    mkdir -p "${SOURCE_DIR}"
    find "${tmp}" -mindepth 1 -maxdepth 1 -exec mv {} "${SOURCE_DIR}/" \;
    rmdir "${tmp}" 2>/dev/null || true
  fi
}

ensure_source() {
  mkdir -p "${APP_DIR}"
  migrate_legacy_source_layout

  if [ -d "${SOURCE_DIR}/.git" ]; then
    return 0
  fi

  if [ -e "${SOURCE_DIR}" ] && ! dir_is_empty "${SOURCE_DIR}"; then
    error "${SOURCE_DIR} 已存在但不是 git 仓库，请先备份/移走后重试。"
    return 1
  fi

  rm -rf "${SOURCE_DIR}"
  git clone --depth=1 "${REPO_URL}" "${SOURCE_DIR}"
}

copy_volume_to_dir_if_needed() {
  local volume="$1"
  local dest="$2"
  if docker volume inspect "${volume}" >/dev/null 2>&1 && dir_is_empty "${dest}"; then
    mkdir -p "${dest}"
    warn "检测到旧 Docker 数据卷 ${volume}，正在迁移到 ${dest} ..."
    docker run --rm -v "${volume}:/from:ro" -v "${dest}:/to" alpine:3.20 sh -c 'cd /from && cp -a . /to/'
  fi
}

prepare_bind_mounts() {
  mkdir -p "${DATA_DIR}" "${SECRETS_DIR}" "${MYSQL_DIR}" "${REDIS_DIR}"
  chmod 700 "${SECRETS_DIR}" || true

  local p was_running=0
  p="$(project_name)"

  if docker volume inspect "${p}_acg_data" >/dev/null 2>&1 || \
     docker volume inspect "${p}_acg_secrets" >/dev/null 2>&1 || \
     docker volume inspect "${p}_acg_mysql" >/dev/null 2>&1 || \
     docker volume inspect "${p}_acg_redis" >/dev/null 2>&1; then
    if is_stack_running; then
      was_running=1
      warn "检测到旧数据卷与正在运行的容器，先停止服务再迁移到本地目录..."
      stop_stack
    fi

    copy_volume_to_dir_if_needed "${p}_acg_data" "${DATA_DIR}"
    copy_volume_to_dir_if_needed "${p}_acg_secrets" "${SECRETS_DIR}"
    copy_volume_to_dir_if_needed "${p}_acg_mysql" "${MYSQL_DIR}"
    copy_volume_to_dir_if_needed "${p}_acg_redis" "${REDIS_DIR}"

    if [ "${was_running}" -eq 1 ]; then
      warn "数据迁移完成，稍后将按本地目录映射重新启动。"
    fi
  fi
}

show_status() {
  echo
  msg "${BLUE}ACG-Faka 管理脚本${PLAIN}"
  echo "安装目录：${APP_DIR}"
  echo "源码目录：${SOURCE_DIR}"
  echo "数据目录：${DATA_DIR}"
  echo "配置密钥目录：${SECRETS_DIR}"
  echo "MySQL目录：${MYSQL_DIR}（镜像 ${MYSQL_IMAGE}）"
  echo "Redis目录：${REDIS_DIR}（镜像 ${REDIS_IMAGE}）"
  echo "PHP版本：${PHP_VERSION}（容器内）"
  echo "备份目录：${BACKUP_DIR}/${BACKUP_PREFIX}_*.tar.gz"
  if [ -d "${SOURCE_DIR}/.git" ]; then
    success "状态：源码已存在"
  elif [ -d "${APP_DIR}" ]; then
    warn "状态：目录已存在但源码未安装"
  else
    warn "状态：未安装"
  fi
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'acg-faka-app'; then
    success "容器：acg-faka-app 运行中"
  elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'acg-faka-app'; then
    warn "容器：acg-faka-app 已创建但未运行"
  else
    warn "容器：未创建"
  fi
  echo
}

compose_up_build() {
  local mode="${1:-image}"
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  if [ "${mode}" = "image" ]; then
    ${dc} --env-file .env -f "${COMPOSE_FILE}" pull app || true
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d
  else
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  fi
}




patch_logo_upload_js_file() {
  local file="$1"
  [ -f "${file}" ] || return 0

  if grep -q "const logoUrl = data.url || data.path" "${file}" 2>/dev/null; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "未检测到 python3，跳过 LOGO 上传 JS 修复：${file}"
    return 0
  fi

  cp -a "${file}" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  LOGO_JS_FILE="${file}" python3 - <<'PY'
from pathlib import Path
import os
p = Path(os.environ['LOGO_JS_FILE'])
s = p.read_text()
old = '''        util.bindButtonUpload(".upload-logo", "/admin/api/upload/send?mime=image", data => {
            if (!controllerActive) return;
            $('input[name=logo]').val(data.url);
            markFormDirty();
            layer.msg(i18n('图标上传成功，但需要保存后才会生效'));
            $('.image-input-wrapper').css({
                "background-image": `url(${data.url})`
            });
        });'''
new = '''        util.bindButtonUpload(".upload-logo", "/admin/api/upload/send?mime=image", data => {
            if (!controllerActive) return;
            const logoUrl = data.url || data.path || data.data?.url || data.data?.path || "";
            if (!logoUrl) {
                layer.msg(i18n('LOGO上传成功，但未返回文件地址，请刷新后重试'));
                return;
            }
            $('input[name=logo]').val(logoUrl).trigger('change');
            markFormDirty();
            layer.msg(i18n('图标上传成功，但需要保存后才会生效'));
            $('.admin-mobile-image-input--logo .image-input-wrapper, .image-input-wrapper').css({
                "background-image": `url(${logoUrl}?v=${Date.now()})`
            });
        });'''
if old not in s:
    raise SystemExit('LOGO upload JS target block not found')
p.write_text(s.replace(old, new))
PY
}

patch_logo_upload_js_source() {
  patch_logo_upload_js_file "${SOURCE_DIR}/assets/admin/controller/config/index.js"
}

patch_logo_upload_js_container() {
  if ! docker ps --format '{{.Names}}' | grep -qx 'acg-faka-app'; then
    warn "acg-faka-app 未运行，跳过 LOGO 上传 JS 修复。"
    return 0
  fi
  if docker exec acg-faka-app sh -lc 'grep -q "const logoUrl = data.url || data.path" /var/www/html/assets/admin/controller/config/index.js' >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  docker cp acg-faka-app:/var/www/html/assets/admin/controller/config/index.js "${tmp}/index.js"
  patch_logo_upload_js_file "${tmp}/index.js"
  docker exec acg-faka-app sh -lc 'cp -a /var/www/html/assets/admin/controller/config/index.js /var/www/html/assets/admin/controller/config/index.js.bak.$(date +%Y%m%d%H%M%S)' || true
  docker cp "${tmp}/index.js" acg-faka-app:/var/www/html/assets/admin/controller/config/index.js
  rm -rf "${tmp}"
}

fix_favicon_link() {
  if ! docker ps --format '{{.Names}}' | grep -qx 'acg-faka-app'; then
    warn "acg-faka-app 未运行，跳过 favicon 软链修复。"
    return 0
  fi

  docker exec acg-faka-app sh -lc '
    set -e
    if [ -f /data/assets_cache/favicon.ico ]; then
      rm -f /var/www/html/favicon.ico
      ln -s /data/assets_cache/favicon.ico /var/www/html/favicon.ico
    fi
  ' || warn "favicon 软链修复失败，请手动检查 /data/assets_cache/favicon.ico"
}

supplement_pay_plugins() {
  mkdir -p "${DATA_DIR}/pay"

  if ! docker ps --format '{{.Names}}' | grep -qx 'acg-faka-app'; then
    warn "acg-faka-app 未运行，跳过支付插件补齐。"
    return 0
  fi

  local plugin tmp
  for plugin in BEpusdt Epay Epusdt; do
    if [ ! -d "${DATA_DIR}/pay/${plugin}" ]; then
      if docker exec acg-faka-app sh -lc "test -d /opt/acg-skel/pay/${plugin}" >/dev/null 2>&1; then
        warn "检测到本地缺少支付插件 ${plugin}，正在从镜像补齐..."
        tmp="$(mktemp -d)"
        docker cp "acg-faka-app:/opt/acg-skel/pay/${plugin}" "${tmp}/${plugin}"
        cp -a "${tmp}/${plugin}" "${DATA_DIR}/pay/${plugin}"
        rm -rf "${tmp}"
      else
        warn "镜像内未找到预装支付插件 ${plugin}，跳过。"
      fi
    fi
  done

  if docker exec acg-faka-app sh -lc 'test -f /opt/acg-skel/pay/Epay/Config/Info.php' >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    docker cp "acg-faka-app:/opt/acg-skel/pay/Epay/Config/Info.php" "${tmp}/Info.php"
    if [ -f "${DATA_DIR}/pay/Epay/Config/Info.php" ] && ! cmp -s "${tmp}/Info.php" "${DATA_DIR}/pay/Epay/Config/Info.php"; then
      warn "检测到 Epay/Config/Info.php 与镜像预装版本不同。"
      read -r -p "是否覆盖为镜像内兼容版本？[y/N]: " yn
      case "${yn:-N}" in
        y|Y)
          cp -a "${DATA_DIR}/pay/Epay/Config/Info.php" "${DATA_DIR}/pay/Epay/Config/Info.php.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
          mkdir -p "${DATA_DIR}/pay/Epay/Config"
          cp -a "${tmp}/Info.php" "${DATA_DIR}/pay/Epay/Config/Info.php"
          success "已覆盖 Epay/Config/Info.php，并保留原文件备份。"
          ;;
        *) warn "已保留当前 Epay/Config/Info.php" ;;
      esac
    elif [ ! -f "${DATA_DIR}/pay/Epay/Config/Info.php" ]; then
      mkdir -p "${DATA_DIR}/pay/Epay/Config"
      cp -a "${tmp}/Info.php" "${DATA_DIR}/pay/Epay/Config/Info.php"
      success "已补齐 Epay/Config/Info.php"
    fi
    rm -rf "${tmp}"
  fi

  chown -R 33:33 "${DATA_DIR}/pay" 2>/dev/null || true
}

image_install_acg() {
  require_root
  install_docker

  local port
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    warn "检测到 ${APP_DIR}/${COMPOSE_FILE} 已存在，将保留本地映射数据并使用镜像 ${PUBLISH_IMAGE}:latest 启动。"
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

  write_env "${port}"
  prepare_bind_mounts
  write_compose image
  compose_up_build image
  supplement_pay_plugins
  fix_favicon_link
  patch_logo_upload_js_container

  success "ACG-Faka 镜像安装/启动完成"
  echo
  echo "镜像：${PUBLISH_IMAGE}:latest"
  echo "访问地址：http://服务器IP:${port}"
  echo "安装目录：${APP_DIR}"
  echo "数据目录：${DATA_DIR}"
  echo "支付插件目录：${DATA_DIR}/pay"
  echo "MySQL目录：${MYSQL_DIR}（${MYSQL_IMAGE}）"
  echo "Redis目录：${REDIS_DIR}（${REDIS_IMAGE}）"
}

image_update_acg() {
  require_root
  install_docker
  if [ ! -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    error "未找到 ${APP_DIR}/${COMPOSE_FILE}，请先安装"
    return 1
  fi
  prepare_bind_mounts
  write_compose image
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} --env-file .env -f "${COMPOSE_FILE}" pull app
  ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d
  supplement_pay_plugins
  fix_favicon_link
  patch_logo_upload_js_container
  success "镜像更新完成：${PUBLISH_IMAGE}:latest"
}

docker_login() {
  require_root
  install_docker
  docker login
}

sync_preinstalled_pay_plugins() {
  ensure_source

  if [ "${BUILD_PAY_PLUGINS:-1}" != "1" ]; then
    warn "已选择不构建支付插件。"
    return 0
  fi

  mkdir -p "${SOURCE_DIR}/app/Pay"

  local plugin missing=0
  for plugin in ${PAY_PLUGINS}; do
    if [ -d "${DATA_DIR}/pay/${plugin}" ]; then
      warn "预装支付插件：${plugin}"
      rm -rf "${SOURCE_DIR}/app/Pay/${plugin}"
      cp -a "${DATA_DIR}/pay/${plugin}" "${SOURCE_DIR}/app/Pay/${plugin}"
    else
      error "缺少 ${DATA_DIR}/pay/${plugin}，不能构建预装支付插件镜像。"
      missing=1
    fi
  done

  if [ "${missing}" -eq 1 ]; then
    error "请先在当前 ACG-Faka 中安装所有预构建支付插件后再构建。"
    return 1
  fi

  # 保留支付基础文件的当前运行版本，避免插件依赖的新基类未进入镜像。
  for file in Base.php Pay.php Signature.php; do
    if [ -f "${DATA_DIR}/pay/${file}" ]; then
      cp -a "${DATA_DIR}/pay/${file}" "${SOURCE_DIR}/app/Pay/${file}"
    fi
  done

  chown -R root:root "${SOURCE_DIR}/app/Pay" || true
}

sync_preinstalled_general_plugins() {
  ensure_source

  if [ "${BUILD_GENERAL_PLUGINS:-1}" != "1" ]; then
    warn "已选择不构建通用插件。"
    return 0
  fi

  mkdir -p "${SOURCE_DIR}/app/Plugin"

  local plugin missing=0
  for plugin in ${GENERAL_PLUGINS}; do
    if [ -d "${DATA_DIR}/plugins/${plugin}" ]; then
      warn "预装通用插件：${plugin}"
      rm -rf "${SOURCE_DIR}/app/Plugin/${plugin}"
      cp -a "${DATA_DIR}/plugins/${plugin}" "${SOURCE_DIR}/app/Plugin/${plugin}"
    else
      error "缺少 ${DATA_DIR}/plugins/${plugin}，不能构建预装通用插件镜像。"
      missing=1
    fi
  done

  if [ "${missing}" -eq 1 ]; then
    error "请先在当前 ACG-Faka 中安装所有预构建通用插件后再构建。"
    return 1
  fi

  chown -R root:root "${SOURCE_DIR}/app/Plugin" || true
}

prepare_plugin_dockerignore() {
  local ignore="${SOURCE_DIR}/.dockerignore"
  [ -f "${ignore}" ] || return 0

  cp -a "${ignore}" "${ignore}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i '/# ACG-Faka custom preinstalled plugins/,$d' "${ignore}"

  {
    echo
    echo '# ACG-Faka custom preinstalled plugins'
    echo '# Keep these after upstream app/Pay/* and app/Plugin/* exclusions: dockerignore uses last match wins.'
    local plugin
    for plugin in ${PAY_PLUGINS}; do
      echo "!app/Pay/${plugin}"
      echo "!app/Pay/${plugin}/**"
    done
    for plugin in ${GENERAL_PLUGINS}; do
      echo "!app/Plugin/${plugin}"
      echo "!app/Plugin/${plugin}/**"
    done
  } >> "${ignore}"
}

verify_preinstalled_image() {
  local image="$1"
  local check_pay="${BUILD_PAY_PLUGINS:-1}"
  local check_general="${BUILD_GENERAL_PLUGINS:-1}"
  docker run --rm --entrypoint sh \
    -e CHECK_PAY="${check_pay}" \
    -e CHECK_GENERAL="${check_general}" \
    -e PAY_PLUGINS="${PAY_PLUGINS}" \
    -e GENERAL_PLUGINS="${GENERAL_PLUGINS}" \
    "${image}" -lc '
    set -e
    if [ "${CHECK_PAY}" = "1" ]; then
      for plugin in ${PAY_PLUGINS}; do
        test -d "/opt/acg-skel/pay/${plugin}" || {
          echo "镜像缺少 /opt/acg-skel/pay/${plugin}" >&2
          exit 1
        }
      done
      test -f /opt/acg-skel/pay/Epay/Config/Info.php || {
        echo "镜像缺少 /opt/acg-skel/pay/Epay/Config/Info.php" >&2
        exit 1
      }
      grep -q "usdt.trc20" /opt/acg-skel/pay/Epay/Config/Info.php || {
        echo "镜像内 Epay/Config/Info.php 缺少 usdt.trc20 兼容项" >&2
        exit 1
      }
      echo "镜像预装支付插件验证通过：${PAY_PLUGINS}"
    fi

    if [ "${CHECK_GENERAL}" = "1" ]; then
      for plugin in ${GENERAL_PLUGINS}; do
        test -d "/opt/acg-skel/plugins/${plugin}" || {
          echo "镜像缺少 /opt/acg-skel/plugins/${plugin}" >&2
          exit 1
        }
      done
      echo "镜像预装通用插件验证通过：${GENERAL_PLUGINS}"
    fi
  '
}

build_plugin_image() {
  require_root
  install_docker
  ensure_git

  local yn
  read -r -p "是否构建支付插件（回车默认构建Y/N）：" yn
  case "${yn:-Y}" in
    y|Y) BUILD_PAY_PLUGINS=1 ;;
    *) BUILD_PAY_PLUGINS=0 ;;
  esac
  read -r -p "是否构建通用插件（回车默认构建Y/N）：" yn
  case "${yn:-Y}" in
    y|Y) BUILD_GENERAL_PLUGINS=1 ;;
    *) BUILD_GENERAL_PLUGINS=0 ;;
  esac

  if [ "${BUILD_PAY_PLUGINS}" != "1" ] && [ "${BUILD_GENERAL_PLUGINS}" != "1" ]; then
    error "支付插件和通用插件都未选择，取消构建。"
    return 1
  fi

  sync_preinstalled_pay_plugins
  sync_preinstalled_general_plugins
  prepare_plugin_dockerignore
  patch_logo_upload_js_source
  prepare_bind_mounts
  write_compose source
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} --env-file .env -f "${COMPOSE_FILE}" build app
  docker tag acg-faka:local "${PUBLISH_IMAGE}:latest"
  verify_preinstalled_image "${PUBLISH_IMAGE}:latest"
  success "构建完成并验证通过：${PUBLISH_IMAGE}:latest"
}

docker_push_image() {
  require_root
  install_docker
  if ! docker image inspect "${PUBLISH_IMAGE}:latest" >/dev/null 2>&1; then
    error "本地没有 ${PUBLISH_IMAGE}:latest，请先执行 6 构建插件镜像。"
    return 1
  fi
  verify_preinstalled_image "${PUBLISH_IMAGE}:latest"
  docker push "${PUBLISH_IMAGE}:latest"
  success "已推送镜像：${PUBLISH_IMAGE}:latest"
}

source_install_acg() {
  require_root
  install_docker
  ensure_git

  local port
  if [ -d "${SOURCE_DIR}/.git" ]; then
    warn "检测到 ${SOURCE_DIR} 已存在，将保留现有源码、本地映射数据和配置并启动服务。"
    read -r -p "是否继续？[Y/n]: " yn
    case "${yn:-Y}" in
      y|Y) ;;
      *) return 0 ;;
    esac
  fi

  ensure_source

  read -r -p "请输入公网访问端口 [默认: ${DEFAULT_PORT}]: " port
  port="${port:-${DEFAULT_PORT}}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    error "端口无效：${port}"
    return 1
  fi

  write_env "${port}"
  prepare_bind_mounts
  patch_logo_upload_js_source
  write_compose source
  compose_up_build source
  supplement_pay_plugins
  fix_favicon_link
  patch_logo_upload_js_container

  success "ACG-Faka 安装/启动完成"
  echo
  echo "访问地址：http://服务器IP:${port}"
  echo "安装目录：${APP_DIR}"
  echo "源码目录：${SOURCE_DIR}"
  echo "数据目录：${DATA_DIR}"
  echo "支付插件目录：${DATA_DIR}/pay"
  echo "配置密钥目录：${SECRETS_DIR}"
  echo "MySQL目录：${MYSQL_DIR}（${MYSQL_IMAGE}）"
  echo "Redis目录：${REDIS_DIR}（${REDIS_IMAGE}）"
  echo "PHP版本：${PHP_VERSION}（容器内）"
  echo "备份文件：/home/${BACKUP_PREFIX}_YYYYmmddHHMMSS.tar.gz"
  echo "说明：首次打开网页后按安装向导完成初始化。"
}

source_update_acg() {
  require_root
  install_docker
  ensure_git
  ensure_source
  prepare_bind_mounts
  write_compose source

  cd "${SOURCE_DIR}"
  git pull --ff-only
  patch_logo_upload_js_source

  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} --env-file .env -f "${COMPOSE_FILE}" pull --ignore-buildable || true
  ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  supplement_pay_plugins
  fix_favicon_link
  patch_logo_upload_js_container
  success "源码更新完成"
}

is_stack_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^(acg-faka-app|acg-faka-mysql|acg-faka-redis)$'
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
  docker stop acg-faka-app acg-faka-mysql acg-faka-redis >/dev/null 2>&1 || true
}

start_stack() {
  if [ -d "${SOURCE_DIR}/.git" ]; then
    install_docker
    prepare_bind_mounts
    [ -f "${APP_DIR}/${COMPOSE_FILE}" ] || write_compose image
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd)"
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  fi
}

backup_acg() {
  require_root
  install_docker
  if [ ! -d "${APP_DIR}" ]; then
    error "未找到安装目录：${APP_DIR}"
    return 1
  fi

  local ts archive was_running=0
  ts="$(date +%Y%m%d%H%M%S)"
  archive="${BACKUP_DIR}/${BACKUP_PREFIX}_${ts}.tar.gz"

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证 MySQL/Redis 备份一致性..."
    stop_stack
  fi

  tar -C "$(dirname "${APP_DIR}")" \
    --exclude='source/.git' \
    --exclude='source/vendor' \
    --exclude='source/node_modules' \
    -czf "${archive}" "$(basename "${APP_DIR}")"

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
    error "未找到备份文件：${BACKUP_DIR}/${BACKUP_PREFIX}_*.tar.gz" >&2
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

restore_legacy_volume_backup() {
  local tmp="$1"
  mkdir -p "${DATA_DIR}" "${SECRETS_DIR}" "${MYSQL_DIR}" "${REDIS_DIR}"
  local p v src
  p="$(project_name)"
  for v in acg_data acg_secrets acg_mysql acg_redis; do
    src="${tmp}/volumes/${p}_${v}.tar.gz"
    if [ -f "${src}" ]; then
      case "${v}" in
        acg_data) docker run --rm -v "${DATA_DIR}:/to" -v "${tmp}/volumes:/backup:ro" alpine:3.20 sh -c "cd /to && tar -xzf /backup/${p}_${v}.tar.gz" ;;
        acg_secrets) docker run --rm -v "${SECRETS_DIR}:/to" -v "${tmp}/volumes:/backup:ro" alpine:3.20 sh -c "cd /to && tar -xzf /backup/${p}_${v}.tar.gz" ;;
        acg_mysql) docker run --rm -v "${MYSQL_DIR}:/to" -v "${tmp}/volumes:/backup:ro" alpine:3.20 sh -c "cd /to && tar -xzf /backup/${p}_${v}.tar.gz" ;;
        acg_redis) docker run --rm -v "${REDIS_DIR}:/to" -v "${tmp}/volumes:/backup:ro" alpine:3.20 sh -c "cd /to && tar -xzf /backup/${p}_${v}.tar.gz" ;;
      esac
    fi
  done
}

restore_acg() {
  require_root
  install_docker
  local archive tmp ts old_dir extracted_dir
  archive="$(select_backup)" || return 1

  warn "即将从备份恢复：${archive}"
  warn "当前目录会移动为 ${APP_DIR}.before_restore_时间戳，然后恢复到 source/data/secrets/mysql/redis 结构。"
  read -r -p "确认恢复？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消恢复"; return 0 ;;
  esac

  stop_stack

  tmp="$(mktemp -d /tmp/acg-faka-restore.XXXXXX)"
  tar -C "${tmp}" -xzf "${archive}"

  ts="$(date +%Y%m%d%H%M%S)"
  old_dir="${APP_DIR}.before_restore_${ts}"
  mkdir -p "$(dirname "${APP_DIR}")"
  if [ -e "${APP_DIR}" ]; then
    mv "${APP_DIR}" "${old_dir}"
  fi

  if [ -d "${tmp}/$(basename "${APP_DIR}")" ]; then
    extracted_dir="${tmp}/$(basename "${APP_DIR}")"
    mv "${extracted_dir}" "${APP_DIR}"
    migrate_legacy_source_layout
  elif [ -f "${tmp}/app/appdir.tar.gz" ]; then
    mkdir -p "${APP_DIR}"
    tar -C "${APP_DIR}" -xzf "${tmp}/app/appdir.tar.gz" --strip-components=1
    migrate_legacy_source_layout
    restore_legacy_volume_backup "${tmp}"
  else
    error "备份结构不正确，正在回滚..."
    rm -rf "${APP_DIR}"
    [ -d "${old_dir}" ] && mv "${old_dir}" "${APP_DIR}"
    rm -rf "${tmp}"
    return 1
  fi
  rm -rf "${tmp}"

  start_stack
  success "恢复完成，已启动服务"
  [ -d "${old_dir}" ] && warn "旧目录保留在：${old_dir}"
}

uninstall_acg() {
  require_root
  warn "此操作将停止并删除 ACG-Faka 容器、安装目录和本地映射数据。"
  warn "安装目录：${APP_DIR}"
  warn "不会删除 /home 下已有备份文件。"
  read -r -p "确认卸载？请输入 yes：" confirm
  if [ "${confirm}" != "yes" ]; then
    warn "已取消卸载"
    return 0
  fi
  stop_stack
  docker rm -f acg-faka-app acg-faka-mysql acg-faka-redis acg-faka-secrets-init >/dev/null 2>&1 || true
  local v
  for v in $(volume_names); do
    docker volume rm "${v}" >/dev/null 2>&1 || true
  done
  rm -rf "${APP_DIR}"
  success "卸载完成"
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    show_status
    echo "1. 安装（${PUBLISH_IMAGE}）"
    echo "2. 更新（${PUBLISH_IMAGE}）"
    echo "3. 备份（/home/${BACKUP_PREFIX}_YYYYmmddHHMMSS.tar.gz）"
    echo "4. 恢复（从 /home/${BACKUP_PREFIX}_*.tar.gz 获取，回车默认最新）"
    echo "5. 登录docker"
    echo "6. 构建支付插件与通用插件"
    echo "7. 推送到docker（${PUBLISH_IMAGE}）"
    echo "8. 卸载"
    echo
    echo "11. 源码安装"
    echo "12. 源码更新"
    echo "13. 备份（/home/${BACKUP_PREFIX}_YYYYmmddHHMMSS.tar.gz）"
    echo "14. 恢复（从 /home/${BACKUP_PREFIX}_*.tar.gz 获取，回车默认最新）"
    echo "15. 卸载"
    echo "0. 退出"
    echo
    read -r -p "请输入选项并回车：" choice || exit 0
    case "${choice}" in
      1) image_install_acg; pause ;;
      2) image_update_acg; pause ;;
      3|13) backup_acg; pause ;;
      4|14) restore_acg; pause ;;
      5) docker_login; pause ;;
      6) build_plugin_image; pause ;;
      7) docker_push_image; pause ;;
      8|15) uninstall_acg; pause ;;
      11) source_install_acg; pause ;;
      12) source_update_acg; pause ;;
      0) exit 0 ;;
      *) error "无效选项"; pause ;;
    esac
  done
}

main_menu "$@"
