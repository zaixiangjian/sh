#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="bepusdt"
CONTAINER_NAME="bepusdt"
OFFICIAL_IMAGE="v03413/bepusdt:latest"
PUSH_IMAGE="zaixiangjian/bepusdt:latest"
APP_DIR="/home/docker/${APP_NAME}"
BACKUP_DIR="/home"
BACKUP_PREFIX="bepusdt"
COMPOSE_FILE="docker-compose.yaml"
DEFAULT_PORT="8001"

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

write_compose() {
  local image="$1"
  local port="$2"
  mkdir -p "${APP_DIR}/data" "${APP_DIR}/logs"
  cat > "${APP_DIR}/${COMPOSE_FILE}" <<EOF
services:
  bepusdt:
    image: ${image}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      LISTEN: ":8080"
      SQLITE: /var/lib/bepusdt/sqlite.db
      LOG: /var/log/bepusdt/
    ports:
      - "0.0.0.0:${port}:8080"
    volumes:
      - ./data:/var/lib/bepusdt
      - ./logs:/var/log/bepusdt
EOF
}

show_status() {
  echo
  msg "${BLUE}BEpusdt 管理脚本${PLAIN}"
  echo "安装目录：${APP_DIR}"
  echo "备份目录：${BACKUP_DIR}/${BACKUP_PREFIX}-*.tar.gz"
  if [ -d "${APP_DIR}" ]; then
    success "状态：目录已存在"
  else
    warn "状态：未安装"
  fi
  if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"; then
    success "容器：${CONTAINER_NAME} 运行中"
  elif command -v docker >/dev/null 2>&1 && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"; then
    warn "容器：${CONTAINER_NAME} 已创建但未运行"
  else
    warn "容器：未创建"
  fi
  echo
}

install_app() {
  local image="${1:-${OFFICIAL_IMAGE}}"
  require_root
  install_docker

  local port
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    warn "检测到 ${APP_DIR} 已存在，安装操作将保留现有 data/logs 并重建/启动服务。"
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

  write_compose "${image}" "${port}"
  set_compose_image "${image}"
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} -f "${COMPOSE_FILE}" pull
  ${dc} -f "${COMPOSE_FILE}" up -d

  success "BEpusdt 安装/启动完成"
  echo
  echo "访问地址：http://服务器IP:${port}"
  echo "安装目录：${APP_DIR}"
  echo "数据目录：${APP_DIR}/data"
  echo "日志目录：${APP_DIR}/logs"
  echo "说明：首次访问会进入初始化页面，请按页面提示设置安全入口和管理员账号。"
}

set_compose_image() {
  local image="$1"
  if [ ! -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    return 0
  fi
  python3 - "${APP_DIR}/${COMPOSE_FILE}" "${image}" <<'PY2'
from pathlib import Path
import sys
path = Path(sys.argv[1])
image = sys.argv[2]
text = path.read_text()
lines = text.splitlines()
changed = False
for i, line in enumerate(lines):
    if line.lstrip().startswith('image:'):
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}image: {image}"
        changed = True
        break
if not changed:
    raise SystemExit('compose 文件中未找到 image 字段')
path.write_text('\n'.join(lines) + '\n')
PY2
}

update_app() {
  local image="${1:-${OFFICIAL_IMAGE}}"
  require_root
  install_docker
  if [ ! -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    error "未找到 ${APP_DIR}/${COMPOSE_FILE}，请先安装"
    return 1
  fi
  set_compose_image "${image}"
  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)"
  ${dc} -f "${COMPOSE_FILE}" pull
  ${dc} -f "${COMPOSE_FILE}" up -d
  success "更新完成"
}

is_stack_running() {
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

stop_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ] && command -v docker >/dev/null 2>&1; then
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd 2>/dev/null || true)"
    if [ -n "${dc}" ]; then
      ${dc} -f "${COMPOSE_FILE}" down || true
      return 0
    fi
  fi
  docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

start_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    install_docker
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd)"
    ${dc} -f "${COMPOSE_FILE}" up -d
  fi
}

backup_app() {
  require_root
  if [ ! -d "${APP_DIR}" ]; then
    error "未找到安装目录：${APP_DIR}"
    return 1
  fi

  mkdir -p "${BACKUP_DIR}"
  local sep="${1:--}"
  local ts archive was_running=0
  ts="$(date +%Y%m%d%H%M%S)"
  archive="${BACKUP_DIR}/${BACKUP_PREFIX}${sep}${ts}.tar.gz"

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证 SQLite 数据备份一致性..."
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
  local sep="${1:--}"
  shopt -s nullglob
  local files=("${BACKUP_DIR}/${BACKUP_PREFIX}${sep}"*.tar.gz)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then
    error "未找到备份文件：${BACKUP_DIR}/${BACKUP_PREFIX}${sep}*.tar.gz" >&2
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
  local sep="${1:--}"
  local archive ts old_dir
  archive="$(select_backup "${sep}")" || return 1

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
  require_root
  warn "此操作将停止并删除 BEpusdt 容器与安装目录：${APP_DIR}"
  warn "不会删除 /home 下已有备份文件。"
  read -r -p "确认卸载？请输入 yes：" confirm
  if [ "${confirm}" != "yes" ]; then
    warn "已取消卸载"
    return 0
  fi
  stop_stack
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
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
  warn "即将推送镜像：${PUSH_IMAGE}"
  warn "需要当前 Docker Hub 账号拥有该仓库推送权限。"
  read -r -p "确认推送？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消推送"; return 0 ;;
  esac

  if ! docker image inspect "${PUSH_IMAGE}" >/dev/null 2>&1; then
    if ! docker image inspect "${OFFICIAL_IMAGE}" >/dev/null 2>&1; then
      warn "本地没有 ${OFFICIAL_IMAGE}，先拉取官方镜像..."
      docker pull "${OFFICIAL_IMAGE}"
    fi
    warn "本地没有 ${PUSH_IMAGE}，将 ${OFFICIAL_IMAGE} 标记为 ${PUSH_IMAGE} 后推送..."
    docker tag "${OFFICIAL_IMAGE}" "${PUSH_IMAGE}"
  fi
  docker push "${PUSH_IMAGE}"
  success "推送完成：${PUSH_IMAGE}"
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    show_status
    echo "1. 安装（zaixiangjian/bepusdt名称跟随官方容器名）"
    echo "2. 更新（zaixiangjian/bepusdt名称跟随官方容器名）"
    echo "3. 备份（/home/${BACKUP_PREFIX}-YYYYmmddHHMMSS.tar.gz）"
    echo "4. 恢复（从 /home/${BACKUP_PREFIX}-*.tar.gz 获取，回车默认最新）"
    echo "5. 登录docker"
    echo "6. 推送到docker（zaixiangjian/bepusdt名称跟随官方容器名）"
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
      1) install_app "${PUSH_IMAGE}"; pause ;;
      2) update_app "${PUSH_IMAGE}"; pause ;;
      3) backup_app "-"; pause ;;
      4) restore_app "-"; pause ;;
      5) docker_login_app; pause ;;
      6) docker_push_app; pause ;;
      7) uninstall_app; pause ;;
      11) install_app "${OFFICIAL_IMAGE}"; pause ;;
      12) update_app "${OFFICIAL_IMAGE}"; pause ;;
      13) backup_app "-"; pause ;;
      14) restore_app "-"; pause ;;
      19) uninstall_app; pause ;;
      0) exit 0 ;;
      *) error "无效选项"; pause ;;
    esac
  done
}

main_menu "$@"
