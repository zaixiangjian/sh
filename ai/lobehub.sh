#!/usr/bin/env bash
set -o pipefail

# LobeHub Docker 管理脚本
# 数据目录: /home/docker/lobehub
# 配置索引: /root/.lobehub/lobehub.json

APP_NAME="lobehub"
APP_DIR="/home/docker/lobehub"
CONFIG_DIR="/root/.lobehub"
CONFIG_FILE="$CONFIG_DIR/lobehub.json"
BACKUP_DIR="/home/lobehub/backups"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/.env"
BUCKET_FILE="$APP_DIR/bucket.config.json"
SEARXNG_FILE="$APP_DIR/searxng-settings.yml"
DEFAULT_PORT="8036"
DEFAULT_RUSTFS_PORT="9000"
DEFAULT_RUSTFS_ADMIN_PORT="9001"
IMAGE_NAME="lobehub/lobehub:latest"

red='\033[31m'
green='\033[32m'
yellow='\033[33m'
blue='\033[36m'
white='\033[0m'

msg() { echo -e "${green}$*${white}"; }
warn() { echo -e "${yellow}$*${white}"; }
err() { echo -e "${red}$*${white}"; }

pause() {
  read -r -n 1 -p "按任意键继续..." _ 2>/dev/null || true
  echo
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    err "请使用 root 运行。"
    exit 1
  fi
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c $((1 * 2 * $1))
  fi
}

random_b64() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$1" | tr -d '\n'
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
  fi
}

generate_jwks_key() {
  python3 - <<'PY' 2>/dev/null
import json, base64, secrets
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

def b64u(n: int) -> str:
    raw = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode()

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
nums = key.private_numbers()
pub = nums.public_numbers
jwk = {
    'kty': 'RSA', 'use': 'sig', 'alg': 'RS256', 'kid': secrets.token_hex(8),
    'n': b64u(pub.n), 'e': b64u(pub.e),
    'd': b64u(nums.d), 'p': b64u(nums.p), 'q': b64u(nums.q),
    'dp': b64u(nums.dmp1), 'dq': b64u(nums.dmq1), 'qi': b64u(nums.iqmp),
}
print(json.dumps({'keys': [jwk]}, separators=(',', ':')))
PY
}

ensure_tools() {
  local missing=""
  command -v docker >/dev/null 2>&1 || missing="$missing docker"
  if ! docker compose version >/dev/null 2>&1; then missing="$missing docker-compose-plugin"; fi
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  command -v tar >/dev/null 2>&1 || missing="$missing tar"
  python3 - <<'PY' >/dev/null 2>&1 || missing="$missing python3-cryptography"
import cryptography
PY

  if [ -n "$missing" ]; then
    warn "缺少依赖:$missing"
    read -r -p "是否自动安装依赖？[Y/n]: " yn
    case "$yn" in n|N) return 1 ;; esac
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y ca-certificates curl gnupg jq tar openssl python3-cryptography
      if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | bash
      fi
      apt-get install -y docker-compose-plugin || true
      systemctl enable --now docker >/dev/null 2>&1 || true
    else
      err "当前系统没有 apt-get，请手动安装 docker、docker compose、jq、tar。"
      return 1
    fi
  fi
}

compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

load_env_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2-
}

set_env_value() {
  local key="$1" value="$2"
  mkdir -p "$APP_DIR"
  touch "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # 使用 perl 避免 sed 分隔符被 URL 干扰
    KEY="$key" VALUE="$value" perl -0pi -e 's/^\Q$ENV{KEY}\E=.*/$ENV{KEY}."=".$ENV{VALUE}/me' "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

write_config_json() {
  mkdir -p "$CONFIG_DIR"
  if command -v jq >/dev/null 2>&1 && [ -f "$ENV_FILE" ]; then
    jq -n \
      --arg app_dir "$APP_DIR" \
      --arg compose_file "$COMPOSE_FILE" \
      --arg env_file "$ENV_FILE" \
      --arg port "$(load_env_value LOBE_PORT)" \
      --arg app_url "$(load_env_value APP_URL)" \
      --arg openai_proxy_url "$(load_env_value OPENAI_PROXY_URL)" \
      --arg openai_api_key "$(load_env_value OPENAI_API_KEY)" \
      --arg registration_disabled "$(load_env_value AUTH_DISABLE_EMAIL_PASSWORD)" \
      --arg allowed_emails "$(load_env_value AUTH_ALLOWED_EMAILS)" \
      '{
        app: "lobehub",
        appDir: $app_dir,
        composeFile: $compose_file,
        envFile: $env_file,
        port: $port,
        appUrl: $app_url,
        models: { providers: { openai: { proxyUrl: $openai_proxy_url, apiKey: $openai_api_key } } },
        auth: { registrationDisabled: ($registration_disabled == "1"), allowedEmails: $allowed_emails },
        updatedAt: (now | todate)
      }' > "$CONFIG_FILE"
  else
    cat > "$CONFIG_FILE" <<EOF
{"app":"lobehub","appDir":"$APP_DIR","composeFile":"$COMPOSE_FILE","envFile":"$ENV_FILE"}
EOF
  fi
}

write_bucket_config() {
  cat > "$BUCKET_FILE" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": ["*"] },
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::lobe/*"]
    }
  ]
}
EOF
}

write_searxng_config() {
  cat > "$SEARXNG_FILE" <<'EOF'
use_default_settings: true
server:
  secret_key: "lobehub-searxng"
  limiter: false
  image_proxy: true
ui:
  static_use_hash: true
search:
  safe_search: 0
  autocomplete: ""
EOF
}

write_compose_file() {
  cat > "$COMPOSE_FILE" <<'EOF'
name: lobehub
services:
  lobe:
    image: lobehub/lobehub:latest
    container_name: lobehub
    ports:
      - "${LOBE_PORT}:3210"
    depends_on:
      postgresql:
        condition: service_healthy
      redis:
        condition: service_healthy
      rustfs:
        condition: service_healthy
      rustfs-init:
        condition: service_completed_successfully
    environment:
      - KEY_VAULTS_SECRET=${KEY_VAULTS_SECRET}
      - AUTH_SECRET=${AUTH_SECRET}
      - DATABASE_URL=postgresql://postgres:${POSTGRES_PASSWORD}@postgresql:5432/${LOBE_DB_NAME}
      - APP_URL=${APP_URL}
      - INTERNAL_APP_URL=http://localhost:3210
      - S3_ENDPOINT=${S3_ENDPOINT}
      - S3_BUCKET=${RUSTFS_LOBE_BUCKET}
      - S3_ENABLE_PATH_STYLE=1
      - S3_ACCESS_KEY=${RUSTFS_ACCESS_KEY}
      - S3_ACCESS_KEY_ID=${RUSTFS_ACCESS_KEY}
      - S3_SECRET_ACCESS_KEY=${RUSTFS_SECRET_KEY}
      - LLM_VISION_IMAGE_USE_BASE64=1
      - S3_SET_ACL=0
      - SEARXNG_URL=http://searxng:8080
      - REDIS_URL=redis://redis:6379
      - REDIS_PREFIX=lobehub
      - REDIS_TLS=0
    env_file:
      - .env
    restart: always
    networks:
      - lobe-network

  postgresql:
    image: paradedb/paradedb:latest-pg17
    container_name: lobe-postgres
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    command: ["postgres", "-c", "shared_preload_libraries=pg_search"]
    environment:
      - POSTGRES_DB=${LOBE_DB_NAME}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: always
    networks:
      - lobe-network

  redis:
    image: redis:7-alpine
    container_name: lobe-redis
    command: redis-server --save 60 1000 --appendonly yes
    volumes:
      - ./redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10
    restart: always
    networks:
      - lobe-network

  rustfs:
    image: rustfs/rustfs:latest
    container_name: lobe-rustfs
    ports:
      - "${RUSTFS_PORT}:9000"
      - "${RUSTFS_ADMIN_PORT}:9001"
    environment:
      - RUSTFS_CONSOLE_ENABLE=true
      - RUSTFS_ACCESS_KEY=${RUSTFS_ACCESS_KEY}
      - RUSTFS_SECRET_KEY=${RUSTFS_SECRET_KEY}
    volumes:
      - ./rustfs-data:/data
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9000/health >/dev/null 2>&1 || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 30
    command: ["--access-key", "${RUSTFS_ACCESS_KEY}", "--secret-key", "${RUSTFS_SECRET_KEY}", "/data"]
    restart: always
    networks:
      - lobe-network

  rustfs-init:
    image: minio/mc:latest
    container_name: lobe-rustfs-init
    depends_on:
      rustfs:
        condition: service_healthy
    volumes:
      - ./bucket.config.json:/bucket.config.json:ro
    entrypoint: /bin/sh
    command: -c 'set -eu; mc alias set rustfs "http://rustfs:9000" "${RUSTFS_ACCESS_KEY}" "${RUSTFS_SECRET_KEY}"; mc mb "rustfs/lobe" --ignore-existing; mc anonymous set-json "/bucket.config.json" "rustfs/lobe" || true;'
    restart: "no"
    networks:
      - lobe-network

  searxng:
    image: searxng/searxng:latest
    container_name: lobe-searxng
    volumes:
      - ./searxng-settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_SETTINGS_FILE=/etc/searxng/settings.yml
    env_file:
      - .env
    restart: always
    networks:
      - lobe-network

networks:
  lobe-network:
    driver: bridge
EOF
}

init_env_interactive() {
  mkdir -p "$APP_DIR" "$CONFIG_DIR" "$BACKUP_DIR"
  if [ -f "$ENV_FILE" ]; then
    warn "检测到已有 .env，将保留原有密钥，仅补齐缺失项。"
  fi
  touch "$ENV_FILE"

  local port app_url s3_endpoint api_url api_key model_list allowed
  port=$(load_env_value LOBE_PORT); port=${port:-$DEFAULT_PORT}
  read -r -p "请输入 LobeHub 本地端口 [${port}]: " input_port
  port=${input_port:-$port}

  app_url=$(load_env_value APP_URL); app_url=${app_url:-http://localhost:${port}}
  read -r -p "请输入访问地址 APP_URL [${app_url}]: " input_app_url
  app_url=${input_app_url:-$app_url}

  s3_endpoint=$(load_env_value S3_ENDPOINT); s3_endpoint=${s3_endpoint:-http://localhost:${DEFAULT_RUSTFS_PORT}}
  read -r -p "请输入 S3_ENDPOINT，公网图片上传需要浏览器可访问 [${s3_endpoint}]: " input_s3
  s3_endpoint=${input_s3:-$s3_endpoint}

  api_url=$(load_env_value OPENAI_PROXY_URL); api_url=${api_url:-https://api.openai.com/v1}
  read -r -p "请输入 OpenAI 兼容 API URL [${api_url}]: " input_api_url
  api_url=${input_api_url:-$api_url}

  api_key=$(load_env_value OPENAI_API_KEY)
  if [ -n "$api_key" ]; then
    read -r -p "已存在 API Key，是否重新输入？[y/N]: " reset_key
    if [[ "$reset_key" =~ ^[Yy]$ ]]; then
      read -r -s -p "请输入 API Key: " api_key; echo
    fi
  else
    read -r -s -p "请输入 API Key（可留空后续再设置）: " api_key; echo
  fi

  model_list=$(load_env_value OPENAI_MODEL_LIST)
  model_list=${model_list:-""}
  read -r -p "请输入模型列表 OPENAI_MODEL_LIST（可留空）[${model_list}]: " input_models
  model_list=${input_models:-$model_list}

  allowed=$(load_env_value AUTH_ALLOWED_EMAILS)
  read -r -p "允许注册/登录邮箱白名单 AUTH_ALLOWED_EMAILS（留空为全部允许）[${allowed}]: " input_allowed
  allowed=${input_allowed:-$allowed}

  set_env_value LOBE_PORT "$port"
  set_env_value APP_URL "$app_url"
  set_env_value INTERNAL_APP_URL "http://localhost:3210"
  set_env_value LOBE_DB_NAME "$(load_env_value LOBE_DB_NAME || true)"
  [ -n "$(load_env_value LOBE_DB_NAME)" ] || set_env_value LOBE_DB_NAME "lobechat"
  [ -n "$(load_env_value POSTGRES_PASSWORD)" ] || set_env_value POSTGRES_PASSWORD "$(random_b64 24)"
  [ -n "$(load_env_value KEY_VAULTS_SECRET)" ] || set_env_value KEY_VAULTS_SECRET "$(random_b64 32)"
  [ -n "$(load_env_value AUTH_SECRET)" ] || set_env_value AUTH_SECRET "$(random_b64 32)"
  if [ -z "$(load_env_value JWKS_KEY)" ]; then
    local jwks
    jwks=$(generate_jwks_key)
    if [ -n "$jwks" ]; then
      set_env_value JWKS_KEY "$jwks"
    else
      warn "JWKS_KEY 自动生成失败，请安装 python3-cryptography 后重新初始化，或手动填写。"
      set_env_value JWKS_KEY ""
    fi
  fi
  set_env_value S3_ENDPOINT "$s3_endpoint"
  set_env_value RUSTFS_PORT "$(load_env_value RUSTFS_PORT || true)"
  [ -n "$(load_env_value RUSTFS_PORT)" ] || set_env_value RUSTFS_PORT "$DEFAULT_RUSTFS_PORT"
  set_env_value RUSTFS_ADMIN_PORT "$(load_env_value RUSTFS_ADMIN_PORT || true)"
  [ -n "$(load_env_value RUSTFS_ADMIN_PORT)" ] || set_env_value RUSTFS_ADMIN_PORT "$DEFAULT_RUSTFS_ADMIN_PORT"
  [ -n "$(load_env_value RUSTFS_ACCESS_KEY)" ] || set_env_value RUSTFS_ACCESS_KEY "admin"
  [ -n "$(load_env_value RUSTFS_SECRET_KEY)" ] || set_env_value RUSTFS_SECRET_KEY "$(random_b64 24)"
  [ -n "$(load_env_value RUSTFS_LOBE_BUCKET)" ] || set_env_value RUSTFS_LOBE_BUCKET "lobe"
  set_env_value OPENAI_PROXY_URL "$api_url"
  set_env_value OPENAI_API_KEY "$api_key"
  [ -n "$model_list" ] && set_env_value OPENAI_MODEL_LIST "$model_list"
  set_env_value ENABLED_OPENAI "1"
  set_env_value AUTH_ALLOWED_EMAILS "$allowed"
  [ -n "$(load_env_value AUTH_DISABLE_EMAIL_PASSWORD)" ] || set_env_value AUTH_DISABLE_EMAIL_PASSWORD "0"
}

install_lobehub() {
  need_root
  ensure_tools || return 1
  mkdir -p "$APP_DIR" "$CONFIG_DIR" "$BACKUP_DIR"
  init_env_interactive
  write_compose_file
  write_bucket_config
  write_searxng_config
  write_config_json
  msg "正在拉取并启动 LobeHub..."
  compose pull
  compose up -d
  msg "安装完成。访问地址: $(load_env_value APP_URL)"
  warn "配置索引: $CONFIG_FILE"
}

start_lobehub() {
  [ -f "$COMPOSE_FILE" ] || { err "未找到 $COMPOSE_FILE，请先安装。"; return 1; }
  compose up -d
}

stop_lobehub() {
  [ -f "$COMPOSE_FILE" ] || return 0
  compose stop
}

restart_lobehub() {
  [ -f "$COMPOSE_FILE" ] || { err "未找到 $COMPOSE_FILE，请先安装。"; return 1; }
  compose restart
}

status_lobehub() {
  echo -e "${blue}LobeHub 状态${white}"
  echo "应用目录: $APP_DIR"
  echo "配置文件: $CONFIG_FILE"
  echo "访问地址: $(load_env_value APP_URL)"
  echo "端口: $(load_env_value LOBE_PORT)"
  echo "注册状态: $([ "$(load_env_value AUTH_DISABLE_EMAIL_PASSWORD)" = "1" ] && echo 禁止注册/邮箱密码登录 || echo 允许邮箱密码注册登录)"
  echo "邮箱白名单: $(load_env_value AUTH_ALLOWED_EMAILS)"
  if [ -f "$COMPOSE_FILE" ]; then
    compose ps
  else
    warn "尚未安装。"
  fi
}

update_lobehub() {
  [ -f "$COMPOSE_FILE" ] || { err "未找到 $COMPOSE_FILE，请先安装。"; return 1; }
  ensure_tools || return 1
  backup_lobehub quiet
  msg "正在更新镜像并重启..."
  compose pull
  compose up -d
  msg "更新完成。"
}

uninstall_lobehub() {
  [ -f "$COMPOSE_FILE" ] || { warn "未检测到安装文件。"; return 0; }
  warn "卸载会停止并删除 LobeHub 容器。"
  read -r -p "是否先创建备份？[Y/n]: " bk
  case "$bk" in n|N) ;; *) backup_lobehub quiet ;; esac
  read -r -p "是否删除数据目录 $APP_DIR ？[y/N]: " deldata
  compose down --remove-orphans
  if [[ "$deldata" =~ ^[Yy]$ ]]; then
    rm -rf "$APP_DIR"
    warn "已删除数据目录。"
  else
    msg "已保留数据目录: $APP_DIR"
  fi
}

backup_lobehub() {
  local mode="$1"
  mkdir -p "$BACKUP_DIR"
  local ts archive
  ts=$(date +%Y%m%d-%H%M%S)
  archive="$BACKUP_DIR/lobehub-backup-${ts}.tar.gz"
  [ "$mode" = "quiet" ] || warn "备份会包含数据库、对象存储、API Key、登录密钥等敏感信息，请妥善保存。"
  if [ -f "$COMPOSE_FILE" ]; then
    msg "正在暂停容器以确保数据库一致性..."
    compose stop >/dev/null 2>&1 || true
  fi
  tar -czf "$archive" \
    --warning=no-file-changed \
    -C / \
    "${APP_DIR#/}" \
    "${CONFIG_DIR#/}" 2>/tmp/lobehub-backup.err
  local rc=$?
  if [ -f "$COMPOSE_FILE" ]; then
    compose up -d >/dev/null 2>&1 || true
  fi
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    msg "备份完成: $archive"
  else
    err "备份失败: $(cat /tmp/lobehub-backup.err 2>/dev/null)"
    return 1
  fi
}

list_backups() {
  mkdir -p "$BACKUP_DIR"
  echo "备份目录: $BACKUP_DIR"
  ls -1t "$BACKUP_DIR"/lobehub-backup-*.tar.gz 2>/dev/null || warn "暂无备份。"
}

restore_lobehub() {
  mkdir -p "$BACKUP_DIR"
  list_backups
  echo
  read -r -p "请输入要恢复的备份文件完整路径: " archive
  [ -f "$archive" ] || { err "备份文件不存在。"; return 1; }
  warn "恢复会停止当前 LobeHub，并把现有目录移动为 .before_restore 备份。"
  read -r -p "确认恢复？[y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || return 0

  [ -f "$COMPOSE_FILE" ] && compose down --remove-orphans >/dev/null 2>&1 || true
  local ts old_app old_cfg
  ts=$(date +%Y%m%d-%H%M%S)
  old_app="${APP_DIR}.before_restore_${ts}"
  old_cfg="${CONFIG_DIR}.before_restore_${ts}"
  [ -d "$APP_DIR" ] && mv "$APP_DIR" "$old_app"
  [ -d "$CONFIG_DIR" ] && mv "$CONFIG_DIR" "$old_cfg"
  if tar -xzf "$archive" -C /; then
    msg "恢复完成，正在启动..."
    compose up -d
    msg "已恢复。旧目录: $old_app $old_cfg"
  else
    err "恢复失败，正在回滚..."
    rm -rf "$APP_DIR" "$CONFIG_DIR"
    [ -d "$old_app" ] && mv "$old_app" "$APP_DIR"
    [ -d "$old_cfg" ] && mv "$old_cfg" "$CONFIG_DIR"
    [ -f "$COMPOSE_FILE" ] && compose up -d >/dev/null 2>&1 || true
    return 1
  fi
}

migration_package() {
  backup_lobehub quiet
  local latest
  latest=$(ls -1t "$BACKUP_DIR"/lobehub-backup-*.tar.gz 2>/dev/null | head -n1)
  echo
  msg "迁移包已生成: $latest"
  echo "新服务器恢复步骤："
  echo "1. scp '$latest' root@新服务器:$BACKUP_DIR/"
  echo "2. scp /root/lobehub.sh root@新服务器:/root/lobehub.sh"
  echo "3. ssh root@新服务器 'chmod +x /root/lobehub.sh && /root/lobehub.sh'"
  echo "4. 在菜单里选择：恢复备份"
}

sync_push() {
  backup_lobehub quiet || return 1
  local latest target
  latest=$(ls -1t "$BACKUP_DIR"/lobehub-backup-*.tar.gz 2>/dev/null | head -n1)
  read -r -p "请输入目标服务器，例如 root@1.2.3.4: " target
  [ -z "$target" ] && return 1
  ssh "$target" "mkdir -p '$BACKUP_DIR'" || return 1
  scp "$latest" "$target:$BACKUP_DIR/" || return 1
  scp /root/lobehub.sh "$target:/root/lobehub.sh" || true
  msg "已推送到 $target:$BACKUP_DIR/"
}

sync_pull() {
  local source
  read -r -p "请输入源服务器，例如 root@1.2.3.4: " source
  [ -z "$source" ] && return 1
  mkdir -p "$BACKUP_DIR"
  ssh "$source" "ls -1t '$BACKUP_DIR'/lobehub-backup-*.tar.gz 2>/dev/null | head -n1" > /tmp/lobehub-latest-remote.txt
  local remote_file
  remote_file=$(cat /tmp/lobehub-latest-remote.txt)
  [ -z "$remote_file" ] && { err "远端没有备份。"; return 1; }
  scp "$source:$remote_file" "$BACKUP_DIR/" || return 1
  msg "已拉取: $BACKUP_DIR/$(basename "$remote_file")"
  read -r -p "是否立即恢复这个备份？[y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    restore_lobehub
  fi
}

sync_menu() {
  while true; do
    clear
    echo -e "${blue}LobeHub 多设备同步/迁移${white}"
    echo "1. 生成迁移包"
    echo "2. 推送最新备份到另一台服务器 scp"
    echo "3. 从另一台服务器拉取最新备份 scp"
    echo "4. 查看本机备份"
    echo "0. 返回"
    read -r -p "请选择: " c || exit 0
    case "$c" in
      1) migration_package; pause ;;
      2) sync_push; pause ;;
      3) sync_pull; pause ;;
      4) list_backups; pause ;;
      0) break ;;
      *) err "无效选择"; pause ;;
    esac
  done
}

enable_registration() {
  [ -f "$ENV_FILE" ] || { err "未找到 .env，请先安装。"; return 1; }
  set_env_value AUTH_DISABLE_EMAIL_PASSWORD "0"
  write_config_json
  msg "已启用邮箱密码注册/登录。正在重启 LobeHub..."
  restart_lobehub
}

disable_registration() {
  [ -f "$ENV_FILE" ] || { err "未找到 .env，请先安装。"; return 1; }
  set_env_value AUTH_DISABLE_EMAIL_PASSWORD "1"
  write_config_json
  warn "已禁止邮箱密码注册/登录；如果没有配置 SSO，普通用户将无法注册登录。"
  restart_lobehub
}

set_allowed_emails() {
  [ -f "$ENV_FILE" ] || { err "未找到 .env，请先安装。"; return 1; }
  local current emails
  current=$(load_env_value AUTH_ALLOWED_EMAILS)
  echo "当前白名单: ${current:-空，全部允许}"
  read -r -p "请输入允许邮箱/域名，英文逗号分隔，留空为全部允许: " emails
  set_env_value AUTH_ALLOWED_EMAILS "$emails"
  write_config_json
  msg "已更新邮箱白名单。正在重启 LobeHub..."
  restart_lobehub
}

api_config_menu() {
  [ -f "$ENV_FILE" ] || { err "未找到 .env，请先安装。"; return 1; }
  local api_url api_key model_list
  api_url=$(load_env_value OPENAI_PROXY_URL)
  read -r -p "OpenAI 兼容 API URL [${api_url}]: " input_url
  api_url=${input_url:-$api_url}
  read -r -p "是否修改 API Key？[y/N]: " yn
  api_key=$(load_env_value OPENAI_API_KEY)
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -r -s -p "请输入 API Key: " api_key; echo
  fi
  model_list=$(load_env_value OPENAI_MODEL_LIST)
  read -r -p "模型列表 OPENAI_MODEL_LIST（可留空）[${model_list}]: " input_models
  model_list=${input_models:-$model_list}
  set_env_value ENABLED_OPENAI "1"
  set_env_value OPENAI_PROXY_URL "$api_url"
  set_env_value OPENAI_API_KEY "$api_key"
  set_env_value OPENAI_MODEL_LIST "$model_list"
  write_config_json
  msg "API 配置已保存。正在重启 LobeHub..."
  restart_lobehub
}

show_paths() {
  echo "脚本: /root/lobehub.sh"
  echo "应用目录: $APP_DIR"
  echo "compose: $COMPOSE_FILE"
  echo "环境变量: $ENV_FILE"
  echo "配置索引: $CONFIG_FILE"
  echo "备份目录: $BACKUP_DIR"
}

main_menu() {
  need_root
  while true; do
    clear
    echo -e "${blue}========== LobeHub Docker 管理 ==========${white}"
    echo "1. 安装/初始化 LobeHub"
    echo "2. 启动"
    echo "3. 停止"
    echo "4. 重启"
    echo "5. 状态"
    echo "6. 更新"
    echo "7. 卸载"
    echo "8. 备份"
    echo "9. 恢复备份"
    echo "10. 多设备同步/迁移"
    echo "11. 启用注册"
    echo "12. 禁止注册"
    echo "13. 设置允许邮箱白名单"
    echo "14. 设置 API URL / API Key / 模型"
    echo "15. 查看路径"
    echo "0. 退出"
    echo "----------------------------------------"
    read -r -p "请输入选择: " choice || exit 0
    case "$choice" in
      1) install_lobehub; pause ;;
      2) start_lobehub; pause ;;
      3) stop_lobehub; pause ;;
      4) restart_lobehub; pause ;;
      5) status_lobehub; pause ;;
      6) update_lobehub; pause ;;
      7) uninstall_lobehub; pause ;;
      8) backup_lobehub; pause ;;
      9) restore_lobehub; pause ;;
      10) sync_menu ;;
      11) enable_registration; pause ;;
      12) disable_registration; pause ;;
      13) set_allowed_emails; pause ;;
      14) api_config_menu; pause ;;
      15) show_paths; pause ;;
      0) exit 0 ;;
      *) err "无效输入"; pause ;;
    esac
  done
}

main_menu
