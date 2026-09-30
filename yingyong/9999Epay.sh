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
"""Candidate only. Never retries financial jobs. Logs contain fixed reason codes only."""
import fcntl
import os
import pathlib
import re
import subprocess
import sys
import syslog
import urllib.parse
import urllib.request

os.umask(0o077)
APP = pathlib.Path('/home/docker/Epay')
MAX_BODY = 1024 * 1024

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def alert(action, reason):
    # Never include exceptions, HTTP bodies, credentials, merchant IDs or URLs.
    syslog.openlog('epay-cron', syslog.LOG_PID, syslog.LOG_DAEMON)
    syslog.syslog(syslog.LOG_ERR, 'action='+action+' reason='+reason)
    print('epay-cron action='+action+' reason='+reason, file=sys.stderr)
    return 1

def validate_response(action, status, body):
    if status != 200 or len(body) > MAX_BODY:
        return False
    try:
        text = body.decode('utf-8').strip()
    except UnicodeDecodeError:
        return False
    if any(x in text for x in ('Fatal error', 'Warning:', 'Notice:', '监控密钥', '<html', '<!DOCTYPE', '记录插入失败')):
        return False
    if action == 'notify':
        # Callback failures can coexist with final ok!: warn rather than silently succeeding.
        return text.endswith('ok!') and '失败' not in text
    if action == 'order':
        return bool(re.fullmatch(r'(?:\d{8}订单统计与清理任务执行成功|订单统计与清理任务今日已完成(?:，余额不足提醒已发送给\d+位商户)?)', text))
    if action == 'settle':
        return bool(re.fullmatch(r'(?:自动生成结算列表今日已完成|自动生成结算列表成功 allmony=\d+(?:\.\d+)? num=\d+)', text))
    return False

def main():
    action = sys.argv[1] if len(sys.argv) == 2 else ''
    if action not in ('notify', 'order', 'settle', '--check'):
        return alert('invalid', 'invalid-action')
    if not (APP/'html/install/install.lock').is_file():
        return alert(action, 'not-installed')
    # Lock before reading key; duplicate invocations are benign and do not execute tasks.
    with open('/run/lock/epay-cron-'+action+'.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        helper = KEY_READER
        p = subprocess.run(['docker', 'exec', '-i', 'epay-php', 'php', '-d', 'display_errors=0', '-d', 'log_errors=0'], input=helper, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
        if p.returncode or not p.stdout or len(p.stdout) > 1024:
            return alert(action, 'key-or-cache-unavailable')
        key = p.stdout.decode('utf-8')
        if len(key) < 16 or any(c in key for c in '\r\n\x00'):
            return alert(action, 'invalid-key')
        if action == '--check':
            print('cron key/cache synchronized; no task executed')
            return 0
        env = (APP/'.env').read_text().splitlines()
        ports = [x.split('=',1)[1].strip().strip('"\'') for x in env if x.startswith('APP_PORT=')]
        if len(ports) != 1 or not ports[0].isdigit() or not 1 <= int(ports[0]) <= 65535:
            return alert(action, 'invalid-port')
        url = 'http://127.0.0.1:'+ports[0]+'/cron.php?'+urllib.parse.urlencode({'do':action,'key':key})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        # One request only. A timeout may mean money mutation already happened; never retry.
        with opener.open(url, timeout=50) as response:
            body = response.read(MAX_BODY+1)
            if not validate_response(action, response.status, body):
                return alert(action, 'business-response-rejected')
        return 0

# Filled from the existing installer, which reads config/cache only, not cron bootstrap.
KEY_READER = b'<?php\n// CLI only: read the effective cron key without invoking business bootstrap/cron.\ntry {\n    require \'/var/www/html/config.php\';\n    if (!preg_match(\'/^[A-Za-z0-9_]+$/D\', $dbconfig[\'dbqz\'])) exit(1);\n    $db = new PDO(\'mysql:host=\'.$dbconfig[\'host\'].\';port=\'.($dbconfig[\'port\'] ?? 3306).\';dbname=\'.$dbconfig[\'dbname\'].\';charset=utf8mb4\', $dbconfig[\'user\'], $dbconfig[\'pwd\'], [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);\n    $prefix=$dbconfig[\'dbqz\'].\'_\';\n    $cache=$db->query("SELECT v FROM {$prefix}cache WHERE k=\'config\' LIMIT 1")->fetchColumn();\n    $conf=@unserialize($cache ?: \'\', [\'allowed_classes\'=>false]);\n    $key=$db->query("SELECT v FROM {$prefix}config WHERE k=\'cronkey\' LIMIT 1")->fetchColumn();\n    if (is_array($conf) && !empty($conf[\'version\']) && ($conf[\'cronkey\'] ?? \'\') !== $key) exit(2);\n    if (!is_string($key) || strlen($key)<16 || preg_match(\'/[\\r\\n\\x00]/\',$key)) exit(3);\n    echo $key;\n} catch (PDOException $e) { exit(($e->errorInfo[1] ?? 0) == 1146 ? 10 : 1); } catch (Throwable $e) { exit(1); }\n'

if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        action = sys.argv[1] if len(sys.argv)==2 and sys.argv[1] in ('notify','order','settle','--check') else 'invalid'
        sys.exit(alert(action, 'transport-or-runtime-failure-no-retry'))
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
    if line in ('# Epay managed cron (no credentials)', '# Epay 托管式 Cron（无需凭证）'): continue
    try: parts=shlex.split(line)
    except ValueError: parts=[]
    if runner in parts and any(a in parts for a in ('notify','order','settle')): continue
    rows.append(line)
if mode == 'install':
    rows.append('# Epay 托管式 Cron（无需凭证）')
    for schedule,action in [('* * * * *','notify'),('10 0 * * *','order'),('20 0 * * *','settle')]:
        rows.append(f'{schedule} /usr/bin/python3 {shlex.quote(runner)} {action} >/dev/null 2>&1')
content='\n'.join(rows)+'\n'
if content != p.stdout:
    subprocess.run(['crontab','-'],input=content,text=True,check=True)
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
**
!Dockerfile
!html/
!html/**
html/private-receipts/
html/**/private-receipts/
html/**/private_receipts/
html/tests/
html/test/
html/fixtures/
html/**/fixtures/
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
html/**/*.key
html/**/*.sql
!html/install/*.sql
html/**/.svn/
html/**/.hg/
html/**/*.phtml
html/**/*.phar
html/**/*.php[0-9]*
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
private-receipts/
**/private-receipts/
**/private_receipts/
mysql/
.env
.git/
EOF
}

write_404_page() {
  cat > "${APP_DIR}/404.html" <<'EOF'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>页面不存在 · Epay</title>
<style>
:root{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;color-scheme:light}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;color:#263349;background:#f5f7fb}main{width:min(100%,470px);padding:44px 28px;text-align:center;background:white;border:1px solid #e8edf5;border-radius:18px;box-shadow:0 18px 45px rgba(32,47,74,.07)}.code{color:#3c73d5;font-size:72px;font-weight:750;line-height:1}h1{font-size:23px;margin:22px 0 10px}p{margin:0 0 29px;color:#66768b;line-height:1.7}.actions{display:flex;justify-content:center;flex-wrap:wrap;gap:12px}a,button{display:inline-block;padding:11px 19px;border-radius:9px;font:inherit;font-weight:600;cursor:pointer;text-decoration:none}a{color:#fff;background:#3776da;border:1px solid #3776da}button{color:#355278;background:#fff;border:1px solid #d6dfec}a:focus-visible,button:focus-visible{outline:3px solid #96baff;outline-offset:2px}
</style>
</head>
<body><main><div class="code" aria-hidden="true">404</div><h1>当前页面不存在</h1><p>链接可能已失效，或您输入的地址有误。</p><div class="actions"><button type="button" id="back">返回上一级</button><a href="/">回到首页</a></div></main>
<script>document.getElementById('back').addEventListener('click',function(){if(document.referrer){try{var previous=new URL(document.referrer);if(previous.origin===location.origin&&previous.href!==location.href){location.assign(previous.href);return}}catch(e){}}location.assign('/')});</script>
</body></html>
EOF
  # Public static error page: nginx workers must read it even under umask 077.
  chmod 0644 "${APP_DIR}/404.html" || return 1
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
    server_tokens off;
    error_page 404 /__epay_404.html;
    location = /__epay_404.html {
        internal;
        alias /etc/nginx/epay-404.html;
        default_type text/html;
        charset utf-8;
    }

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
    # Reject multiply encoded path metacharacters/backslashes, not query strings.
    if ($request_uri ~* "^[^?]*(%25(?:25)*(?:2e|2f|5c|00)|%5c|%00)") { return 404; }
    location /plugins { deny all; }
    location ^~ /includes { deny all; }
    location ^~ /vendor { deny all; }
    location = /plugins/baofu/cert/baofu.cer { try_files $uri =404; }
    location = /plugins/ysepay/cert/businessgate.cer { try_files $uri =404; }
    location = /plugins/sandpay/cert/sand.cer { try_files $uri =404; }
    location = /plugins/jdpay/inc/cert/wy_rsa_public_key.pem { try_files $uri =404; }
    location = /plugins/hnapay/cert/hnapaypay.pem { try_files $uri =404; }
    location = /plugins/hnapay/cert/hnapay.pem { try_files $uri =404; }
    location = /plugins/lakala/cert/lkl-apigw-v1.cer { try_files $uri =404; }
    location = /plugins/lakala/cert/lkl-apigw-v2.cer { try_files $uri =404; }
    location = /plugins/yseqt/cert/businessgate.cer { try_files $uri =404; }
    location = /plugins/yinyingtong/cert/M2.cer { try_files $uri =404; }
    location ~* ^/plugins(?:/|$) { deny all; }
    # Include-only PHP is private; browser template assets remain public.
    location ~* ^/template/.*\.(php[0-9]*|phtml|phar)(/|$) { return 404; }
    location ~* \.(tpl|inc|php[0-9]+|phtml|phar|key|p12|pfx|jks|keystore|log|sqlite[0-9]*|db|ini|conf|ya?ml|sh|sql|dump|tar|bz2|xz|zst|tgz|gz|zip|7z|rar|bak|old|orig|save|swp|swo)([./~_-]|$) { deny all; }
    location ~* (^|/)(Dockerfile|docker-compose[^/]*|compose[^/]*\.ya?ml|Makefile|nginx\.txt|IIS\.txt|README[^/]*|CHANGELOG[^/]*|LICENSE[^/]*|install\.lock|.*~)$ { deny all; }
    location ~* \.php/ { return 404; }
    location ~* ^/(assets|upload|uploads|static)/.*\.(php[0-9]*|phtml|phar)([./~_-]|$) { deny all; }

    # 禁止访问 config.php / .git / .env / composer.* / 备份包 / 隐藏文件，防止源码与敏感文件泄露。
    location ~ /\.(?!well-known(?:/|$)).* {
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
        try_files $uri =404;
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
    "includes/functions.php" \
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
  python3 - "$1" <<'PYARCH'
import sys,tarfile
with tarfile.open(sys.argv[1],'r:gz') as t:
    seen=set()
    for m in t:
        parts=m.name.rstrip('/').split('/')
        if not parts or parts[0]!='Epay' or any(x in ('','..','.') for x in parts) or m.name.startswith('/'):
            raise SystemExit('Unsafe archive path')
        if m.name.rstrip('/') in seen: raise SystemExit('Duplicate archive entry')
        seen.add(m.name.rstrip('/'))
        if m.name=='Epay/mysql/mysql.sock' and m.issym() and m.linkname=='/var/run/mysqld/mysqld.sock':
            continue
        if not(m.isfile() or m.isdir()): raise SystemExit('Unsafe archive member type')
        if m.mode & 0o6000: raise SystemExit('Unsafe privileged archive mode')
PYARCH
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

  harden_epay_ssrf || return 1

  if [ "${changed}" -eq 1 ]; then
    success "已清理已知后门特征"
  fi
  return 0
}

# Modern outbound code is a release prerequisite, not a patch insertion point.
# Legacy layouts must be upgraded/reviewed outside this packager; never silently rewrite.
harden_epay_ssrf() {
  python3 - "${HTML_DIR}/includes/functions.php" <<'PYSSRF' || return 1
import pathlib,re,sys
p=pathlib.Path(sys.argv[1])
if p.is_symlink() or not p.is_file(): raise SystemExit('Missing/unsafe outbound source')
t=p.read_text()
# Ignore comments: guard names in a comment are not evidence of executable guards.
t=re.sub(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|/\*.*?\*/|//[^\n]*|#[^\n]*", lambda m: '' if m.group(0).startswith(('/*','//','#')) else m.group(0), t, flags=re.S)
def block(name):
    matches=list(re.finditer(r'^function\s+'+name+r'\s*\(',t,re.M))
    if len(matches)!=1: raise SystemExit('Missing/ambiguous outbound function: '+name)
    start=matches[0].start()
    nxt=re.search(r'^function\s+',t[matches[0].end():],re.M)
    return t[start:matches[0].end()+nxt.start()] if nxt else t[start:]
def require(b,patterns):
    for pat in patterns:
        if not re.search(pat,b,re.S): raise SystemExit('Outbound security contract missing; source unchanged')
for name in ('epay_ip_in_cidr','epay_is_public_ip','epay_resolve_outbound_ips','epay_is_safe_outbound_url','epay_assert_safe_outbound_url'):
    block(name)
require(block('epay_is_public_ip'),[r"2000::/3",r"100\.64\.0\.0/10",r"127\.0\.0\.0/8",r"169\.254\.0\.0/16",r"epay_ip_in_cidr"])
require(block('epay_resolve_outbound_ips'),[r'DNS_A\s*\|\s*DNS_AAAA\s*\|\s*DNS_CNAME',r'epay_resolve_outbound_ips\('])
require(block('epay_outbound_target'),[r"\['http',\s*'https'\]",r"isset\(\$p\['user'\]\)",r"isset\(\$p\['pass'\]\)",r'in_array\(\$port,\s*\[80,443\],\s*true\)',r'foreach\(\$ips as \$ip\) if\(!epay_is_public_ip\(\$ip\)\)',r'epay_resolve_outbound_ips\(\$host\)'])
require(block('epay_outbound_curl_options'),[r'if\(\$proxyEnabled\) return false;',r"CURLOPT_PROXY\s*=>\s*''",r"CURLOPT_NOPROXY\s*=>\s*'\*'",r'CURLOPT_FOLLOWLOCATION\s*=>\s*false',r'CURLOPT_MAXREDIRS\s*=>\s*0',r'CURLOPT_SSL_VERIFYPEER\s*=>\s*true',r'CURLOPT_SSL_VERIFYHOST\s*=>\s*2',r'CURLOPT_RESOLVE',r'CURLOPT_PROTOCOLS\s*=>\s*CURLPROTO_HTTP\s*\|\s*CURLPROTO_HTTPS',r'CURLOPT_REDIR_PROTOCOLS\s*=>\s*CURLPROTO_HTTP\s*\|\s*CURLPROTO_HTTPS'])
require(block('epay_prepare_outbound_curl'),[r'epay_outbound_target\(\$url,\$reason\)',r'if\(\$target===false\) return false;',r'epay_outbound_curl_options\(\$target,\$proxyEnabled\)',r'return \$options!==false && curl_setopt_array\(\$ch,\$options\);'])
for name in ('curl_get','get_curl','check_proxy'):
    b=block(name)
    # A disabled diagnostic must throw; returning false can be reported as success by callers.
    if name=='check_proxy' and re.fullmatch(r'function\s+check_proxy\([^)]*\)\s*\{\s*throw new Exception\([^;]*\);\s*\}\s*',b,re.S): continue
    proxy=r",\s*!empty\(\$conf\['proxy'\]\)" if name=='curl_get' else (r',\s*true' if name=='check_proxy' else '')
    guard=r'if\(!epay_prepare_outbound_curl\(\$ch,\s*\$url'+proxy+r'\)\)\s*\{\s*curl_close\(\$ch\);\s*'+(r'throw new Exception\([^;]*\);' if name=='check_proxy' else r'return false;')+r'\s*\}'
    require(b,[guard,r'curl_exec\(\$ch\)'])
    g=re.search(guard,b,re.S)
    if g.end()>b.index('curl_exec('): raise SystemExit('Outbound guard must precede execution')
    # No setter can undo pinning/proxy rejection/protocol/TLS/redirect restrictions.
    setters=re.findall(r'curl_setopt\(\$ch,\s*(CURLOPT_\w+),\s*([^;]+)\);',b)
    safe={'CURLOPT_SSL_VERIFYPEER':'true','CURLOPT_SSL_VERIFYHOST':'2','CURLOPT_FOLLOWLOCATION':'false','CURLOPT_PROTOCOLS':'CURLPROTO_HTTP|CURLPROTO_HTTPS','CURLOPT_REDIR_PROTOCOLS':'CURLPROTO_HTTP|CURLPROTO_HTTPS'}
    for opt,val in setters:
        if opt in safe and re.sub(r'\s+','',val)!=safe[opt]: raise SystemExit('Unsafe outbound option override')
        if opt in ('CURLOPT_PROXY','CURLOPT_PROXYPORT','CURLOPT_PROXYTYPE','CURLOPT_RESOLVE','CURLOPT_CONNECT_TO'):
            raise SystemExit('Unreviewed outbound routing override')
    if 'curl_setopt_array(' in b: raise SystemExit('Unreviewed outbound option array')
print('Modern outbound security contract verified; functions.php bytes preserved')
PYSSRF
}

write_compose() {
  local mode="${1:-source}"
  write_404_page || return 1
  provision_private_receipts || return 1
  local php_image_block
  if [ "${mode}" = "image" ]; then
    php_image_block="    image: ${CUSTOM_IMAGE}"
  else
    php_image_block="    build:
      context: .build-context
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
      - ./404.html:/etc/nginx/epay-404.html:ro
    networks:
      epay_net:

  php:
${php_image_block}
    container_name: epay-php
    restart: unless-stopped
    environment:
      EPAY_PRIVATE_RECEIPT_DIR: /var/lib/epay-private-receipts
    security_opt:
      - no-new-privileges:true
    depends_on:
      mysql:
        condition: service_healthy
    volumes:
      - ./html:/var/www/html
      - ./private-receipts:/var/lib/epay-private-receipts:rw
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

# 只迁移指定部署 Web 树中的 ZIP；不删除，不扫描旧树/数据库/私有存储。
quarantine_epay_webroot_zips() {
  python3 - "${APP_DIR}" "${HTML_DIR}" "$1" <<'PYZIP'
import os, pathlib, stat, sys, tempfile, datetime
app, current, root = map(lambda s: pathlib.Path(os.path.abspath(s)), sys.argv[1:])
excluded = {'.git', 'security-backups', 'private-receipts', 'private_receipts', 'mysql', 'database', 'backup', 'backups'}
def no_links(p):
 for n in [p] + list(p.parents):
  if n.is_symlink(): raise RuntimeError('ZIP path symlink refused: ' + str(n))
no_links(app); no_links(root)
if current != app/'html' or not (root == current or (root.parent == app and root.name.startswith('html.new.'))):
 raise RuntimeError('ZIP migration requires the current deployment webroot')
if not root.is_dir(): raise RuntimeError('ZIP webroot missing')
files = []
def walk_error(e): raise e
for base, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
 dirs[:] = [n for n in dirs if n not in excluded]
 for name in dirs + names:
  if name in excluded: continue
  p = pathlib.Path(base)/name
  if p.suffix.lower() != '.zip': continue
  mode = p.lstat().st_mode
  if not stat.S_ISREG(mode): raise RuntimeError('ZIP link/special object refused: ' + str(p))
  files.append(p)
# Validate all candidates before creating a backup or moving any file.
if files:
 backup = app/'security-backups'
 no_links(backup)
 backup.mkdir(mode=0o700, exist_ok=True)
 os.chmod(backup, 0o700)
 dest = pathlib.Path(tempfile.mkdtemp(prefix='webroot-zips-'+datetime.datetime.now().strftime('%Y%m%d%H%M%S')+'-', dir=backup))
 os.chmod(dest, 0o700)
 for p in files:
  no_links(p)
  if not stat.S_ISREG(p.lstat().st_mode): raise RuntimeError('ZIP object changed before migration')
  target = dest/p.relative_to(root)
  target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
  for d in [target.parent]+list(target.parent.parents):
   if d == backup: break
   os.chmod(d, 0o700)
  os.rename(p, target)
  os.chmod(target, 0o600)
 print('已将 Web ZIP（含已有上传 ZIP）移出 Web，保留原字节及相对路径：'+str(dest)+'；文件数：'+str(len(files)))
PYZIP
}

seed_html_from_image() (
  local cid new_html old_html ts
  mkdir -p "${APP_DIR}"
  warn "正在从镜像 ${CUSTOM_IMAGE} 提取源码到临时目录..."
  docker pull "${CUSTOM_IMAGE}" || return 1
  new_html="$(mktemp -d "${APP_DIR}/html.new.XXXXXX")" || return 1
  trap 'if [ -n "${cid:-}" ]; then docker rm "$cid" >/dev/null 2>&1 || true; fi; rm -rf "$new_html"' EXIT
  cid="$(docker create "${CUSTOM_IMAGE}" sh -c true)" || return 1
  if ! docker cp "${cid}:/var/www/html/." "${new_html}/"; then
    docker rm "${cid}" >/dev/null 2>&1 || true
    rm -rf "${new_html}"
    error "从镜像提取源码失败，已保留原 ${HTML_DIR}"
    return 1
  fi
  docker rm "${cid}" >/dev/null || return 1

  local old_html_dir="${HTML_DIR}"
  HTML_DIR="${new_html}"
  rm -rf "${HTML_DIR}/.git"
  find "${HTML_DIR}" -path '*/.git' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  repair_epay_source_layout || return 1
  validate_epay_source || return 1
  sanitize_epay_source || return 1
  clean_epay_residue_files || return 1
  verify_epay_security_fixes || return 1
  HTML_DIR="${old_html_dir}"

  quiesce_epay_writers || return 1
  preserve_epay_runtime "${HTML_DIR}" "${new_html}" || return 1
  quarantine_epay_webroot_zips "${new_html}" || return 1

  ts="$(date +%Y%m%d%H%M%S)"
  old_html=""
  if [ -e "${HTML_DIR}" ]; then
    # 原子预留唯一名称；-T 禁止把 html 嵌套移动进已有备份目录。
    old_html="$(mktemp -d "${HTML_DIR}.before_seed_${ts}.XXXXXX")" || return 1
    if ! mv -T "${HTML_DIR}" "${old_html}"; then
      rmdir "${old_html}" 2>/dev/null || true
      return 1
    fi
  fi
  if ! mv -T "${new_html}" "${HTML_DIR}"; then
    if [ -n "${old_html}" ] && [ -d "${old_html}" ]; then
      if ! mv -T "${old_html}" "${HTML_DIR}"; then
        error "新源码切换失败，自动回滚失败；旧源码保留：${old_html}"
      else
        error "新源码切换失败，已恢复旧 html"
      fi
    fi
    return 1
  fi
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
  printf '%s\n' private-receipts private_receipts config.php install/install.lock assets/img assets/uploads upload uploads plugins/sandpay/logs plugins/kuaiqian/temp plugins/douyinpay/cert admin/@login.lock lakala_log.txt
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
    if docker inspect "$c" >/dev/null 2>&1; then docker stop "$c" >/dev/null || return 1; fi
  done
}

provision_private_receipts() {
  python3 - "${APP_DIR}/private-receipts" <<'PRIVATE_RECEIPTS'
import os,pathlib,stat,sys
r=pathlib.Path(sys.argv[1])
# Validate the entire tree before chmod/chown; never follow an archive/runtime link.
for p in [r]+list(r.parents):
 if p.is_symlink(): raise SystemExit('Private receipt path symlink refused')
if not r.exists(): r.mkdir(mode=0o700)
nodes=[r]+list(r.rglob('*'))
for p in nodes:
 mode=p.lstat().st_mode
 if not(stat.S_ISREG(mode) or stat.S_ISDIR(mode)): raise SystemExit('Unsafe private receipt object')
for p in nodes:
 os.chown(p,82,82,follow_symlinks=False)
 os.chmod(p,0o700 if p.is_dir() else 0o600,follow_symlinks=False)
PRIVATE_RECEIPTS
}

fix_permissions() {
  provision_private_receipts || return 1
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

install_app_impl() {
  local mode="${1:-source}"
  require_root
  install_docker || return 1
  ensure_git || return 1
  ensure_python3 || return 1

  local port="$EPAY_INSTALL_PORT"
  mkdir -p "${APP_DIR}"
  if [ "${mode}" = "image" ]; then
    # 镜像模式使用镜像内源码作为宿主机 ./html 的种子；否则 ./html 绑定会覆盖镜像内 /var/www/html。
    seed_html_from_image || return 1
  else
    if [ ! -d "${HTML_DIR}/.git" ]; then
      if [ -e "${HTML_DIR}" ] && [ -n "$(ls -A "${HTML_DIR}" 2>/dev/null || true)" ]; then
        error "${HTML_DIR} 已存在但不是 git 仓库，请先备份/移走后重试。"
        return 1
      fi
      rm -rf "${HTML_DIR}"
      git clone --depth=1 "${REPO_URL}" "${HTML_DIR}" || return 1
    fi
    validate_repo_origin || return 1
    repair_epay_source_layout || return 1
    validate_epay_source || return 1
    sanitize_epay_source || return 1
    clean_epay_residue_files || return 1
    scan_epay_untracked_source_files || return 1
    verify_epay_security_fixes || return 1
    quarantine_epay_webroot_zips "${HTML_DIR}" || return 1
  fi

  write_env "${port}" || return 1
  write_dockerfile || return 1
  write_dockerignore || return 1
  write_nginx_conf || return 1
  write_compose "${mode}" || return 1
  fix_permissions || return 1

  cd "${APP_DIR}"
  local dc
  dc="$(compose_cmd)" || return 1
  if [ "${mode}" = "image" ]; then
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d || return 1
  else
    prepare_epay_clean_build || return 1
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build || return 1
  fi
  write_epay_persistence || return 1
  apply_epay_egress_firewall || return 1

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

update_app_impl() {
  local mode="${1:-source}"
  require_root
  install_docker || return 1
  ensure_git || return 1
  ensure_python3 || return 1
  if [ ! -f "${APP_DIR}/.env" ] || [ ! -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    error "未找到已安装配置，请先执行安装"
    return 1
  fi
  if [ "${mode}" = "image" ]; then
    seed_html_from_image || return 1
    cd "${APP_DIR}"
    write_dockerfile || return 1
    write_dockerignore || return 1
    write_nginx_conf || return 1
    write_compose "${mode}" || return 1
    fix_permissions || return 1
    local dc
    dc="$(compose_cmd)" || return 1
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d || return 1
    write_epay_persistence || return 1
    apply_epay_egress_firewall || return 1
    success "镜像模式更新完成"
    return 0
  fi
  if [ ! -d "${HTML_DIR}/.git" ]; then
    error "未找到 ${HTML_DIR}，请先安装"
    return 1
  fi

  cd "${HTML_DIR}"
  local runtime_backup
  quiesce_epay_writers || return 1
  ensure_epay_backup_dir
  runtime_backup="$(mktemp -d "${APP_DIR}/security-backups/runtime.XXXXXX")"
  preserve_epay_runtime "${HTML_DIR}" "$runtime_backup" || return 1
  validate_repo_origin || return 1
  git fetch --depth=1 origin main || return 1
  git reset --hard origin/main || return 1
  repair_epay_source_layout || return 1
  validate_epay_source || return 1
  sanitize_epay_source || return 1
  clean_epay_residue_files || return 1
  scan_epay_untracked_source_files || return 1
  verify_epay_security_fixes || return 1
  preserve_epay_runtime "$runtime_backup" "${HTML_DIR}" || return 1
  quarantine_epay_webroot_zips "${HTML_DIR}" || return 1

  cd "${APP_DIR}"
  write_dockerfile || return 1
  write_dockerignore || return 1
  write_nginx_conf || return 1
  write_compose "${mode}" || return 1
  fix_permissions || return 1
  local dc
  dc="$(compose_cmd)" || return 1
  prepare_epay_clean_build || return 1
  ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build || return 1
  write_epay_persistence || return 1
  apply_epay_egress_firewall || return 1
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
  return 0
}

start_stack() {
  if [ -f "${APP_DIR}/${COMPOSE_FILE}" ]; then
    install_docker || return 1
    cd "${APP_DIR}"
    local dc
    dc="$(compose_cmd)" || return 1
    if grep -q "context: .build-context" "$COMPOSE_FILE"; then prepare_epay_clean_build || return 1; fi
    ${dc} --env-file .env -f "${COMPOSE_FILE}" up -d --build || return 1
    write_epay_persistence || return 1
    apply_epay_egress_firewall || return 1
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

  warn "备份会包含数据库、.env 密钥、商户/订单和私有回单数据，请妥善保存。"

  if is_stack_running; then
    was_running=1
    warn "检测到容器运行中，先停止服务以保证 MySQL 数据备份一致性..."
    stop_stack || return 1
  fi

  provision_private_receipts || { if [ "${was_running}" -eq 1 ]; then start_stack; fi; return 1; }
  if ! tar --exclude=Epay/.build-context --exclude=Epay/.image-build.* --exclude=Epay/html.before_seed_* -C "$(dirname "${APP_DIR}")" -czf "${archive}" "$(basename "${APP_DIR}")"; then
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

  if ! cp -- "$archive" "$restore_tmp/archive.tar.gz" || ! validate_backup_archive "$restore_tmp/archive.tar.gz"; then
    rm -rf "$restore_tmp"; return 1
  fi
  archive="$restore_tmp/archive.tar.gz"
  if ! tar --exclude=Epay/mysql/mysql.sock --same-owner --same-permissions -C "${restore_tmp}" -xzf "${archive}"; then
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
  local was_running=0
  if is_stack_running; then was_running=1; fi
  stop_stack || { rm -rf "${restore_tmp}"; return 1; }

  if [ -e "${APP_DIR}" ]; then
    mv "${APP_DIR}" "${old_dir}" || { rm -rf "$restore_tmp"; return 1; }
  fi
  if mv "${restore_tmp}/Epay" "${APP_DIR}"; then
    rm -rf "${restore_tmp}"
    if ! start_stack; then
      error "恢复启动失败，回滚到旧目录（失败候选保留）"
      stop_stack || { error "候选仍运行，禁止替换数据目录"; return 1; }
      mv "$APP_DIR" "${APP_DIR}.failed_restore_${ts}" || return 1
      if [ -d "$old_dir" ]; then
        mv "$old_dir" "$APP_DIR" || return 1
        if [ "$was_running" -eq 1 ]; then restart_previous_stack || error "旧栈启动失败，需人工处理"; fi
      fi
      return 1
    fi
    success "恢复完成，已启动服务"
    if [ -d "${old_dir}" ]; then warn "旧目录保留在：${old_dir}"; fi
  else
    error "恢复替换失败，正在回滚..."
    rm -rf "${APP_DIR}" "${restore_tmp}"
    if [ -d "$old_dir" ]; then mv "$old_dir" "$APP_DIR" || return 1; fi
    if [ "$was_running" -eq 1 ]; then restart_previous_stack || return 1; fi
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

# Refuse links/special objects before copying or removing runtime paths.
epay_validate_build_paths() {
  python3 - "$1" <<'PYPATHS' || return 1
import pathlib,stat,os,sys
r=pathlib.Path(os.path.abspath(sys.argv[1]))
for p in [r]+list(r.parents):
    if p.is_symlink(): raise SystemExit('Build path symlink refused')
if not r.is_dir(): raise SystemExit('Build tree missing')
def failed(e): raise e
for base,dirs,files in os.walk(r,followlinks=False,onerror=failed):
    for n in dirs+files:
        mode=(pathlib.Path(base)/n).lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise SystemExit('Build tree link/special object refused')
PYPATHS
}

# Manifest contains EVERY file and directory, not a critical-file presence checklist.
# JSON paths avoid ambiguity from spaces/newlines. No exclusions on the image side.
epay_build_manifest() {
  epay_validate_build_paths "$1" || return 1
  python3 - "$1" "$2" <<'PYMANIFEST' || return 1
import hashlib,json,os,pathlib,stat,sys
r=pathlib.Path(sys.argv[1]); rows={}
def failed(e): raise e
for base,dirs,files in os.walk(r,followlinks=False,onerror=failed):
    for n in dirs+files:
        p=pathlib.Path(base)/n; mode=p.lstat().st_mode
        rel=p.relative_to(r).as_posix()
        if stat.S_ISDIR(mode): rows[rel]={'type':'dir'}
        elif stat.S_ISREG(mode):
            h=hashlib.sha256()
            with p.open('rb') as f:
                for data in iter(lambda:f.read(1024*1024),b''): h.update(data)
            rows[rel]={'type':'file','sha256':h.hexdigest()}
        else: raise SystemExit('Unsafe artifact object')
if 'includes/functions.php' not in rows: raise SystemExit('Missing functions.php in artifact')
with open(sys.argv[2],'x') as f: json.dump(rows,f,sort_keys=True)
PYMANIFEST
}

verify_epay_image_manifest() (
  local image_id="$1" expected="$2" verify_stage cid=''
  verify_stage="$(mktemp -d "$APP_DIR/.image-verify.XXXXXX")" || return 1
  # Never start an application container or attach production volumes/network.
  trap 'if [ -n "$cid" ]; then docker rm "$cid" >/dev/null 2>&1 || true; fi; rm -rf "$verify_stage"' EXIT
  cid="$(docker create --network none --entrypoint /bin/true "$image_id")" || return 1
  docker inspect "$cid" > "$verify_stage/container.json" || return 1
  python3 - "$verify_stage/container.json" "$image_id" <<'PYCONTAINER' || return 1
import json,sys
rows=json.load(open(sys.argv[1]))
if len(rows)!=1: raise SystemExit('Image inspection failed')
c=rows[0]
if c.get('Image')!=sys.argv[2] or c.get('State',{}).get('Status')!='created' or c.get('State',{}).get('Running') is not False:
    raise SystemExit('Unexpected verification container state/image')
if c.get('HostConfig',{}).get('NetworkMode')!='none' or c.get('Mounts')!=[]:
    raise SystemExit('Verification container must have no network/mounts')
PYCONTAINER
  mkdir "$verify_stage/html" || return 1
  docker cp "$cid:/var/www/html/." "$verify_stage/html/" || return 1
  docker rm "$cid" >/dev/null || return 1
  cid=''
  epay_build_manifest "$verify_stage/html" "$verify_stage/actual.json" || return 1
  # Rehash staging too: build hooks or concurrent modifications must not change it.
  epay_build_manifest "$HTML_DIR" "$verify_stage/stage-now.json" || return 1
  python3 - "$expected" "$verify_stage/actual.json" "$verify_stage/stage-now.json" <<'PYCOMPARE' || return 1
import json,sys
expected,actual,current=[json.load(open(p)) for p in sys.argv[1:]]
if current!=expected: raise SystemExit('Clean staging changed during build; refusing push')
missing=set(expected)-set(actual); extra=set(actual)-set(expected)
changed={p for p in expected.keys() & actual.keys() if expected[p]!=actual[p]}
if missing or extra or changed:
    # Do not print runtime values or hashes, even on unexpected image contents.
    raise SystemExit('Image manifest mismatch: missing=%d extra=%d changed=%d; refusing push' % (len(missing),len(extra),len(changed)))
print('Image manifest verified: %d files, %d directories; all paths/SHA-256 match clean staging' % (sum(x['type']=='file' for x in actual.values()),sum(x['type']=='dir' for x in actual.values())))
PYCOMPARE
)

docker_push_app() (
  require_root
  install_docker || return 1
  ensure_python3 || return 1
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
  scan_epay_untracked_source_files || return 1
  local build_stage
  build_stage="$(mktemp -d "${APP_DIR}/.image-build.XXXXXX")"
  trap 'rm -rf "$build_stage"' EXIT
  epay_validate_build_paths "$HTML_DIR" || return 1
  cp -a "${HTML_DIR}" "$build_stage/html" || return 1
  APP_DIR="$build_stage"
  HTML_DIR="$build_stage/html"
  MYSQL_DIR="$build_stage/mysql"
  cd "${APP_DIR}"
  while IFS= read -r rel; do
    # assets/img contains shipped application graphics: preserve defaults.
    [ "$rel" = assets/img ] || rm -rf "${HTML_DIR:?}/$rel"
  done < <(epay_runtime_paths)
  repair_epay_source_layout || return 1
  validate_epay_source || return 1
  rm -rf "${HTML_DIR}/.git"
  find "${HTML_DIR}" -path '*/.git' -type d -prune -exec rm -rf {} + 2>/dev/null || true
  local functions_hash
  functions_hash="$(sha256sum "$HTML_DIR/includes/functions.php")" || return 1
  sanitize_epay_source || return 1
  # Even a future sanitizer must not silently rewrite reviewed outbound code.
  [ "$(sha256sum "$HTML_DIR/includes/functions.php")" = "$functions_hash" ] || return 1
  clean_epay_residue_files || return 1
  scan_epay_untracked_source_files || return 1
  verify_epay_security_fixes || return 1
  prune_epay_build_context || return 1
  scan_epay_sensitive_build_files || return 1
  write_dockerfile || return 1
  write_dockerignore || return 1
  local image_id
  epay_build_manifest "$HTML_DIR" "$build_stage/expected.json" || return 1
  docker build --no-cache --iidfile "$build_stage/image.id" -t "${CUSTOM_IMAGE}" -f Dockerfile . || return 1
  image_id="$(cat "$build_stage/image.id")" || return 1
  [[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1
  verify_epay_image_manifest "$image_id" "$build_stage/expected.json" || return 1
  # Verify immutable content, then assert the publication tag still names that content.
  [ "$(docker image inspect "$CUSTOM_IMAGE" --format '{{.Id}}')" = "$image_id" ] || return 1
  docker push "${CUSTOM_IMAGE}" || return 1
  verify_remote_image_digest "$CUSTOM_IMAGE" || return 1
  success "推送完成且远端 config digest 与本地 image ID 一致：${CUSTOM_IMAGE}"
)

restore_custom_app() {
  local mode="${1:-source}"
  restore_app "$mode"
}


prepare_epay_clean_build() (
  local stage
  stage="$(mktemp -d "$APP_DIR/.clean-build.XXXXXX")" || return 1
  trap 'rm -rf "$stage"' EXIT
  cp -a "$HTML_DIR" "$stage/html" || return 1
  local target="$APP_DIR/.build-context"
  APP_DIR="$stage" HTML_DIR="$stage/html" MYSQL_DIR="$stage/mysql"
  while IFS= read -r rel; do
    [ "$rel" = assets/img ] || rm -rf "$HTML_DIR/$rel" || return 1
  done < <(epay_runtime_paths)
  prune_epay_build_context || return 1
  scan_epay_sensitive_build_files || return 1
  validate_epay_source || return 1
  write_dockerfile || return 1
  write_dockerignore || return 1
  rm -rf "$target" || return 1
  mv "$stage" "$target" || return 1
)

restart_previous_stack() (
  cd "$APP_DIR" || return 1
  local dc
  dc="$(compose_cmd)" || return 1
  ${dc} --env-file .env -f "$COMPOSE_FILE" up -d --no-build --pull never || return 1
)

# Whole-tree snapshot includes MySQL numeric ownership; take only while stopped.
# On rollback never rebuild, fetch, or call financial tasks.
app_transaction() (
  local operation="$1" mode="$2" parent snapshot existed=0 running=0 rc=0
  parent="$(dirname "$APP_DIR")"
  mkdir -p "$parent" || return 1
  snapshot="$(mktemp -d "$parent/.epay-rollback.XXXXXX")" || return 1
  chmod 700 "$snapshot" || return 1
  if is_stack_running; then running=1; fi
  if [ -d "$APP_DIR" ]; then
    existed=1
    stop_stack || { rm -rf "$snapshot"; return 1; }
    cp -a "$APP_DIR" "$snapshot/Epay" || {
      if [ "$running" -eq 1 ]; then restart_previous_stack || true; fi
      rm -rf "$snapshot"; return 1;
    }
  fi
  if "${operation}_app_impl" "$mode"; then
    rm -rf "$snapshot"
    return 0
  else rc=$?; fi
  # Returning failure must not leave a partly replaced stack using new data.
  stop_stack || { error "无法停止失败候选，快照保留：$snapshot"; return 1; }
  if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$snapshot/failed-candidate" || return 1
  fi
  if [ "$existed" -eq 1 ]; then
    mv "$snapshot/Epay" "$APP_DIR" || return 1
    if [ "$running" -eq 1 ]; then restart_previous_stack || error "旧栈恢复启动失败"; fi
  fi
  error "操作失败已回滚；失败候选保留在私有目录 $snapshot"
  return "$rc"
)

install_app() {
  local mode="${1:-source}"
  require_root || return 1
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


  EPAY_INSTALL_PORT="$port" app_transaction install "$mode"
}

update_app() {
  app_transaction update "${1:-source}"
}

prune_epay_build_context() {
  python3 - "$HTML_DIR" <<'PYPRUNE'
import pathlib,shutil,re,sys
r=pathlib.Path(sys.argv[1])
for p in sorted(r.rglob('*'),key=lambda x:len(x.parts),reverse=True):
    rel=p.relative_to(r)
    if p.is_symlink(): raise SystemExit('Build context symlink requires review')
    remove=any(x in ('.git','.svn','.hg','private-receipts','private_receipts','tests','test','fixtures','fixture','__pycache__') for x in rel.parts)
    remove=remove or bool(re.search(r'\.(env|zip|tar|gz|tgz|7z|rar|log|key|bak[^/]*|old[^/]*|orig[^/]*|save[^/]*|swp|phtml|phar|php[0-9]+)$',p.name,re.I))
    remove=remove or (p.suffix.lower()=='.sql' and not(rel.parent==pathlib.Path('install')))
    remove=remove or p.name.startswith(('epay_release','epay_update'))
    if remove:
        if p.is_dir(): shutil.rmtree(p)
        else: p.unlink()
PYPRUNE
}

verify_remote_image_digest() {
  local image="$1" id remote
  id="$(docker image inspect "$image" --format '{{.Id}}')" || return 1
  remote="$(mktemp)" || return 1
  if ! docker manifest inspect --verbose "$image" >"$remote"; then rm -f "$remote"; return 1; fi
  python3 - "$remote" "$id" <<'PYDIGEST'
import json,sys
obj=json.load(open(sys.argv[1])); rows=obj if isinstance(obj,list) else [obj]
def configs(x):
    if isinstance(x,dict):
        if isinstance(x.get('config'),dict) and 'digest' in x['config']: yield x['config']['digest']
        for v in x.values(): yield from configs(v)
    elif isinstance(x,list):
        for v in x: yield from configs(v)
values=set(configs(rows))
if sys.argv[2] not in values: raise SystemExit('Remote config digest mismatch; push NOT verified')
print('Remote immutable config digest matches local image ID')
PYDIGEST
  local rc=$?
  rm -f "$remote"
  return "$rc"
}

ensure_installed_epay_cron() {
  # A downloaded manager/source directory alone is not an installed application.
  [ -f "${APP_DIR}/${COMPOSE_FILE}" ] || return 0
  [ -f "${HTML_DIR}/index.php" ] || return 0
  [ -f "${HTML_DIR}/config.php" ] || return 0
  [ -f "${HTML_DIR}/install/install.lock" ] || return 0
  if [ ! -f "${APP_DIR}/ops/cron-runner.py" ]; then
    warn "检测到 Epay 已安装，但定时任务执行器缺失，请先执行安装/更新修复；未添加无效任务。"
    return 0
  fi
  if ! command -v crontab >/dev/null || [ ! -x /usr/bin/python3 ]; then
    warn "Epay 定时任务检查失败：缺少 crontab 或 /usr/bin/python3，未修改定时任务。"
    return 0
  fi
  update_epay_crontab install || warn "Epay 定时任务补全失败，原有其他任务未主动删除。"
  return 0
}

main_menu() {
  require_root || return 1
  ensure_installed_epay_cron
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
