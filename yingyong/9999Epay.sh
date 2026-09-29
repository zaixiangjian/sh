#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

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

apply_epay_egress_firewall() (
  ensure_iptables || return 1
  exec 8>/run/lock/epay-egress.lock || return 1
  flock -x 8 || return 1
  local gateway cidr hook
  gateway="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1])[1])' "$EPAY_NETWORK_SUBNET")"
  # --noflush 的事务只更新 Epay 自有链；绝不清空其他应用规则。
  {
    echo '*filter'
    echo ':EPAY-EGRESS - [0:0]'
    echo '-F EPAY-EGRESS'
    echo '-A EPAY-EGRESS -m conntrack --ctdir REPLY -j RETURN'
    echo "-A EPAY-EGRESS -d ${gateway}/32 -j REJECT"
    echo "-A EPAY-EGRESS -d ${EPAY_NETWORK_SUBNET} -j RETURN"
    for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4; do
      echo "-A EPAY-EGRESS -d $cidr -j REJECT"
    done
    echo '-A EPAY-EGRESS -j RETURN'
    echo ':EPAY-HOST - [0:0]'
    echo '-F EPAY-HOST'
    echo '-A EPAY-HOST -m conntrack --ctdir REPLY -j RETURN'
    echo '-A EPAY-HOST -j REJECT'
    echo COMMIT
  } | iptables-restore --wait 10 --noflush || return 1
  # 独立 FORWARD 前置入口：990 后续将宽泛 br+ ACCEPT 插入 DOCKER-USER 也不能绕过。
  for hook in FORWARD DOCKER-USER INPUT; do
    local chain=EPAY-EGRESS
    [ "$hook" != INPUT ] || chain=EPAY-HOST
    iptables -w 10 -I "$hook" 1 -s "$EPAY_NETWORK_SUBNET" -j "$chain" || return 1
    python3 - "$hook" "$EPAY_NETWORK_SUBNET" "$chain" <<'PY' || return 1
import subprocess,sys
hook,subnet,chain=sys.argv[1:]
s=subprocess.check_output(['iptables','-S',hook],text=True).splitlines()
indices=[i for i,l in enumerate([x for x in s if x.startswith('-A ')],1) if l == f'-A {hook} -s {subnet} -j {chain}']
for i in reversed(indices[1:]): subprocess.run(['iptables','-w','10','-D',hook,str(i)],check=True)
PY
  done
  success "Epay 出站规则已生效；保留端口与其他应用规则"
)

ensure_epay_backup_dir() {
  install -d -m 0700 "${APP_DIR}/security-backups"
}

write_epay_persistence() (
  set -e
  ensure_python3
  ensure_iptables
  command -v flock >/dev/null || install_pkg util-linux
  if ! command -v crontab >/dev/null; then
    if command -v apt-get >/dev/null; then install_pkg cron; else install_pkg cronie; fi
  fi
  command -v crontab >/dev/null
  # Start the scheduler only if needed; do not restart existing jobs.
  if systemctl cat cron.service >/dev/null 2>&1; then
    systemctl enable --now cron.service >/dev/null
  else
    systemctl enable --now crond.service >/dev/null
  fi
  ensure_epay_backup_dir
  install -d -m 0700 "${APP_DIR}/ops"
  local stage
  stage="$(mktemp -d "${APP_DIR}/ops/.persistence.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  # 同一函数生成开机/定时入口，避免与即时入口实现漂移。
  {
    printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
    printf 'EPAY_NETWORK_SUBNET=%q\n' "$EPAY_NETWORK_SUBNET"
    printf '%s\n' 'ensure_iptables() { command -v iptables >/dev/null; }' 'success() { :; }'
    declare -f apply_epay_egress_firewall
    printf '%s\n' 'apply_epay_egress_firewall'
  } > "$stage/epay-egress"
  cat > "$stage/epay-egress.service" <<'EPAY_SERVICE'
[Unit]
Description=Epay-only egress restrictions
After=docker.service network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/epay-egress
[Install]
WantedBy=multi-user.target
EPAY_SERVICE
  cat > "$stage/epay-egress.timer" <<'EPAY_TIMER'
[Unit]
Description=Reconcile Epay-only firewall hook order
[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
Unit=epay-egress.service
[Install]
WantedBy=timers.target
EPAY_TIMER
  cat > "$stage/cron-runner.py" <<'EPAY_RUNNER'
#!/usr/bin/python3
"""Epay scheduler: no key in argv, crontab or persistent URL file."""
import pathlib,subprocess,sys,urllib.request,urllib.parse,fcntl,os
os.umask(0o077)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl): return None

def main():
    action=sys.argv[1] if len(sys.argv)==2 else ''
    if action not in ('notify','order','settle','--check'): return 1
    if not pathlib.Path('/home/docker/Epay/html/install/install.lock').is_file(): return 0
    helper=b'<?php\n// CLI only: read the effective cron key without invoking business bootstrap/cron.\ntry {\n    require \'/var/www/html/config.php\';\n    if (!preg_match(\'/^[A-Za-z0-9_]+$/D\', $dbconfig[\'dbqz\'])) exit(1);\n    $db = new PDO(\'mysql:host=\'.$dbconfig[\'host\'].\';port=\'.($dbconfig[\'port\'] ?? 3306).\';dbname=\'.$dbconfig[\'dbname\'].\';charset=utf8mb4\', $dbconfig[\'user\'], $dbconfig[\'pwd\'], [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);\n    $prefix=$dbconfig[\'dbqz\'].\'_\';\n    $cache=$db->query("SELECT v FROM {$prefix}cache WHERE k=\'config\' LIMIT 1")->fetchColumn();\n    $conf=@unserialize($cache ?: \'\', [\'allowed_classes\'=>false]);\n    $key=$db->query("SELECT v FROM {$prefix}config WHERE k=\'cronkey\' LIMIT 1")->fetchColumn();\n    if (is_array($conf) && !empty($conf[\'version\']) && ($conf[\'cronkey\'] ?? \'\') !== $key) exit(2);\n    if (!is_string($key) || strlen($key)<16 || preg_match(\'/[\\r\\n\\x00]/\',$key)) exit(3);\n    echo $key;\n} catch (PDOException $e) { exit(($e->errorInfo[1] ?? 0) == 1146 ? 10 : 1); } catch (Throwable $e) { exit(1); }\n'
    p=subprocess.run(['docker','exec','-i','epay-php','php','-d','display_errors=0','-d','log_errors=0'],input=helper,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20)
    if p.returncode == 10: return 0
    if p.returncode or not p.stdout or len(p.stdout)>1024:return 1
    key=p.stdout.decode()
    if action=='--check': print('cron key/cache synchronized; no task executed');return 0
    lock=open('/run/lock/epay-cron-'+action+'.lock','w')
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:return 0
    env=pathlib.Path('/home/docker/Epay/.env').read_text().splitlines()
    port=next(x.split('=',1)[1].strip().strip('"\'') for x in env if x.startswith('APP_PORT='))
    if not port.isdigit():return 1
    url='http://127.0.0.1:'+port+'/cron.php?'+urllib.parse.urlencode({'do':action,'key':key})
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
    with opener.open(url,timeout=50) as response: response.read()
    return 0

if __name__=='__main__':
    try: sys.exit(main())
    except Exception: sys.exit(1)
EPAY_RUNNER
  # APP_DIR is fixed for this manager; no keys are stored in these templates.
  bash -n "$stage/epay-egress"
  python3 - "$stage/cron-runner.py" <<'EPAY_COMPILE'
import pathlib,sys
compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], 'exec')
EPAY_COMPILE
  install -d /usr/local/sbin /etc/systemd/system
  # Atomic replace: active timers can never read partially written executables.
  install -m 0750 "$stage/epay-egress" /usr/local/sbin/epay-egress.new
  mv -f /usr/local/sbin/epay-egress.new /usr/local/sbin/epay-egress
  install -m 0700 "$stage/cron-runner.py" "${APP_DIR}/ops/cron-runner.py.new"
  mv -f "${APP_DIR}/ops/cron-runner.py.new" "${APP_DIR}/ops/cron-runner.py"
  install -m 0644 "$stage/epay-egress.service" /etc/systemd/system/epay-egress.service
  install -m 0644 "$stage/epay-egress.timer" /etc/systemd/system/epay-egress.timer
  update_epay_crontab install
  systemctl daemon-reload
  systemctl enable epay-egress.service epay-egress.timer >/dev/null
  # Only start an inactive timer. Never restart Docker or invoke the funds runner.
  if ! systemctl is-active --quiet epay-egress.timer; then
    systemctl start epay-egress.timer
  fi
)

update_epay_crontab() (
  set -e
  exec 9>/run/lock/epay-crontab.lock
  flock -x 9
  python3 - "$1" "${APP_DIR}/ops/cron-runner.py" <<'EPAY_CRON'
import subprocess,sys,shlex
mode,runner=sys.argv[1:]
p=subprocess.run(['crontab','-l'],capture_output=True,text=True)
if p.returncode and 'no crontab for' not in p.stderr.lower():
    raise SystemExit('Cannot safely read crontab; unchanged')
rows=[]
for line in p.stdout.splitlines():
    if line == '# Epay managed cron (no credentials)': continue
    try: parts=shlex.split(line)
    except ValueError: parts=[]
    if runner in parts and any(a in parts for a in ('notify','order','settle')): continue
    rows.append(line)
if mode == 'install':
    rows.append('# Epay managed cron (no credentials)')
    for schedule,action in [('* * * * *','notify'),('10 0 * * *','order'),('20 0 * * *','settle')]:
        rows.append(f'{schedule} /usr/bin/python3 {shlex.quote(runner)} {action} >/dev/null 2>&1')
subprocess.run(['crontab','-'],input='\n'.join(rows)+'\n',text=True,check=True)
EPAY_CRON
)

remove_epay_persistence() (
  set -e
  # Stop only Epay-owned jobs before deleting application files.
  systemctl disable --now epay-egress.timer epay-egress.service >/dev/null 2>&1 || true
  if command -v crontab >/dev/null; then update_epay_crontab remove; fi
  exec 8>/run/lock/epay-egress.lock || return 1
  flock -x 8 || return 1
  if command -v iptables >/dev/null; then
    # Remove only jumps targeting our two chains (including old subnets).
    python3 - <<'EPAY_REMOVE'
import subprocess,shlex
for hook in ('FORWARD','DOCKER-USER','INPUT'):
    p=subprocess.run(['iptables','-w','10','-S',hook],capture_output=True,text=True)
    for line in p.stdout.splitlines():
        args=shlex.split(line)
        if args[:2] != ['-A',hook]: continue
        if any(args[i]=='-j' and args[i+1] in ('EPAY-EGRESS','EPAY-HOST') for i in range(len(args)-1)):
            subprocess.run(['iptables','-w','10','-D']+args[1:],check=True)
for chain in ('EPAY-EGRESS','EPAY-HOST'):
    if subprocess.run(['iptables','-w','10','-S',chain],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0:
        subprocess.run(['iptables','-w','10','-F',chain],check=True)
        subprocess.run(['iptables','-w','10','-X',chain],check=True)
EPAY_REMOVE
  fi
  rm -f /usr/local/sbin/epay-egress /etc/systemd/system/epay-egress.service /etc/systemd/system/epay-egress.timer
  rm -f "${APP_DIR}/ops/cron-runner.py"
  systemctl daemon-reload
)

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
html/admin/@login.lock
html/lakala_log.txt
html/assets/uploads/
html/upload/
html/uploads/
html/plugins/sandpay/logs/
html/plugins/kuaiqian/temp/
html/plugins/douyinpay/cert/
html/epay_release*
html/epay_update*
html/.env
html/.git/
html/**/.git/
html/**/*.env
html/**/*.zip
html/**/*.tar
html/**/*.tar.gz
html/**/*.tgz
html/**/*.7z
html/**/*.rar
html/**/*.log
html/**/*.ini
html/**/*.key
html/**/*.bak*
html/**/*.old*
html/**/*.orig*
html/**/*.save*
html/**/*.swp
html.before_seed_*/
html.new.*/
*.before_restore_*/
Epay.before_restore_*/
security-backups/
mysql/
.env
.git/
EOF
}

write_nginx_conf() {
  cat > "${APP_DIR}/nginx.conf" <<'EOF'
log_format epay_safe '$remote_addr [$time_local] "$request_method $uri $server_protocol" $status $body_bytes_sent';
server {
    access_log /var/log/nginx/access.log epay_safe;
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
    # 升级脚本不得公开访问；除 index.php 外的安装目录 PHP 均禁止执行。
    location = /install/update.php {
        return 404;
    }
    location ~* ^/install/(?!index\.php$).*\.php$ {
        return 404;
    }
    location /install/ {
        if (-f $document_root/install/install.lock) { return 404; }
        try_files $uri /install/index.php?$query_string;
    }

    # Only this fixed callback may execute below the denied plugins tree.
    location = /plugins/paypal/webhook.php {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/plugins/paypal/webhook.php;
        fastcgi_param SCRIPT_NAME /plugins/paypal/webhook.php;
        fastcgi_pass php:9000;
    }
    # Cron URLs contain a credential: neither access nor error logs may retain it.
    location = /cron.php {
        access_log off;
        error_log /dev/null crit;
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root/cron.php;
        fastcgi_param SCRIPT_NAME /cron.php;
        fastcgi_pass php:9000;
    }
    location = /lakala_log.txt { deny all; }
    location = /admin/@login.lock { deny all; }
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
  chmod 600 "${APP_DIR}/.env"
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
  return 0
}

validate_epay_source() {
  local missing=0
  for path in \
    "index.php" \
    "includes/common.php" \
    "includes/lib/Template.php" \
    "includes/vendor/composer/autoload_real.php" \
    "install/install.sql" \
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
  return 0
}

clean_epay_residue_files() {
  if [ ! -d "${HTML_DIR}" ]; then
    return 0
  fi
  local count
  count="$(find "${HTML_DIR}" -type f \( -name '*.bak*' -o -name '*.old*' -o -name '*.orig*' -o -name '*.save*' -o -name '*.swp' \) | wc -l | tr -d ' ')"
  if [ "${count}" != "0" ]; then
    warn "检测到 Web 根目录残留备份文件 ${count} 个，正在移出避免公网泄露..."
    ensure_epay_backup_dir
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
  return 0
}

scan_epay_sensitive_build_files() {
  if [ ! -d "${HTML_DIR}" ]; then
    return 0
  fi
  local found_file
  found_file="$(mktemp)"
  find "${HTML_DIR}" -type f \( \
    -name '*.bak*' -o -name '*.old*' -o -name '*.orig*' -o -name '*.save*' -o -name '*.swp' \
    -o -name '*.env' -o -name '*.log' -o -name '*.key' \
    -o -name '*.phtml' -o -name '*.phar' -o -name '*.php[0-9]*' \
    -o -name '.env' \
  \) -print >"${found_file}"
  if [ -s "${found_file}" ]; then
    error "检测到不应进入镜像/公网目录的敏感文件："
    sed -n '1,80p' "${found_file}"
    rm -f "${found_file}"
    return 1
  fi
  if find "${HTML_DIR}" -type f \( -name '*.pem' -o -name '*.crt' \) -print0 | xargs -0 grep -Il "PRIVATE KEY" >"${found_file}" 2>/dev/null && [ -s "${found_file}" ]; then
    error "检测到私钥 PEM/CRT 文件，拒绝进入镜像："
    sed -n '1,80p' "${found_file}"
    rm -f "${found_file}"
    return 1
  fi
  rm -f "${found_file}"
}


scan_epay_untracked_source_files() {
  if [ ! -d "${HTML_DIR}/.git" ]; then
    return 0
  fi
  local found_file
  found_file="$(mktemp)"
  git -C "${HTML_DIR}" ls-files --others --exclude-standard | grep -Ei '\.(php|php[0-9]*|phtml|phar|cgi|pl|py|sh)$' | grep -vx 'config.php' >"${found_file}" || true
  if [ -s "${found_file}" ]; then
    error "检测到未跟踪的可执行/PHP 残留文件，拒绝继续："
    sed -n '1,120p' "${found_file}"
    rm -f "${found_file}"
    return 1
  fi
  rm -f "${found_file}"
}
validate_repo_origin() {
  if [ -d "${HTML_DIR}/.git" ]; then
    local origin
    origin="$(git -C "${HTML_DIR}" remote get-url origin 2>/dev/null || true)"
    if [ "${origin}" != "${REPO_URL}" ]; then
      error "源码仓库 origin 不符合预期：${origin:-未设置}"
      error "预期：${REPO_URL}"
      return 1
    fi
  fi
  return 0
}

validate_backup_archive() {
  local archive="$1"
  local list_file type_file
  list_file="$(mktemp)"
  type_file="$(mktemp)"
  if ! tar -tzf "${archive}" >"${list_file}"; then
    rm -f "${list_file}" "${type_file}"
    error "备份文件无法读取：${archive}"
    return 1
  fi
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "${list_file}" || grep -Evq '^Epay(/|$)' "${list_file}"; then
    error "备份归档包含异常路径，拒绝恢复：${archive}"
    sed -n '1,80p' "${list_file}"
    rm -f "${list_file}" "${type_file}"
    return 1
  fi
  if ! tar -tvzf "${archive}" >"${type_file}"; then
    rm -f "${list_file}" "${type_file}"
    error "备份文件无法读取详细清单：${archive}"
    return 1
  fi
  if awk '{c=substr($1,1,1); if(c!="-" && c!="d") bad=1} END{exit bad?0:1}' "${type_file}"; then
    error "备份归档包含符号链接、硬链接或特殊文件，拒绝恢复：${archive}"
    sed -n '1,80p' "${type_file}"
    rm -f "${list_file}" "${type_file}"
    return 1
  fi
  rm -f "${list_file}" "${type_file}"
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
  return 0
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
    image: nginx:1.31-alpine
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

seed_html_from_image() (
  local cid new_html old_html ts
  mkdir -p "${APP_DIR}"
  warn "正在从镜像 ${CUSTOM_IMAGE} 提取源码到临时目录..."
  docker pull "${CUSTOM_IMAGE}"
  new_html="$(mktemp -d "${APP_DIR}/html.new.XXXXXX")"
  trap 'if [ -n "${cid:-}" ]; then docker rm "$cid" >/dev/null 2>&1 || true; fi; rm -rf "$new_html"' EXIT
  cid="$(docker create "${CUSTOM_IMAGE}" sh -c true)"
  if ! docker cp "${cid}:/var/www/html/." "${new_html}/"; then
    docker rm "${cid}" >/dev/null 2>&1 || true
    rm -rf "${new_html}"
    error "从镜像提取源码失败，已保留原 ${HTML_DIR}"
    return 1
  fi
  docker rm "${cid}" >/dev/null

  local old_html_dir="${HTML_DIR}"
  HTML_DIR="${new_html}"
  rm -rf "${HTML_DIR}/.git"
  find "${HTML_DIR}" -path '*/.git' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  repair_epay_source_layout
  validate_epay_source
  sanitize_epay_source
  clean_epay_residue_files
  verify_epay_security_fixes
  HTML_DIR="${old_html_dir}"

  quiesce_epay_writers
  preserve_epay_runtime "${HTML_DIR}" "${new_html}"

  ts="$(date +%Y%m%d%H%M%S)"
  old_html="${HTML_DIR}.before_seed_${ts}"
  [ -e "${HTML_DIR}" ] && mv "${HTML_DIR}" "${old_html}"
  mv "${new_html}" "${HTML_DIR}"
  if [ -d "${old_html}" ]; then
    warn "旧 html 已保留：${old_html}"
  fi
  return 0
)

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
  return 0
}

epay_runtime_paths() {
  printf '%s\n' config.php install/install.lock assets/img assets/uploads upload uploads plugins/sandpay/logs plugins/kuaiqian/temp plugins/douyinpay/cert admin/@login.lock lakala_log.txt
}

preserve_epay_runtime() {
  python3 - "$1" "$2" <<'PYRUNTIME'
from pathlib import Path
import shutil,sys,re
src,dst=map(Path,sys.argv[1:])
rels='config.php install/install.lock assets/img assets/uploads upload uploads plugins/sandpay/logs plugins/kuaiqian/temp plugins/douyinpay/cert admin/@login.lock lakala_log.txt'.split()
for rel in rels:
 p=src/rel
 if not p.exists() and not p.is_symlink(): continue
 nodes=[p]+(list(p.rglob('*')) if p.is_dir() else [])
 for n in nodes:
  if n.is_symlink() or not(n.is_file() or n.is_dir()): raise RuntimeError('unsafe runtime entry: '+str(n))
  if n.is_file() and rel!='config.php' and re.search(r'\.(php[0-9]*|phtml|phar|sh|py|cgi|pl)$',n.name,re.I): raise RuntimeError('executable runtime entry: '+str(n))
  target=dst/n.relative_to(src)
  for parent in [target]+list(target.parents):
   if parent==dst.parent: break
   if parent.is_symlink(): raise RuntimeError('runtime destination symlink')
 for n in nodes:
  target=dst/n.relative_to(src)
  if n.is_dir(): target.mkdir(parents=True,exist_ok=True)
  else: target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(n,target)
PYRUNTIME
}

quiesce_epay_writers() {
  # Do not take a live snapshot: stop only this application's writers/ingress.
  local c
  for c in epay-nginx epay-php; do
    if docker inspect "$c" >/dev/null 2>&1; then docker stop "$c" >/dev/null; fi
  done
}

fix_permissions() {
  ensure_epay_backup_dir
  mkdir -p "${HTML_DIR}" "${MYSQL_DIR}"
  ensure_placeholder_config
  python3 - "$HTML_DIR" <<'PY'
import os,sys,pathlib
r=pathlib.Path(sys.argv[1])
for p in r.rglob('*'):
 if p.is_symlink(): raise RuntimeError('webroot symlink requires review')
# 不跟随链接；源码归 root，安装前仅配置文件/安装锁目录临时可写。
for base,ds,fs in os.walk(r,followlinks=False):
 p=pathlib.Path(base); os.chown(p,0,0); os.chmod(p,0o755)
 for n in fs:
  p=pathlib.Path(base,n)
  if not p.is_symlink(): os.chown(p,0,0); os.chmod(p,0o644)
for rel in ['assets/img','assets/uploads','upload','uploads','plugins/sandpay/logs','plugins/kuaiqian/temp','plugins/douyinpay/cert']:
 p=r/rel; p.mkdir(parents=True,exist_ok=True)
 for base,ds,fs in os.walk(p,followlinks=False):
  d=pathlib.Path(base)
  if d.is_symlink(): raise RuntimeError('runtime symlink refused')
  os.chown(d,0,82); os.chmod(d,0o1775)
  for n in fs:
   f=d/n
   if f.is_symlink(): raise RuntimeError('runtime symlink refused')
   if f.suffix.lower() not in ['.php','.phtml','.phar','.sh','.py']:
    os.chown(f,82,82); os.chmod(f,0o644)
# 登录限制会创建/删除锁：sticky 目录保护 root 拥有的现有 PHP 文件。
os.chown(r/'admin',0,82); os.chmod(r/'admin',0o1775)
for rel in ['admin/@login.lock','lakala_log.txt']:
 p=r/rel
 if rel=='lakala_log.txt' and not p.exists(): p.touch()
 if p.exists(): os.chown(p,82,82); os.chmod(p,0o600)
os.chown(r/'config.php',0,82); os.chmod(r/'config.php',0o640)
if not (r/'install/install.lock').exists():
 os.chown(r/'config.php',82,82); os.chmod(r/'config.php',0o600)
 os.chown(r/'install',0,82); os.chmod(r/'install',0o1775)
PY
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
  else
    if [ ! -d "${HTML_DIR}/.git" ]; then
      if [ -e "${HTML_DIR}" ] && [ -n "$(ls -A "${HTML_DIR}" 2>/dev/null || true)" ]; then
        error "${HTML_DIR} 已存在但不是 git 仓库，请先备份/移走后重试。"
        return 1
      fi
      rm -rf "${HTML_DIR}"
      git clone --depth=1 "${REPO_URL}" "${HTML_DIR}"
    fi
    validate_repo_origin
    repair_epay_source_layout
    validate_epay_source
    sanitize_epay_source
    clean_epay_residue_files
    scan_epay_untracked_source_files
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
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d
  else
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  fi
  write_epay_persistence
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
  if [ ! -f "${APP_DIR}/.env" ] || [ ! -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    error "未找到已安装配置，请先执行安装"
    return 1
  fi
  if [ "${mode}" = "image" ]; then
    seed_html_from_image
    cd "${APP_DIR}"
    write_dockerfile
    write_dockerignore
    write_nginx_conf
    write_compose "${mode}"
    fix_permissions
    local dc
    dc="$(compose_cmd)"
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d
    write_epay_persistence
    apply_epay_egress_firewall
    success "镜像模式更新完成"
    return 0
  fi
  if [ ! -d "${HTML_DIR}/.git" ]; then
    error "未找到 ${HTML_DIR}，请先安装"
    return 1
  fi

  cd "${HTML_DIR}"
  local runtime_backup
  quiesce_epay_writers
  ensure_epay_backup_dir
  runtime_backup="$(mktemp -d "${APP_DIR}/security-backups/runtime.XXXXXX")"
  preserve_epay_runtime "${HTML_DIR}" "$runtime_backup"
  validate_repo_origin
  git fetch --depth=1 origin main
  git reset --hard origin/main
  repair_epay_source_layout
  validate_epay_source
  sanitize_epay_source
  clean_epay_residue_files
  scan_epay_untracked_source_files
  verify_epay_security_fixes
  preserve_epay_runtime "$runtime_backup" "${HTML_DIR}"

  cd "${APP_DIR}"
  write_dockerfile
  write_dockerignore
  write_nginx_conf
  write_compose "${mode}"
  fix_permissions
  local dc
  dc="$(compose_cmd)"
  ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
  write_epay_persistence
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
      ${dc} --env-file .env -f "${COMPOSE_FILE}" down || return 1
      if is_stack_running; then error "Epay 容器仍运行，拒绝继续"; return 1; fi
      return 0
    fi
  fi
  local c
  for c in epay-nginx epay-php epay-mysql; do
    if docker inspect "$c" >/dev/null 2>&1; then docker stop "$c" >/dev/null || return 1; fi
  done
  if is_stack_running; then return 1; fi
}

start_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    install_docker
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd)"
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build
    write_epay_persistence
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

  warn "备份会包含数据库、.env 密钥、商户/订单数据，请妥善保存。"

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证 MySQL 数据备份一致性..."
    stop_stack || return 1
  fi

  if ! tar -C "$(dirname "${APP_DIR}")" -czf "${archive}" "$(basename "${APP_DIR}")"; then
    rm -f "${archive}"
    if [ "${was_running}" -eq 1 ]; then start_stack; fi
    error "备份失败，未保留不完整归档"
    return 1
  fi
  chmod 600 "${archive}"

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
  local mode="${1:-source}"
  require_root
  install_docker
  local archive ts old_dir
  ensure_python3
  archive="$(select_backup)" || return 1
  validate_backup_archive "${archive}" || return 1

  warn "即将从备份恢复：${archive}"
  warn "当前目录会移动为 ${APP_DIR}.before_restore_时间戳"
  read -r -p "确认恢复？[y/N]: " yn
  case "${yn:-N}" in
    y|Y) ;;
    *) warn "已取消恢复"; return 0 ;;
  esac

  mkdir -p "$(dirname "${APP_DIR}")"
  ts="$(date +%Y%m%d%H%M%S)"
  old_dir="${APP_DIR}.before_restore_${ts}"
  local restore_tmp
  restore_tmp="$(mktemp -d "$(dirname "${APP_DIR}")/.epay-restore.XXXXXX")"

  if ! tar --same-owner --same-permissions -C "${restore_tmp}" -xzf "${archive}"; then
    error "解压失败，未替换当前目录。"
    rm -rf "${restore_tmp}"
    return 1
  fi
  if [ ! -d "${restore_tmp}/Epay" ]; then
    error "备份结构不正确：归档内未找到 Epay/"
    rm -rf "${restore_tmp}"
    return 1
  fi

  if ! (HTML_DIR="${restore_tmp}/Epay/html"; validate_epay_source && verify_epay_security_fixes); then
    rm -rf "${restore_tmp}"
    return 1
  fi
  if [ ! -f "${restore_tmp}/Epay/.env" ]; then
    rm -rf "${restore_tmp}"
    error "备份缺少 .env，拒绝恢复"
    return 1
  fi
  # Normalize only staged source/config, never database numeric ownership.
  if ! (
    APP_DIR="${restore_tmp}/Epay"
    HTML_DIR="${APP_DIR}/html"
    MYSQL_DIR="${APP_DIR}/mysql"
    write_dockerfile || exit 1
    write_dockerignore || exit 1
    write_nginx_conf || exit 1
    write_compose "$mode" || exit 1
    chmod 600 "${APP_DIR}/.env" || exit 1
    fix_permissions || exit 1
  ); then
    rm -rf "${restore_tmp}"
    error "恢复预检失败，当前目录未替换"
    return 1
  fi
  stop_stack || { rm -rf "${restore_tmp}"; return 1; }

  if [ -e "${APP_DIR}" ]; then
    mv "${APP_DIR}" "${old_dir}"
  fi
  if mv "${restore_tmp}/Epay" "${APP_DIR}"; then
    rm -rf "${restore_tmp}"
    start_stack
    success "恢复完成，已启动服务"
    if [ -d "${old_dir}" ]; then warn "旧目录保留在：${old_dir}"; fi
  else
    error "恢复替换失败，正在回滚..."
    rm -rf "${APP_DIR}" "${restore_tmp}"
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
  remove_epay_persistence
  stop_stack || return 1
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

docker_push_app() (
  require_root
  install_docker
  ensure_python3
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
  # Never delete the live Git checkout or bake runtime data into a public image.
  scan_epay_untracked_source_files
  local build_stage
  build_stage="$(mktemp -d "${APP_DIR}/.image-build.XXXXXX")"
  trap 'rm -rf "$build_stage"' EXIT
  cp -a "${HTML_DIR}" "$build_stage/html"
  APP_DIR="$build_stage"
  HTML_DIR="$build_stage/html"
  MYSQL_DIR="$build_stage/mysql"
  cd "${APP_DIR}"
  while IFS= read -r rel; do
    # assets/img contains shipped application graphics: preserve defaults.
    [ "$rel" = assets/img ] || rm -rf "${HTML_DIR:?}/$rel"
  done < <(epay_runtime_paths)
  repair_epay_source_layout
  validate_epay_source
  rm -rf "${HTML_DIR}/.git"
  find "${HTML_DIR}" -path '*/.git' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  sanitize_epay_source
  clean_epay_residue_files
  scan_epay_untracked_source_files
  verify_epay_security_fixes
  scan_epay_sensitive_build_files
  write_dockerfile
  write_dockerignore
  docker build --no-cache -t "${CUSTOM_IMAGE}" -f Dockerfile .
  docker run --rm --entrypoint sh "${CUSTOM_IMAGE}" -lc '
    test -f /var/www/html/index.php &&
    test -f /var/www/html/includes/common.php &&
    test -f /var/www/html/includes/lib/Template.php &&
    test -f /var/www/html/install/index.php &&
    test -f /var/www/html/install/install.sql &&
    test ! -f /var/www/html/config.php &&
    test ! -f /var/www/html/install/install.lock &&
    test ! -d /var/www/html/.git &&
    ! find /var/www/html -type f \( -name "*.bak*" -o -name "*.old*" -o -name "*.orig*" -o -name "*.save*" -o -name "*.swp" -o -name "*.env" -o -name "*.log" -o -name "*.key" -o -name "*.zip" -o -name "*.tar" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.rar" -o -name "epay_release*" -o -name "epay_update*" \) | grep -q . &&
    ! find /var/www/html -type f \( -name "*.pem" -o -name "*.crt" \) -print0 | xargs -0 grep -Il "PRIVATE KEY" | grep -q .
  '
  docker push "${CUSTOM_IMAGE}"
  success "推送完成：${CUSTOM_IMAGE}"
)

restore_custom_app() {
  local mode="${1:-source}"
  restore_app "$mode"
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
      4) restore_custom_app image; pause ;;
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
