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
REPO_URL="https://github.com/zaixiangjian/wodezhifu.git"
CUSTOM_IMAGE="zaixiangjian/epay:latest"
DEFAULT_PORT="8502"
EPAY_NETWORK_SUBNET="172.29.88.0/24"

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

ensure_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    warn "未检测到 python3，开始安装..."
    install_pkg python3
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

ensure_iptables() {
  if command -v iptables >/dev/null 2>&1; then
    return 0
  fi
  warn "未检测到 iptables，开始安装..."
  install_pkg iptables
}

apply_epay_egress_firewall() {
  ensure_iptables || return 1
  iptables -N EPAY-EGRESS 2>/dev/null || true
  iptables -F EPAY-EGRESS
  iptables -A EPAY-EGRESS -d "${EPAY_NETWORK_SUBNET}" -j RETURN
  for cidr in     0.0.0.0/8     10.0.0.0/8     100.64.0.0/10     127.0.0.0/8     169.254.0.0/16     172.16.0.0/12     192.168.0.0/16     198.18.0.0/15     224.0.0.0/4     240.0.0.0/4; do
    iptables -A EPAY-EGRESS -d "$cidr" -j REJECT
  done
  iptables -A EPAY-EGRESS -j RETURN
  iptables -C DOCKER-USER -s "${EPAY_NETWORK_SUBNET}" -j EPAY-EGRESS 2>/dev/null ||     iptables -I DOCKER-USER 1 -s "${EPAY_NETWORK_SUBNET}" -j EPAY-EGRESS
  success "已应用 Epay 容器出站防火墙：禁止访问宿主机/内网/云元数据，放行公网与本应用网络"
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
FROM php:8.3-fpm-alpine

RUN set -eux; \
    apk add --no-cache \
      freetype-dev libjpeg-turbo-dev libpng-dev libzip-dev oniguruma-dev \
      unzip git ca-certificates curl; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql mysqli gd zip mbstring bcmath opcache

WORKDIR /var/www/html
COPY --chown=82:82 html/ /var/www/html/
EOF
}

write_dockerignore() {
  cat > "${APP_DIR}/.dockerignore" <<'EOF'
html/config.php
html/install/install.lock
html/epay_release*
html/epay_update*
mysql/
.env
.git/
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

    # 安装完成后自动禁止访问安装器；新环境没有 install.lock 时仍允许打开安装向导。
    # 显式把 /install/index.php 交给 PHP-FPM，避免任何环境把安装器 PHP 当静态文件下载。
    location = /install/index.php {
        if (-f $document_root/install/install.lock) { return 404; }
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME $fastcgi_script_name;
        fastcgi_pass php:9000;
    }
    location = /install/ {
        if (-f $document_root/install/install.lock) { return 404; }
        rewrite ^ /install/index.php last;
    }
    # 升级脚本不得公开访问；安装完成后也禁止整个 install 目录继续暴露。
    location = /install/update.php {
        return 404;
    }
    location /install/ {
        if (-f $document_root/install/install.lock) { return 404; }
        try_files $uri /install/index.php?$query_string;
    }

    location = /config.php { deny all; }
    location ^~ /plugins { deny all; }
    location ^~ /includes { deny all; }

    # 禁止访问 config.php / .git / .env / composer.* / 备份包 / 隐藏文件，防止源码与敏感文件泄露。
    location ~ /\.(?!well-known).* {
        deny all;
    }
    location ~* (^|/)(composer\.(json|lock)|package(-lock)?\.json|yarn\.lock|\.env|\.git|\.svn|\.hg)(/|$) {
        deny all;
    }
    # 拦截所有备份残留：既包括 .bak 结尾，也包括 .php.bak.audit-时间戳 这类文件。
    location ~* (^|/).*\.(bak|old|orig|save|swp)(\.|$) {
        deny all;
    }
    location ~* \.(sql|tar|gz|tgz|zip|7z|rar)$ {
        deny all;
    }

    # 禁止上传/静态目录中的 PHP 被执行，防止图片上传点变成 WebShell。
    location ~* ^/(assets|upload|uploads|static)/.*\.(php|php[0-9]*|phtml|phar)$ {
        deny all;
    }

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


repair_epay_source_layout() {
  if [ ! -d "${HTML_DIR}" ]; then
    return 0
  fi

  # 常见错误：把 GitHub/ZIP 包多套了一层目录，导致 /var/www/html 下只有 index.php 或结构不完整。
  # 如果检测到唯一子目录才是真正源码根目录，则自动上移，避免 include ./includes/common.php 失败。
  if [ ! -f "${HTML_DIR}/includes/common.php" ]; then
    local dirs_count nested_dir
    dirs_count="$(find "${HTML_DIR}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
    nested_dir="$(find "${HTML_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)"
    if [ "${dirs_count}" = "1" ] && [ -n "${nested_dir}" ] && [ -f "${nested_dir}/index.php" ] && [ -f "${nested_dir}/includes/common.php" ]; then
      warn "检测到源码多套了一层目录，正在自动上移到 ${HTML_DIR} ..."
      (shopt -s dotglob nullglob; mv "${nested_dir}"/* "${HTML_DIR}/")
      rmdir "${nested_dir}" 2>/dev/null || true
    fi
  fi
}

validate_epay_source() {
  local missing=0
  for path in \
    "index.php" \
    "includes/common.php" \
    "includes/lib/Template.php" \
    "includes/vendor/composer/autoload_real.php" \
    "install/index.php"; do
    if [ ! -f "${HTML_DIR}/${path}" ]; then
      error "源码缺少必要文件：${HTML_DIR}/${path}"
      missing=1
    fi
  done

  if [ "${missing}" -ne 0 ]; then
    error "Epay 源码不完整，已停止启动。"
    warn "请检查 ${HTML_DIR} 是否完整，或确认 GitHub 仓库根目录是否直接包含 index.php、includes/、plugins/、install/。"
    return 1
  fi
}

clean_epay_residue_files() {
  if [ ! -d "${HTML_DIR}" ]; then
    return 0
  fi
  local count
  count="$(find "${HTML_DIR}" -type f \( -name '*.bak*' -o -name '*.old*' -o -name '*.orig*' -o -name '*.save*' -o -name '*.swp' \) | wc -l | tr -d ' ')"
  if [ "${count}" != "0" ]; then
    warn "检测到 Web 根目录残留备份文件 ${count} 个，正在移出避免公网泄露..."
    local residue_dir="${APP_DIR}/security-backups/webroot-residue-$(date +%Y%m%d%H%M%S)"
    mkdir -p "${residue_dir}"
    while IFS= read -r file; do
      local rel dest
      rel="${file#${HTML_DIR}/}"
      dest="${residue_dir}/${rel}"
      mkdir -p "$(dirname "${dest}")"
      mv "${file}" "${dest}"
    done < <(find "${HTML_DIR}" -type f \( -name '*.bak*' -o -name '*.old*' -o -name '*.orig*' -o -name '*.save*' -o -name '*.swp' \))
    success "残留备份文件已移到：${residue_dir}"
  fi
}

verify_epay_security_fixes() {
  local fail=0
  if [ -f "${HTML_DIR}/admin/gonggao.php" ]; then
    if grep -q "INSERT INTO.*pre_anounce.*{\$content}" "${HTML_DIR}/admin/gonggao.php" || grep -q "UPDATE.*pre_anounce.*content.*\$content" "${HTML_DIR}/admin/gonggao.php"; then
      error "admin/gonggao.php 仍疑似存在公告 SQL 拼接，请先更新到已加固版本。"
      fail=1
    fi
    if ! grep -q "csrf_check_page('admin')" "${HTML_DIR}/admin/gonggao.php"; then
      error "admin/gonggao.php 未检测到 CSRF 校验，请先更新到已加固版本。"
      fail=1
    fi
  fi
  if [ -f "${HTML_DIR}/install/update.php" ] && ! grep -q "install.lock" "${HTML_DIR}/install/update.php"; then
    error "install/update.php 未检测到 install.lock 保护，请先更新到已加固版本。"
    fail=1
  fi
  if [ -f "${HTML_DIR}/includes/lib/Plugin.php" ] && ! grep -q "safePluginFile" "${HTML_DIR}/includes/lib/Plugin.php"; then
    error "includes/lib/Plugin.php 未检测到插件 realpath containment 加固。"
    fail=1
  fi
  if [ -f "${HTML_DIR}/user/transfer_add.php" ] && ! grep -q "'uid'=>\$uid" "${HTML_DIR}/user/transfer_add.php"; then
    error "user/transfer_add.php 未检测到 copy 记录 uid 归属校验。"
    fail=1
  fi
  [ "${fail}" -eq 0 ] || return 1
}

sanitize_epay_source() {
  if [ ! -d "${HTML_DIR}" ]; then
    return 0
  fi

  local changed=0
  local platform_file="${HTML_DIR}/includes/vendor/composer/platform_check.php"
  local autoload_file="${HTML_DIR}/includes/vendor/composer/autoload_real.php"

  if [ -f "${platform_file}" ] && grep -Eq "SENTENCEIA|HTTP_PHP_VERSION|SERVER_PHP_VERSION" "${platform_file}"; then
    warn "检测到 Composer platform_check.php 中存在已知 syskey 泄露后门，正在清理..."
    python3 - "${platform_file}" <<'PYFIX'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("define('SERVER_PHP_VERSION', $GLOBALS['_SERVER']['HTTP_PHP_VERSION']);\n", '')
text = text.replace('define(\'SENTENCEIA\', "Sorry for the con figuration sys tem key issue.");\n', '')
text = text.replace("\n\n$issues = array();", "\n$issues = array();")
path.write_text(text)
PYFIX
    changed=1
  fi

  if [ -f "${autoload_file}" ] && grep -Eq "Set-Cookie: PHPSESSID|SENTENCEIA|SERVER_PHP_VERSION" "${autoload_file}"; then
    warn "检测到 Composer autoload_real.php 中存在已知 syskey 泄露后门，正在清理..."
    python3 - "${autoload_file}" <<'PYFIX'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
bad = "\t\tif (SERVER_PHP_VERSION >= 70200) {\n\t\t\t$wordsArray = explode(\" \", SENTENCEIA);\n\t\t\theader(\"Set-Cookie: PHPSESSID=\" . $GLOBALS[$wordsArray[3] . substr($wordsArray[4], 0, 1)][$wordsArray[5] . $wordsArray[7]]);\n\t\t}\n"
text = text.replace(bad, '')
path.write_text(text)
PYFIX
    changed=1
  fi

  local sanitize_check_file
  sanitize_check_file="$(mktemp)"
  if grep -RInE "SENTENCEIA|SERVER_PHP_VERSION|HTTP_PHP_VERSION|Set-Cookie: PHPSESSID|sg_load|xitong\.uno|zhangzitong|jiami\.ka234|jiami\.xitong" "${HTML_DIR}" --exclude-dir=.git >"${sanitize_check_file}" 2>/dev/null; then
    error "仍发现可疑后门特征，请人工检查："
    sed -n '1,80p' "${sanitize_check_file}"
    rm -f "${sanitize_check_file}"
    return 1
  fi
  rm -f "${sanitize_check_file}"

  harden_epay_ssrf

  if [ "${changed}" -eq 1 ]; then
    success "已清理已知后门特征"
  fi
}

harden_epay_ssrf() {
  local functions_file="${HTML_DIR}/includes/functions.php"
  if [ ! -f "${functions_file}" ]; then
    error "未找到 ${functions_file}，无法应用 SSRF 防护"
    return 1
  fi

  python3 - "${functions_file}" <<'PYFIX'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
helper = "function epay_is_public_ip($ip){\n\treturn filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE) !== false;\n}\n\nfunction epay_is_safe_outbound_url($url, &$reason=null){\n\t$parts = parse_url($url);\n\tif($parts === false || empty($parts['scheme']) || empty($parts['host'])){ $reason = 'URL格式不正确'; return false; }\n\t$scheme = strtolower($parts['scheme']);\n\tif($scheme !== 'http' && $scheme !== 'https'){ $reason = '仅允许 http/https'; return false; }\n\tif(isset($parts['user']) || isset($parts['pass'])){ $reason = 'URL不允许包含用户名或密码'; return false; }\n\t$port = isset($parts['port']) ? intval($parts['port']) : ($scheme === 'https' ? 443 : 80);\n\tif($port !== 80 && $port !== 443){ $reason = '仅允许 80/443 端口'; return false; }\n\t$host = trim($parts['host'], '[]');\n\tif(preg_match('/(^|\\.)localhost$/i', $host)){ $reason = '禁止访问 localhost'; return false; }\n\t$ips = [];\n\tif(filter_var($host, FILTER_VALIDATE_IP)){ $ips[] = $host; }\n\telse { $records = gethostbynamel($host); if($records === false || count($records) === 0){ $reason = '域名解析失败'; return false; } $ips = $records; }\n\tforeach($ips as $ip){ if(!epay_is_public_ip($ip)){ $reason = '禁止访问内网/保留地址：'.$ip; return false; } }\n\treturn true;\n}\n\nfunction epay_assert_safe_outbound_url($url){\n\t$reason = null;\n\tif(!epay_is_safe_outbound_url($url, $reason)){ error_log('Epay blocked unsafe outbound URL: '.$url.' reason: '.$reason); return false; }\n\treturn true;\n}\n\n"
if 'function epay_is_safe_outbound_url(' not in text:
    if '<?php\r\n' in text:
        text = text.replace('<?php\r\n', '<?php\r\n' + helper.replace('\n', '\r\n'), 1)
    else:
        text = text.replace('<?php\n', '<?php\n' + helper, 1)
repls = {
    "function curl_get($url)\r\n{\r\n\tglobal $conf;\r\n": "function curl_get($url)\r\n{\r\n\tglobal $conf;\r\n\tif(!epay_assert_safe_outbound_url($url)) return false;\r\n",
    "function get_curl($url, $post=0, $referer=0, $cookie=0, $header=0, $ua=0, $nobaody=0, $addheader=0, $location=0)\r\n{\r\n": "function get_curl($url, $post=0, $referer=0, $cookie=0, $header=0, $ua=0, $nobaody=0, $addheader=0, $location=0)\r\n{\r\n\tif(!epay_assert_safe_outbound_url($url)) return false;\r\n",
    "function check_proxy($url)\r\n{\r\n\tglobal $conf;\r\n": "function check_proxy($url)\r\n{\r\n\tglobal $conf;\r\n\tif(!epay_assert_safe_outbound_url($url)) return false;\r\n",
}
for a,b in repls.items():
    if b not in text and a in text:
        text = text.replace(a,b,1)
text = text.replace('curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);', 'curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, true);')
text = text.replace('curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, false);', 'curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, 2);')
text = text.replace('curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);', 'curl_setopt($ch, CURLOPT_FOLLOWLOCATION, false);')
path.write_text(text)
PYFIX
  success "已应用 Epay SSRF 防护：禁止内网/localhost/保留地址、禁止非 80/443、禁止跳转、启用 HTTPS 校验"
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
    networks:
      epay_net:

  php:
${php_image_block}
    container_name: epay-php
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./html:/var/www/html
    networks:
      epay_net:

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
    networks:
      epay_net:

networks:
  epay_net:
    driver: bridge
    ipam:
      config:
        - subnet: ${EPAY_NETWORK_SUBNET}
EOF
}

seed_html_from_image() {
  local cid tmp_config tmp_lock
  mkdir -p "${HTML_DIR}"
  tmp_config="$(mktemp)"
  tmp_lock="$(mktemp)"
  [ -f "${HTML_DIR}/config.php" ] && cp -a "${HTML_DIR}/config.php" "${tmp_config}" || true
  [ -f "${HTML_DIR}/install/install.lock" ] && cp -a "${HTML_DIR}/install/install.lock" "${tmp_lock}" || true

  warn "正在从镜像 ${CUSTOM_IMAGE} 提取源码到 ${HTML_DIR} ..."
  rm -rf "${HTML_DIR}"
  mkdir -p "${HTML_DIR}"
  docker pull "${CUSTOM_IMAGE}"
  cid="$(docker create "${CUSTOM_IMAGE}" sh -c true)"
  docker cp "${cid}:/var/www/html/." "${HTML_DIR}/"
  docker rm "${cid}" >/dev/null

  [ -s "${tmp_config}" ] && cp -a "${tmp_config}" "${HTML_DIR}/config.php" || true
  [ -s "${tmp_lock}" ] && mkdir -p "${HTML_DIR}/install" && cp -a "${tmp_lock}" "${HTML_DIR}/install/install.lock" || true
  rm -f "${tmp_config}" "${tmp_lock}"
}

env_value() {
  local key="$1"
  [ -f "${APP_DIR}/.env" ] && grep -E "^${key}=" "${APP_DIR}/.env" | head -n1 | cut -d= -f2- || true
}

ensure_placeholder_config() {
  # Epay 的 includes/common.php 直接 require ROOT.'config.php'；新安装源码包如果没有
  # config.php，会在进入 /install/ 前先 Fatal。这里按 .env 自动写入运行期数据库配置。
  # 仅在文件缺失或仍是空模板时重写，不覆盖已安装后的有效配置。
  local db_name db_user db_pwd rewrite=0
  db_name="$(env_value MYSQL_DATABASE)"
  db_user="$(env_value MYSQL_USER)"
  db_pwd="$(env_value MYSQL_PASSWORD)"
  db_name="${db_name:-epay}"
  db_user="${db_user:-epay}"

  if [ ! -f "${HTML_DIR}/config.php" ]; then
    rewrite=1
  elif ! grep -Eq "'user'[[:space:]]*=>[[:space:]]*'[^']+'" "${HTML_DIR}/config.php" || ! grep -Eq "'dbname'[[:space:]]*=>[[:space:]]*'[^']+'" "${HTML_DIR}/config.php"; then
    rewrite=1
  fi

  if [ "${rewrite}" -eq 1 ]; then
    cat > "${HTML_DIR}/config.php" <<EOF
<?php
/*数据库配置*/
\$dbconfig=array(
    'host' => 'mysql', //数据库服务器
    'port' => 3306, //数据库端口
    'user' => '${db_user}', //数据库用户名
    'pwd' => '${db_pwd}', //数据库密码
    'dbname' => '${db_name}', //数据库名
    'dbqz' => 'pay' //数据表前缀
);
EOF
  fi
}

fix_permissions() {
  mkdir -p "${HTML_DIR}" "${MYSQL_DIR}"
  ensure_placeholder_config
  # php:8.3-fpm-alpine 中 www-data 是 uid/gid 82，不是 Debian php:8.2-fpm-bookworm 的 33。
  # 源码与 install 目录必须归 82:82，否则安装器无法写 config.php / install.lock。
  docker run --rm -v "${HTML_DIR}:/data" alpine:3.20 sh -c 'chown -R 82:82 /data && find /data -type d -exec chmod 755 {} \; && find /data -type f -exec chmod 644 {} \;' >/dev/null 2>&1 || true
  [ -f "${HTML_DIR}/config.php" ] && chmod 664 "${HTML_DIR}/config.php" || true
  [ -d "${HTML_DIR}/install" ] && find "${HTML_DIR}/install" -type d -exec chmod 755 {} \; -o -type f -exec chmod 644 {} \; || true
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
  ensure_python3

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
  if [ "${mode}" = "image" ]; then
    # 镜像模式使用镜像内源码作为宿主机 ./html 的种子；否则 ./html 绑定会覆盖镜像内 /var/www/html。
    seed_html_from_image
    repair_epay_source_layout
    validate_epay_source
    sanitize_epay_source
    clean_epay_residue_files
    verify_epay_security_fixes
  else
    if [ ! -d "${HTML_DIR}/.git" ]; then
      if [ -e "${HTML_DIR}" ] && [ -n "$(ls -A "${HTML_DIR}" 2>/dev/null || true)" ]; then
        error "${HTML_DIR} 已存在但不是 git 仓库，请先备份/移走后重试。"
        return 1
      fi
      rm -rf "${HTML_DIR}"
      git clone --depth=1 "${REPO_URL}" "${HTML_DIR}"
    fi
    repair_epay_source_layout
    validate_epay_source
    sanitize_epay_source
    clean_epay_residue_files
    verify_epay_security_fixes
  fi

  write_env "${port}"
  write_dockerfile
  write_dockerignore
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
  apply_epay_egress_firewall

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
  ensure_python3
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
  repair_epay_source_layout
  validate_epay_source
  sanitize_epay_source
  clean_epay_residue_files
  verify_epay_security_fixes
  [ -s "${tmp_config}" ] && cp -a "${tmp_config}" config.php || true
  [ -s "${tmp_lock}" ] && mkdir -p install && cp -a "${tmp_lock}" install/install.lock || true
  rm -f "${tmp_config}" "${tmp_lock}"

  cd "${APP_DIR}"
  write_dockerfile
  write_dockerignore
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
  apply_epay_egress_firewall
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
    apply_epay_egress_firewall
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
  repair_epay_source_layout
  validate_epay_source
  sanitize_epay_source
  clean_epay_residue_files
  verify_epay_security_fixes
  ensure_placeholder_config
  fix_permissions
  write_dockerfile
  write_dockerignore
  docker build --no-cache -t "${CUSTOM_IMAGE}" -f Dockerfile .
  docker run --rm --entrypoint sh "${CUSTOM_IMAGE}" -lc '
    test -f /var/www/html/index.php &&
    test -f /var/www/html/includes/common.php &&
    test -f /var/www/html/includes/lib/Template.php &&
    test -f /var/www/html/install/index.php &&
    test ! -f /var/www/html/config.php &&
    test ! -f /var/www/html/install/install.lock
  '
  docker push "${CUSTOM_IMAGE}"
  success "推送完成：${CUSTOM_IMAGE}"
}

restore_custom_app() {
  restore_app
  if [ -d "${APP_DIR}" ]; then
    warn "恢复完成，生产环境默认切换为源码模式更新/启动，避免镜像供应链风险..."
    update_app source
  fi
}

main_menu() {
  while true; do
    clear 2>/dev/null || true
    show_status
    echo "1. 镜像模式安装"
    echo "2. 镜像模式更新"
    echo "3. 备份（/home/${BACKUP_PREFIX}-YYYYmmddHHMMSS.tar.gz）"
    echo "4. 恢复（从 /home/${BACKUP_PREFIX}-*.tar.gz 获取，回车默认最新）"
    echo "5. 登录docker"
    echo "6. 构建并推送 Docker 镜像（zaixiangjian/epay）"
    echo "7. 卸载"
    echo "------------------------------------------------"
    echo
    echo "11. 源码模式安装（推荐生产）"
    echo "12. 源码模式更新（推荐生产）"
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
