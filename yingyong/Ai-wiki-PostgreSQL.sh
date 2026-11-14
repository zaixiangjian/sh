#!/usr/bin/env bash
# Ai-wiki PostgreSQL manager. No production actions occur merely by opening menus.
set -uo pipefail
set +x
umask 077
export LC_ALL=C.UTF-8
if [[ ${AIWIKI_TEST_ROOT:-} ]]; then
    [[ $AIWIKI_TEST_ROOT == /root/.hermes/cache/scratch/Ai-wiki-PostgreSQL-test-* && ! -L $AIWIKI_TEST_ROOT ]] || { echo '不安全的测试目录' >&2; exit 1; }
    ROOT=$AIWIKI_TEST_ROOT/project; BACKUPS=$AIWIKI_TEST_ROOT/home/备份/Ai-wiki-PostgreSQL
    CONFIG_BASE=$BACKUPS/config; RESTORE_HOME=$AIWIKI_TEST_ROOT/home; UNIT_DIR=$AIWIKI_TEST_ROOT/units
    PROJECT=ai-wiki-postgresql-test; CONTAINER=Ai-wiki-PostgreSQL-test; NETWORK=ai-wiki-postgresql-test-network
    LOCK=$AIWIKI_TEST_ROOT/operation.lock
else
    ROOT=/home/docker/Ai-wiki-PostgreSQL
    BACKUPS=/home/备份/Ai-wiki-PostgreSQL
    CONFIG_BASE=$BACKUPS/config; RESTORE_HOME=/home; UNIT_DIR=/etc/systemd/system
    PROJECT=ai-wiki-postgresql; CONTAINER=Ai-wiki-PostgreSQL; NETWORK=ai-wiki-postgresql-network
    LOCK=/run/lock/Ai-wiki-PostgreSQL.lock
fi
DEFAULT_VERSION=18-bookworm
BASE_COMMANDS=(python3 tar gzip sha256sum flock realpath du df find timeout mktemp cmp readlink sort cut tail tr grep date dirname chmod chown cp mv rm mkdir rmdir ln sleep)
say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; return 1; }
ask() {
    local label=$1 secret=${2:-0}
    printf '%s (:quit 取消): ' "$label" >&2
    if [[ $secret == 1 ]]; then IFS= read -rs REPLY || return 1; printf '\n' >&2
    else IFS= read -r REPLY || return 1; fi
    [[ $REPLY != :quit && $REPLY != :cancel && $REPLY != 退出配置向导 ]]
}
confirm() { local answer; printf '%s\n请输入 Y或y 继续: ' "$*" >&2; IFS= read -r answer && [[ $answer == Y || $answer == y ]]; }
pause() { local x; printf '按回车继续...' >&2; IFS= read -r x || :; }
valid_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,47}$ && $1 != pg_* ]]; }
valid_project() { valid_name "$1" && [[ ! $1 =~ ^(data|config|logs|secrets|projects|api-runtime|postgres|template0|template1)$ ]]; }
valid_version() { [[ $1 =~ ^(14|15|16|17|18)(\.[0-9]{1,2})?-bookworm$ ]]; }
data_layout() {
    local version=${1:-$PGVERSION}
    if [[ ${version%%[.-]*} == 18 ]]; then
        DATA_MOUNT=/var/lib/postgresql
        DATA_RELATIVE=18/docker
    else
        DATA_MOUNT=/var/lib/postgresql/data
        DATA_RELATIVE=pgdata
    fi
}
qi() { printf '"%s"' "${1//\"/\"\"}"; }
ql() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }
# Fresh-host bootstrap: Debian/Ubuntu with apt. Never install merely to render menus.
install_packages() {
    [[ -z ${AIWIKI_TEST_ROOT:-} ]] || { fail '隔离模式禁止真实软件包安装'; return 1; }
    [[ $EUID == 0 ]] && command -v apt-get >/dev/null || { fail '自动安装需要root和Debian/Ubuntu apt'; return 1; }
    confirm "将从系统软件源安装缺少的组件：$*。是否继续？" || return 1
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" || { fail '依赖安装失败，未继续数据操作'; return 1; }
}
prepare_base_environment() {
    local cmd missing=0
    for cmd in "${BASE_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    if (( missing )); then
        install_packages python3 tar gzip coreutils findutils util-linux diffutils grep ca-certificates || return 1
    fi
    require_tools
}
prepare_work_directory() {
    # Do not require Hermes to have been installed on a replacement server.
    local directory=${TMPDIR:-/root/.cache/ai-wiki-postgresql/tmp}
    [[ $directory == /* ]] || { fail 'TMPDIR必须为绝对路径'; return 1; }
    [[ $(realpath -m "$directory") == "$directory" ]] || { fail '临时目录不能经过符号链接'; return 1; }
    [[ $directory != "$ROOT" && $directory != "$ROOT"/* ]] || { fail '临时目录不能位于数据库项目目录内'; return 1; }
    mkdir -p -- "$directory" || return 1
    [[ -d $directory && -w $directory && ! -L $directory ]] || { fail '临时目录不可写或不安全'; return 1; }
    export TMPDIR=$directory
}
require_tools() {
    local x
    for x in "${BASE_COMMANDS[@]}"; do
        command -v "$x" >/dev/null || { fail "缺少 $x，请先从安装/恢复入口补齐环境"; return 1; }
    done
    prepare_work_directory
}
bootstrap_operation() {
    prepare_base_environment || return 1
    locked "$@"
}
paths_safe() {
    [[ $(realpath -m "$ROOT") == "$ROOT" && $(realpath -m "$BACKUPS") == "$BACKUPS" && $BACKUPS != "$ROOT"/* && $ROOT != "$BACKUPS"/* ]] || { fail '目录边界或符号链接不安全'; return 1; }
    [[ ! -L $ROOT && ! -L $BACKUPS ]] || return 1
}
locked() (
    require_tools && paths_safe || exit 1
    mkdir -p "$(dirname "$LOCK")" || exit 1
    exec 9>"$LOCK" || exit 1
    flock -n 9 || { fail '其他操作进行中'; exit 1; }
    "$@"
)
setup_docker_repository() {
    [[ -z ${AIWIKI_TEST_ROOT:-} ]] || return 1
    local ID='' VERSION_CODENAME='' UBUNTU_CODENAME='' distribution codename architecture
    [[ -r /etc/os-release ]] || return 1
    . /etc/os-release
    case $ID in debian|ubuntu) distribution=$ID;; *) fail 'Docker官方源自动配置仅支持Debian/Ubuntu'; return 1;; esac
    codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
    [[ $codename =~ ^[a-z][a-z0-9-]*$ ]] || return 1
    architecture=$(dpkg --print-architecture) || return 1
    case $architecture in amd64|arm64|armhf|ppc64el|s390x) :;; *) fail '不支持的Docker架构'; return 1;; esac
    confirm "是否配置并使用 https://download.docker.com/linux/$distribution 官方签名源？" || return 1
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl || return 1
    local key=/etc/apt/keyrings/ai-wiki-docker.asc source=/etc/apt/sources.list.d/ai-wiki-docker.sources expected
    expected=$(printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' "$distribution" "$codename" "$architecture" "$key")
    [[ ! -L $key && ! -L $source ]] || { fail 'Docker专用源或密钥不能为链接'; return 1; }
    if [[ -e $source ]]; then
        [[ -f $source && -s $key ]] && cmp -s "$source" <(printf '%s\n' "$expected") || { fail '已存在的Docker专用源不匹配，拒绝覆盖'; return 1; }
    else
        mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d || return 1
        if [[ ! -s $key ]]; then
            [[ ! -e $key ]] || { fail 'Docker密钥文件异常，请管理员检查'; return 1; }
            local temporary_key
            temporary_key=$(mktemp /etc/apt/keyrings/.ai-wiki-docker-XXXXXXXX) || return 1
            if ! curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 "https://download.docker.com/linux/$distribution/gpg" -o "$temporary_key"; then rm -f "$temporary_key"; return 1; fi
            grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$temporary_key" || { rm -f "$temporary_key"; fail '官方签名密钥格式异常'; return 1; }
            chmod 644 "$temporary_key" && mv -T "$temporary_key" "$key" || return 1
        fi
        printf '%s\n' "$expected" > "$source" || return 1
    fi
    chmod 644 "$key" "$source" || return 1
    apt-get update
}
ensure_docker() {
    local installed=0 pkg version candidates
    if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
        [[ -z ${AIWIKI_TEST_ROOT:-} ]] || { fail '隔离模式禁止真实Docker安装'; return 1; }
        command -v apt-get >/dev/null && command -v apt-cache >/dev/null || { fail 'Docker自动安装仅支持Debian/Ubuntu apt'; return 1; }
        confirm '缺少Docker或Compose v2，仅使用Docker官方源，不回退发行版包或第三方镜像源。继续？' || return 1
        setup_docker_repository || return 1
        local -a packages=() package_names=()
        if ! command -v docker >/dev/null; then
            package_names=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
            installed=1
        else
            package_names=(docker-compose-plugin)
        fi
        for pkg in "${package_names[@]}"; do
            candidates=$(apt-cache madison "$pkg") || return 1
            version=$(printf '%s' "$candidates" | python3 -c '
import sys
for line in sys.stdin:
 fields=[x.strip() for x in line.split("|")]
 if len(fields)>=3 and fields[2].startswith("https://download.docker.com/linux/"):
  print(fields[1]);break
') || return 1
            [[ -n $version && $version != *[[:space:]]* ]] || { fail "官方源没有可用的 $pkg，禁止回退其他源"; return 1; }
            packages+=("$pkg=$version")
        done
        # Never allow apt to remove a conflicting existing runtime implicitly.
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove --no-install-recommends "${packages[@]}" || { fail '官方Docker组件安装失败；不回退、不自动卸载冲突组件'; return 1; }
        command -v docker >/dev/null && docker compose version >/dev/null 2>&1 || { fail '安装后Docker/Compose校验失败'; return 1; }
    fi
    if ! docker info >/dev/null 2>&1; then
        command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { fail 'Docker未就绪，当前无可用systemd，请手动启动daemon'; return 1; }
        # Never restart a shared daemon; an existing installation requires explicit start approval.
        if (( ! installed )); then confirm '已有Docker但daemon不可用，是否尝试启动（不会执行restart）？可能启动其自动重启容器。' || return 1; fi
        systemctl start docker || { fail 'Docker启动失败'; return 1; }
        local attempt
        for attempt in {1..15}; do docker info >/dev/null 2>&1 && break; sleep 2; done
    fi
    docker info >/dev/null 2>&1 || { fail 'Docker仍不可用，未继续操作'; return 1; }
}
compose_template() {
    local log_options=''

    local DATA_MOUNT DATA_RELATIVE
    data_layout "${PGVERSION:-$DEFAULT_VERSION}"
    if [[ ${1:-current} != legacy ]]; then
        log_options=', -c, log_filename=postgresql-%H.log, -c, log_rotation_age=1h, -c, log_rotation_size=0, -c, log_truncate_on_rotation=on, -c, log_file_mode=0600'
    fi
    cat <<EOF
name: $PROJECT
services:
  postgres:
    image: postgres:\${POSTGRES_VERSION:?required}
    container_name: $CONTAINER
    restart: unless-stopped
    stop_grace_period: 120s
    environment:
      POSTGRES_USER: \${POSTGRES_USER:?required}
      POSTGRES_DB: \${POSTGRES_DB:?required}
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      POSTGRES_INITDB_ARGS: --auth-host=scram-sha-256
      PGDATA: $DATA_MOUNT/$DATA_RELATIVE
    volumes:
      - ./data:$DATA_MOUNT
      - ./logs:/var/log/postgresql
    secrets:
      - postgres_password
    command: [postgres, -c, logging_collector=on, -c, log_directory=/var/log/postgresql, -c, log_statement=none, -c, log_min_error_statement=panic$log_options]
    healthcheck:
      test: [CMD-SHELL, 'pg_isready -U "\$\$POSTGRES_USER" -d "\$\$POSTGRES_DB"']
      interval: 5s
      timeout: 5s
      retries: 30
    networks: [postgres]

    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: '3'
secrets:
  postgres_password:
    file: ./config/postgres-password
networks:
  postgres:
    name: $NETWORK
EOF
}
compose_is_managed() {
    cmp -s "$ROOT/compose.yaml" <(compose_template) || cmp -s "$ROOT/compose.yaml" <(compose_template legacy) || cmp -s "$ROOT/compose.yaml" <(compose_template unpublished) || cmp -s "$ROOT/compose.yaml" <(compose_template legacy | grep -v '^$') || cmp -s "$ROOT/compose.yaml" <(compose_template unpublished | grep -v '^$')
}
write_current_compose() {
    # Only explicit install/update/restore transitions apply new runtime settings.
    compose_is_managed || { fail 'Compose不是已认可模板，拒绝覆盖'; return 1; }
    local temporary
    temporary=$(mktemp "$ROOT/.compose-XXXXXXXX") || return 1
    if compose_template > "$temporary" && chmod 600 "$temporary" && mv -T -- "$temporary" "$ROOT/compose.yaml"; then return 0; fi
    rm -f -- "$temporary"; return 1
}
load_env() {
    [[ -f $ROOT/.env && ! -L $ROOT/.env ]] || { fail '尚未安装或 .env 不安全'; return 1; }
    local key value
    PGUSER= PGDB= PGVERSION= PG_BIND= PG_PORT=5432
    while IFS='=' read -r key value; do
        case $key in POSTGRES_USER) PGUSER=$value;; POSTGRES_DB) PGDB=$value;; POSTGRES_VERSION) PGVERSION=$value;; PG_BIND) PG_BIND=$value;; PG_PORT) PG_PORT=$value;; ''|'#'*) :;; *) fail '环境文件包含非托管字段'; return 1;; esac
    done < "$ROOT/.env"
    valid_name "$PGUSER" && valid_name "$PGDB" && valid_version "$PGVERSION" || { fail '环境变量不合法'; return 1; }
    [[ -z $PG_BIND || $PG_BIND == 127.0.0.1 || $PG_BIND == 0.0.0.0 ]] && [[ $PG_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( PG_PORT<=65535 )) || { fail '数据库端口配置不合法'; return 1; }
}
write_env() { printf 'POSTGRES_USER=%s\nPOSTGRES_DB=%s\nPOSTGRES_VERSION=%s\nPG_BIND=%s\nPG_PORT=%s\n' "$PGUSER" "$PGDB" "$PGVERSION" "${PG_BIND:-}" "${PG_PORT:-5432}" > "$ROOT/.env"; }
managed() {
    paths_safe && load_env || return 1
    [[ -f $ROOT/config/manager.json && ! -L $ROOT/config && ! -L $ROOT/data && ! -L $ROOT/logs && ! -L $ROOT/compose.yaml ]] || { fail '项目标记或目录异常'; return 1; }
    compose_is_managed || { fail 'Compose 不符合本脚本安全模板，拒绝操作'; return 1; }
    if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
        local label mount DATA_MOUNT DATA_RELATIVE
        data_layout
        label=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER") || return 1
        mount=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$DATA_MOUNT\"}}{{.Source}}{{end}}{{end}}" "$CONTAINER") || return 1
        [[ $label == "$PROJECT" && $mount == "$ROOT/data" ]] || { fail '同名容器不属于本项目'; return 1; }
    fi
    if docker network inspect "$NETWORK" >/dev/null 2>&1; then
        [[ $(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$NETWORK") == "$PROJECT" ]] || { fail '同名网络不属于本项目'; return 1; }
    fi
}
dc() { docker compose --project-directory "$ROOT" --env-file "$ROOT/.env" -f "$ROOT/compose.yaml" -p "$PROJECT" "$@"; }
running() { [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null) == true ]]; }
sql() { docker exec -i "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$PGUSER" -d "${1:-$PGDB}" -At; }
catalog_exists() {
    local kind=$1 name=$2 result query
    case $kind in
        database) query=$(printf 'SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=%s);\n' "$(ql "$name")");;
        user) query=$(printf 'SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=%s);\n' "$(ql "$name")");;
        *) return 2;;
    esac
    result=$(printf '%s\n' "$query" | sql) || return 2
    case $result in t) return 0;; f) return 1;; *) return 2;; esac
}
healthy() {
    local i
    for i in {1..60}; do
        if running && [[ $(printf 'SELECT 1;\n' | sql 2>/dev/null) == 1 ]]; then return 0; fi
        sleep 2
    done
    fail '数据库连接未通过检查（不会输出可能含秘密的日志）'
}
install_pg() {
    ensure_docker && paths_safe || return 1
    if [[ -e $ROOT ]]; then
        [[ -d $ROOT && -z $(find "$ROOT" -mindepth 1 -print -quit) ]] || { fail '安装目录已有内容，不覆盖；请使用更新或恢复'; return 1; }
    fi
    docker container inspect "$CONTAINER" >/dev/null 2>&1 && { fail '同名容器已存在'; return 1; }
    docker network inspect "$NETWORK" >/dev/null 2>&1 && { fail '同名网络已存在'; return 1; }
    ask '管理员用户名 [aiwiki_admin]' || return 1; PGUSER=${REPLY:-aiwiki_admin}; valid_name "$PGUSER" || { fail '用户名不合法'; return 1; }
    ask '初始数据库名 [aiwiki]' || return 1; PGDB=${REPLY:-aiwiki}; valid_name "$PGDB" || { fail '数据库名不合法'; return 1; }
    ask "PostgreSQL 版本 [$DEFAULT_VERSION]，明确固定主版本" || return 1; PGVERSION=${REPLY:-$DEFAULT_VERSION}; valid_version "$PGVERSION" || { fail '版本格式应为18-bookworm或18.x-bookworm（兼容14至17原有布局）'; return 1; }
    ask '管理员密码（至少12字符，不回显）' 1 || return 1; local password=$REPLY; REPLY=; [[ ${#password} -ge 12 ]] || { fail '密码过短'; return 1; }
    api_prompt_binding || return 1
    local api_bind=$API_BIND_INPUT

    docker pull "postgres:$PGVERSION" || return 1
    mkdir -p "$ROOT"/{config,data,logs} || return 1
    chmod 700 "$ROOT" "$ROOT/config" "$ROOT/data" || return 1
    printf '%s' "$password" > "$ROOT/config/postgres-password" || return 1; unset password
    write_env && compose_template > "$ROOT/compose.yaml" || return 1
    printf '{"format":1,"projects":{}}\n' > "$ROOT/config/manager.json" || return 1
    api_engine set-bind "$api_bind" || return 1
    # Use image's postgres UID/GID (not host assumptions); bind log dir must be writable.
    local uid gid
    uid=$(docker run --rm --network none --entrypoint id "postgres:$PGVERSION" -u postgres) || return 1
    gid=$(docker run --rm --network none --entrypoint id "postgres:$PGVERSION" -g postgres) || return 1
    chown "$uid:$gid" "$ROOT/logs" "$ROOT/data" || return 1
    chmod 700 "$ROOT/logs"
    dc up -d && healthy || { fail '安装未就绪，保留全部文件供检查；不会覆盖重装'; return 1; }
    say '安装成功；PostgreSQL 5432不发布到宿主机，仅API独立映射。'
    say 'PostgreSQL日志：按小时轮转，24个命名槽循环覆盖；不是严格容量上限，不自动删除旧版日志。'
}
update_pg() {
    ensure_docker && managed || return 1
    local current target oldversion oldimage oldbind oldport oldcompose
    current=$(printf 'SHOW server_version;\n' | sql) || return 1
    say "当前数据库版本：$current；配置镜像：postgres:$PGVERSION"
    ask "目标版本 [$PGVERSION]" || return 1; target=${REPLY:-$PGVERSION}
    if ! valid_version "$target"; then fail '目标版本不支持（仅14至18-bookworm）；跨主版本升级必须另行迁移，禁止直接执行'; return 1; fi
    [[ ${target%%[.-]*} == "${current%%.*}" && ${target%%[.-]*} == "${PGVERSION%%[.-]*}" ]] || { fail '主版本升级禁止直接执行；需另行 pg_upgrade / 导出导入方案'; return 1; }
    api_prompt_binding || return 1
    local api_bind=$API_BIND_INPUT

    say '更新前建议完整冷备份。'
    if confirm '现在生成完整备份？（非Y/y跳过）'; then
        backup_pg || { fail '更新前备份失败，已中止更新'; return 1; }
    fi
    confirm '确认已有可用备份并更新同一主版本镜像？' || return 1
    oldversion=$PGVERSION; oldimage=$(docker inspect -f '{{.Image}}' "$CONTAINER") || return 1
    oldbind=$PG_BIND; oldport=$PG_PORT; oldcompose=$(< "$ROOT/compose.yaml")
    docker pull "postgres:$target" || return 1
    # Validate server version of pulled image before touching the running service.
    local actual
    actual=$(docker run --rm --network none --entrypoint postgres "postgres:$target" --version) || return 1
    [[ $actual == "postgres (PostgreSQL) ${current%%.*}."* ]] || { fail '目标镜像主版本不匹配'; return 1; }
    write_current_compose || return 1
    PG_BIND=; PG_PORT=5432; PGVERSION=$target
    write_env && compose_template > "$ROOT/compose.yaml" || return 1
    if dc up -d --force-recreate postgres && healthy; then
        api_engine set-bind "$api_bind" && api_apply || { fail '数据库已更新，但API绑定应用失败'; return 1; }
        say '更新成功，数据/权限/配置保留。'; return 0
    fi
    fail '更新失败，尝试恢复原镜像；不保证回退已发生的数据格式变更'
    docker tag "$oldimage" "postgres:$oldversion" || return 1
    PGVERSION=$oldversion; PG_BIND=$oldbind; PG_PORT=$oldport
    write_env && printf '%s\n' "$oldcompose" > "$ROOT/compose.yaml" && dc up -d --force-recreate postgres && healthy
}
# Archive metadata/checksum helper: never sources configuration or executes archive content.
archive_tool() {
python3 - "$@" <<'PY'
import sys,tarfile,hashlib,json,pathlib,stat
mode=sys.argv[1]; base=pathlib.Path(sys.argv[2])
def digest(f):
 h=hashlib.sha256()
 for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
def inspect_archive():
 records={}; normalized=set()
 with tarfile.open(base/'project.tar.gz','r:gz') as t:
  for m in t:
   p=pathlib.PurePosixPath(m.name)
   if p.is_absolute() or '..' in p.parts or (not m.isfile() and not m.isdir()) or m.name in records: raise ValueError('unsafe/duplicate archive member: '+m.name)
   if str(p) in normalized:raise ValueError('duplicate normalized archive path: '+m.name)
   normalized.add(str(p))
   if m.mode & 0o6000: raise ValueError('setuid/setgid forbidden')
   records[m.name]={'sha256':digest(t.extractfile(m)) if m.isfile() else None,'size':m.size,'mode':m.mode,'uid':m.uid,'gid':m.gid}
 return records
if mode=='make':
 records=inspect_archive()
 with open(base/'project.tar.gz','rb') as f: sha=digest(f)
 data={'format':1,'created':sys.argv[3],'version':sys.argv[4],'archive_sha256':sha,'files':records}
 (base/'manifest.json').write_text(json.dumps(data,ensure_ascii=False,sort_keys=True))
 (base/'SHA256SUMS').write_text(sha+'  project.tar.gz\n'+hashlib.sha256((base/'manifest.json').read_bytes()).hexdigest()+'  manifest.json\n')
elif mode=='verify':
 if base.is_symlink() or any((base/n).is_symlink() for n in ['project.tar.gz','manifest.json','SHA256SUMS']): raise ValueError('symlink backup')
 lines=(base/'SHA256SUMS').read_text().splitlines()
 if len(lines)!=2: raise ValueError('checksum format')
 for line,name in zip(lines,['project.tar.gz','manifest.json']):
  sha,sep,target=line.partition('  ')
  if sep!='  ' or target!=name: raise ValueError('checksum target')
  with open(base/name,'rb') as f:
   if digest(f)!=sha: raise ValueError('checksum mismatch '+name)
 data=json.loads((base/'manifest.json').read_text())
 if data['format']!=1 or inspect_archive()!=data['files']: raise ValueError('archive manifest mismatch')
 required=['./.env','./compose.yaml','./config/manager.json','./config/postgres-password']
 if any(n not in data['files'] for n in required): raise ValueError('not a full PostgreSQL project backup')
 with tarfile.open(base/'project.tar.gz') as t:
  env=t.extractfile('./.env').read().decode()
  version=next(x.split('=',1)[1] for x in env.splitlines() if x.startswith('POSTGRES_VERSION='))
  configured_major=version.split('-')[0].split('.')[0]
  pg_version_path='./data/18/docker/PG_VERSION' if configured_major=='18' else './data/pgdata/PG_VERSION'
  if pg_version_path not in data['files']:raise ValueError('missing PG_VERSION for configured data layout')
  major=t.extractfile(pg_version_path).read().decode().strip()
  if configured_major!=major or version!=data['version']: raise ValueError('PG_VERSION mismatch')
 print(data['created']+' postgres:'+data['version'])
elif mode=='tree':
 data=json.loads((base/'manifest.json').read_text()); root=pathlib.Path(sys.argv[3])
 for name,rec in data['files'].items():
  p=root/name
  st=p.lstat()
  if stat.S_IMODE(st.st_mode)!=rec['mode'] or st.st_uid!=rec['uid'] or st.st_gid!=rec['gid']: raise ValueError('metadata mismatch '+name)
  if rec['sha256'] is not None:
   if not stat.S_ISREG(st.st_mode): raise ValueError('not regular')
   with open(p,'rb') as f:
    if digest(f)!=rec['sha256']: raise ValueError('file mismatch '+name)
else: raise ValueError('unknown mode')
PY
}
backup_pg() (
    ensure_docker && managed || exit 1
    api_container_owned || exit 1
    local DATA_MOUNT DATA_RELATIVE
    data_layout
    [[ -f $ROOT/data/$DATA_RELATIVE/PG_VERSION ]] || { fail '没有初始化数据库或数据布局不匹配'; exit 1; }
    # Full physical backup cannot safely include arbitrary symlinks / external tablespaces.
    local unsupported
    unsupported=$(find "$ROOT" ! -type f ! -type d -print -quit) || { fail '备份目录遍历失败'; exit 1; }
    [[ -z $unsupported ]] || { fail '存在符号链接、外部表空间或特殊文件，为防漏备份拒绝打包'; exit 1; }
    mkdir -p "$BACKUPS" || exit 1
    local need avail was=0 api_was=0 work='' partial='' published=''
    need=$(du -sb "$ROOT" | cut -f1); avail=$(df -PB1 "$BACKUPS" | tail -1 | tr -s ' ' | cut -d' ' -f4)
    [[ $need =~ ^[0-9]+$ && $avail =~ ^[0-9]+$ ]] && (( avail > need + need/5 + 67108864 )) || { fail '备份磁盘空间不足'; exit 1; }
    running && was=1
    cleanup_backup() {
        local rc=$?
        trap - EXIT INT TERM HUP
        if (( was )); then
            if ! docker start "$CONTAINER" >/dev/null || ! healthy; then fail '无法恢复备份前运行状态，请立即检查'; rc=1; fi
        fi
        if (( api_was )); then
            docker start "$CONTAINER-API" >/dev/null || { fail '备份后API未能重新启动'; rc=1; }
        fi
        [[ -z $work || ! -d $work ]] || rm -rf -- "$work"
        [[ -z $partial ]] || rm -f -- "$partial"
        if (( rc == 0 )) && [[ -n ${AIWIKI_RESULT_FILE:-} && -n $published ]]; then printf '%s\n' "$published" > "$AIWIKI_RESULT_FILE" || rc=1; fi
        exit "$rc"
    }
    trap cleanup_backup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM HUP
    if api_running; then
        api_was=1
        docker stop -t 60 "$CONTAINER-API" >/dev/null || exit 1
        api_running && { fail 'API未停止，拒绝冷备份'; exit 1; }
        [[ $(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER-API") == 0 ]] || { fail 'API未正常排空请求，拒绝备份'; exit 1; }
    fi
    if (( was )); then docker stop -t 120 "$CONTAINER" >/dev/null || exit 1; fi
    running && { fail '容器未停止'; exit 1; }
    [[ $(docker inspect -f '{{.State.Status}}' "$CONTAINER") == exited ]] || { fail '容器状态不是 exited'; exit 1; }
    [[ $(docker inspect -f '{{.State.ExitCode}}|{{.State.OOMKilled}}' "$CONTAINER") == '0|false' ]] || { fail '容器不是正常退出（可能超时强杀或OOM），拒绝生成冷备份'; exit 1; }
    local control image
    image=$(docker inspect -f '{{.Image}}' "$CONTAINER") || exit 1
    control=$(docker run --rm --network none --read-only --user postgres -e LC_ALL=C --mount "type=bind,src=$ROOT/data,dst=/backup,readonly" --entrypoint pg_controldata "$image" "/backup/$DATA_RELATIVE" 2>/dev/null) || { fail '无法读取数据库控制状态，拒绝备份'; exit 1; }
    printf '%s\n' "$control" | grep -Eq '^Database cluster state:[[:space:]]+shut down[[:space:]]*$' || { fail '数据库未完成正常关闭/checkpoint，拒绝备份'; exit 1; }
    work=$(mktemp -d "$BACKUPS/.partial-XXXXXXXX") || exit 1
    say '冷备份：数据库已停止；外部编辑器/博客文件写入者必须由用户提前暂停。'
    tar --acls --xattrs --numeric-owner -czpf "$work/project.tar.gz" -C "$ROOT" . || exit 1
    archive_tool make "$work" "$(date -u +%FT%TZ)" "$PGVERSION" && archive_tool verify "$work" || exit 1
    local dest attempt reserved=0
    for attempt in {1..60}; do
        dest="$BACKUPS/Ai-wiki-$(date +%Y-%m-%d-%H%M%S).tar.gz"
        if [[ ! -e $dest && ! -L $dest && ! -e $dest.partial && ! -L $dest.partial ]]; then
            if ( set -o noclobber; : > "$dest.partial" ) 2>/dev/null; then partial="$dest.partial"; reserved=1; break; fi
            fail '备份文件创建失败，可能空间不足或权限异常'; exit 1
        fi
        sleep 1
    done
    (( reserved )) || { fail '备份文件名持续冲突，已取消，不覆盖历史文件'; exit 1; }
    tar -czf "$partial" -C "$work" project.tar.gz manifest.json SHA256SUMS || exit 1
    bundle_verify "$partial" || exit 1
    python3 - "$partial" "$dest" <<'PY_PUBLISH'
import os,sys
with open(sys.argv[1],'rb') as f:os.fsync(f.fileno())
os.link(sys.argv[1],sys.argv[2]);os.unlink(sys.argv[1])
fd=os.open(os.path.dirname(sys.argv[2]),os.O_RDONLY);os.fsync(fd);os.close(fd)
PY_PUBLISH
    [[ $? == 0 ]] || exit 1
    partial=''; published=$dest
    say "完整备份已验证：$dest（包含数据库凭据，请加密存储与限制访问）"

)
list_backups() {
    python3 - "$RESTORE_HOME" "$BACKUPS" <<'PY_FILES'
import sys,pathlib,re,datetime
files=[]
for root in dict.fromkeys(sys.argv[1:]):
 p=pathlib.Path(root)
 if p.is_dir():
  for f in p.glob('Ai-wiki-*.tar.gz'):
   if f.is_symlink() or not f.is_file():continue
   m=re.fullmatch(r'Ai-wiki-(\d{4}-\d{2}-\d{2}-\d{6})\.tar\.gz',f.name)
   if not m:continue
   try: datetime.datetime.strptime(m[1],'%Y-%m-%d-%H%M%S')
   except ValueError:continue
   files.append(f)
for f in sorted(set(files),key=lambda p:(p.name,p.stat().st_mtime_ns),reverse=True):print(f)
PY_FILES
}
bundle_unpack() {
    python3 - "$1" "$2" <<'PY_BUNDLE'
import sys,pathlib,tarfile,shutil,gzip
p=pathlib.Path(sys.argv[1]);dest=pathlib.Path(sys.argv[2]); expected={'project.tar.gz','manifest.json','SHA256SUMS'}
if p.is_symlink() or not p.is_file():raise ValueError('unsafe archive path')
with gzip.open(p,'rb') as stream:
 while stream.read(1024*1024):pass
with tarfile.open(p,'r:gz') as t:
 members=t.getmembers()
 if len(members)!=3 or {m.name for m in members}!=expected or any(not m.isfile() for m in members):raise ValueError('invalid full-project bundle')
 for m in members:
  with t.extractfile(m) as f, (dest/m.name).open('xb') as w:shutil.copyfileobj(f,w,1024*1024)
PY_BUNDLE
}
bundle_verify() (
    require_tools || exit 1
    local tmp; tmp=$(mktemp -d "${TMPDIR:-/root/.cache/ai-wiki-postgresql/tmp}/aiwiki-check-XXXXXXXX") || exit 1
    trap 'rm -rf -- "$tmp"' EXIT
    bundle_unpack "$1" "$tmp" && archive_tool verify "$tmp"
)
latest_valid() {
    local n
    while IFS= read -r n; do
        [[ -n $n ]] || continue
        if bundle_verify "$n" >/dev/null 2>&1; then printf '%s\n' "$n"; return 0; fi
        say "跳过无效备份：${n##*/}" >&2
    done < <(list_backups)
    fail '没有有效完整备份'
}
restore_pg() (
    paths_safe && ensure_docker || exit 1
    local b stage bundle='' old='' was=0 swapped=0 had=0 completed=0 service_touched=0 api_was=0 api_touched=0
    api_container_owned || exit 1
    api_running && api_was=1
    choose_backup || exit 1
    local selected=$SELECTED
    bundle_verify "$selected" || exit 1
    bundle=$(mktemp -d "${TMPDIR:-/root/.cache/ai-wiki-postgresql/tmp}/aiwiki-restore-bundle-XXXXXXXX") || exit 1
    trap 'rm -rf -- "$bundle"' EXIT
    bundle_unpack "$selected" "$bundle" || exit 1
    b=$bundle
    say "即将用 $selected 覆盖整个 $ROOT，包含数据库、凭据及所有博客文件。原始备份不会删除。"
    local answer
    printf '恢复将替换全项目并暂停数据库，输入小写 y 确认（其他输入取消）: ' >&2
    IFS= read -r answer && [[ $answer == y ]] || exit 1
    if [[ -e $ROOT ]]; then managed || exit 1; had=1; running && was=1
    else
        docker container inspect "$CONTAINER" >/dev/null 2>&1 && { fail '存在同名容器'; exit 1; }
        docker network inspect "$NETWORK" >/dev/null 2>&1 && { fail '存在同名网络'; exit 1; }
    fi
    mkdir -p "$(dirname "$ROOT")" || exit 1
    local need avail
    need=$(python3 -c 'import json,sys; print(sum(x["size"] for x in json.load(open(sys.argv[1]))["files"].values()))' "$b/manifest.json") || exit 1
    avail=$(df -PB1 "$(dirname "$ROOT")" | tail -1 | tr -s ' ' | cut -d' ' -f4)
    (( avail > need + 67108864 )) || { fail '恢复暂存空间不足'; exit 1; }
    stage=$(mktemp -d "$(dirname "$ROOT")/.aiwiki-restore-XXXXXXXX") || exit 1
    restore_exit() {
        local rc=$?; trap - EXIT INT TERM HUP
        if (( ! completed )); then
            if (( swapped )); then
                api_remove_runtime || { fail '恢复失败且API无法停止，保留回滚目录'; exit 1; }
                docker stop -t 120 "$CONTAINER" >/dev/null 2>&1 || :
                if running; then fail "恢复失败且新容器无法停止，保留回滚目录 $old"; exit 1; fi
                docker rm "$CONTAINER" >/dev/null 2>&1 || :
                local failed; failed=$(mktemp -d "$(dirname "$ROOT")/.aiwiki-failed-XXXXXXXX")
                if [[ -n $failed ]] && mv -T "$ROOT" "$failed"; then
                    if [[ -n $old ]] && mv -T "$old" "$ROOT"; then old=''; else fail "原目录未能自动复位：$old"; fi
                    say "失败恢复目录保留供检查：$failed" >&2
                else fail "无法移走失败目录；原始数据保留在 $old"; fi
            fi
            if (( had && service_touched )) && [[ -z $old ]]; then
                if load_env; then dc up -d && { (( was )) || docker stop -t 120 "$CONTAINER" >/dev/null; } || fail '原服务重建失败'; fi
            fi
            if (( api_touched && api_was )) && [[ -z $old && -d $ROOT ]]; then api_apply || fail '原API恢复失败'; fi
        fi
        [[ ! -d $stage ]] || rm -rf -- "$stage"
        [[ ! -d $bundle ]] || rm -rf -- "$bundle"
        exit "$rc"
    }
    trap restore_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
    tar --acls --xattrs --numeric-owner -xzpf "$b/project.tar.gz" -C "$stage" || exit 1
    archive_tool tree "$b" "$stage" || exit 1
    # Validate restored configuration BEFORE stopping or replacing anything.
    local saved=$ROOT; ROOT=$stage
    load_env && compose_is_managed || { ROOT=$saved; fail '恢复配置与当前资源名称/模板不兼容'; exit 1; }
    ROOT=$saved
    docker pull "postgres:$PGVERSION" || exit 1
    api_touched=1
    api_remove_runtime || exit 1
    if (( had )); then
        service_touched=1
        docker stop -t 120 "$CONTAINER" >/dev/null 2>&1 || { docker container inspect "$CONTAINER" >/dev/null 2>&1 && exit 1; }
        running && exit 1
        old=$(mktemp -d "$(dirname "$ROOT")/.aiwiki-before-XXXXXXXX") || exit 1
        mv -T "$ROOT" "$old" || { rmdir "$old"; old=''; exit 1; }
    fi
    if ! mv -T "$stage" "$ROOT"; then
        [[ -z $old ]] || { mv -T "$old" "$ROOT" && old=''; }
        exit 1
    fi
    swapped=1
    managed && write_current_compose && dc up -d --force-recreate && healthy && api_apply || exit 1
    completed=1
    [[ -z $old ]] || rm -rf -- "$old"
    say '恢复成功：全目录文件校验、容器和数据库连接检查通过；原始备份保留。'
)
# Small JSON association index, containing no database passwords.
registry() {
python3 - "$ROOT" "$@" <<'PY'
import sys,json,pathlib,os,re
root=pathlib.Path(sys.argv[1]); mode=sys.argv[2]; path=root/'config/manager.json'
data=json.loads(path.read_text()); projects=data['projects']; args=sys.argv[3:]
for name,entry in projects.items():
 if not re.fullmatch(r'[a-z][a-z0-9_-]{0,47}',name) or name in ('data','logs','config','secrets','projects') or name.startswith('pg_'): raise ValueError('unsafe project index')
 if not isinstance(entry,dict) or not isinstance(entry.get('users'),list): raise ValueError('invalid project entry')
 if not isinstance(entry.get('database'),str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,47}',entry['database']):raise ValueError('invalid project database')
 if any(not isinstance(u,str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,47}',u) or u.startswith('pg_') for u in entry['users']):raise ValueError('invalid project user')
if mode=='list':
 for p,v in sorted(projects.items()): print(p+' database='+v['database']+' users='+','.join(v['users']))
elif mode=='get': print(json.dumps(projects.get(args[0]),ensure_ascii=False))
elif mode=='add':
 p,db,user=args
 if p in projects: raise ValueError('project already registered')
 projects[p]={'database':db,'users':[user]}
elif mode=='attach-user':
 db,user=args
 for entry in projects.values():
  if entry['database']==db and user not in entry['users']:entry['users'].append(user)
elif mode=='remove':
 if args[0] not in projects: raise ValueError('unknown project')
 del projects[args[0]]
elif mode=='drop-user':
 for p,v in list(projects.items()):
  if args[0] not in v['users']: continue
  v['users'].remove(args[0]); folder=root/p
  if not v['users']:
   # Remove only a tree composed entirely of empty directories, never symlinks/files.
   safe=folder.is_dir() and not folder.is_symlink()
   if safe:
    def traversal_error(error):raise error
    for base,dirs,files in os.walk(folder,followlinks=False,onerror=traversal_error):
     if files or any((pathlib.Path(base)/d).is_symlink() for d in dirs): safe=False; break
   if safe:
    for base,dirs,files in os.walk(folder,topdown=False,onerror=traversal_error): os.rmdir(base)
   else: print('保留包含实际文件或异常链接的项目目录：'+p)
   # Removing a login role is not deleting the project: retain DB mapping and empty user list.
else: raise ValueError('unknown registry action')
if mode in ('add','remove','drop-user','attach-user'):
 tmp=path.with_suffix('.tmp'); tmp.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n'); tmp.chmod(0o600); tmp.replace(path)
PY
}
exists_db() { catalog_exists database "$1"; }
exists_user() { catalog_exists user "$1"; }
# Select from one immutable list; never interpret user input as a name or expression.
select_numbered() {
    local prompt=$1 selected index
    shift
    local -a entries=("$@")
    SELECTED_NAME=
    ((${#entries[@]})) || { say '暂无可选项'; return 1; }
    for index in "${!entries[@]}"; do printf '%s. %s\n' "$((index+1))" "${entries[$index]}"; done
    printf '%s' "$prompt" >&2
    IFS= read -r selected || return 1
    [[ -n $selected ]] || { say '已取消'; return 1; }
    [[ $selected =~ ^[1-9][0-9]{0,5}$ ]] && (( selected <= ${#entries[@]} )) || { fail '无效序号'; return 1; }
    SELECTED_NAME=${entries[$((selected-1))]}
}
select_database_item() {
    local kind=$1 prompt=${2:-请输入序号选择（回车默认取消）：} result query
    local -a entries=()
    case $kind in
        user) query='SELECT rolname FROM pg_roles WHERE rolcanlogin ORDER BY 1;' ;;
        database) query='SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1;' ;;
        *) fail '无效选择类型'; return 1;;
    esac
    result=$(printf '%s\n' "$query" | sql) || { fail '列表读取失败'; return 1; }
    [[ -z $result ]] || mapfile -t entries <<< "$result"
    select_numbered "$prompt" "${entries[@]}"
}
user_create() {
    select_database_item database '输入要添加用户的数据库序号（回车默认取消）：' || return 1
    local db=$SELECTED_NAME user pass
    valid_name "$db" && exists_db "$db" || return 1
    say "目标数据库：$db"
    ask '新数据库用户名' || return 1; user=$REPLY; valid_name "$user" || return 1
    local lookup_rc=0
    exists_user "$user" || lookup_rc=$?
    case $lookup_rc in 0) fail '用户名已存在，不会覆盖或复用'; return 1;; 1) :;; *) fail '用户名冲突检查失败'; return 1;; esac
    ask '用户密码（至少12字符）' 1 || return 1; pass=$REPLY; REPLY=; [[ ${#pass} -ge 12 ]] || return 1
    # Create and grant in one database transaction: failure leaves no partial role/grants.
    if ! {
        printf 'BEGIN; CREATE ROLE %s LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %s;\n' "$(qi "$user")" "$(ql "$pass")"
        printf 'GRANT CONNECT,TEMPORARY ON DATABASE %s TO %s; GRANT USAGE,CREATE ON SCHEMA public TO %s;\n' "$(qi "$db")" "$(qi "$user")" "$(qi "$user")"
        printf 'GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO %s; GRANT USAGE,SELECT,UPDATE ON ALL SEQUENCES IN SCHEMA public TO %s; COMMIT;\n' "$(qi "$user")" "$(qi "$user")"
    } | sql "$db" >/dev/null 2>&1; then
        unset pass; fail '创建用户或授权失败，数据库事务已回滚'; return 1
    fi
    unset pass
    if ! registry attach-user "$db" "$user"; then
        fail "用户 $user 已创建并授权，但项目关联保存失败，请勿误认为用户创建失败而重复执行"; return 1
    fi
    say "用户 $user 已添加到数据库 $db：可连接、创建临时表和public对象、读写现有public表及序列；不是超级管理员或数据库所有者。"
    say '其他用户将来创建的表不会自动共享；需要时由对象创建者显式授权。'
}
select_user_in_database() {
    local db=$1 result query
    local -a entries=()
    # Effective CONNECT includes PUBLIC/inherited access; this is not an ownership assertion.
    query=$(printf "SELECT r.rolname FROM pg_roles r JOIN pg_database d ON d.datname=%s WHERE r.rolcanlogin AND has_database_privilege(r.oid,d.oid,'CONNECT') ORDER BY r.rolname;\n" "$(ql "$db")")
    result=$(printf '%s\n' "$query" | sql) || { fail '数据库用户列表读取失败'; return 1; }
    [[ -z $result ]] || mapfile -t entries <<< "$result"
    say "数据库：$db（列出有有效连接权限的用户，含PUBLIC/继承授权）"
    select_numbered '请输入序号选择（回车默认取消）：' "${entries[@]}"
}
user_delete() {
    select_database_item database '输入要删除用户的数据库序号（回车默认取消）：' || return 1
    local db=$SELECTED_NAME
    select_user_in_database "$db" || return 1
    local user=$SELECTED_NAME super deps
    valid_name "$user" && [[ $user != "$PGUSER" && $user != postgres ]] || { fail '不能删除管理账户'; return 1; }
    super=$(printf 'SELECT rolsuper FROM pg_roles WHERE rolname=%s;\n' "$(ql "$user")" | sql) || return 1
    [[ $super == f ]] || { fail '账户不存在或是超级用户'; return 1; }
    deps=$(printf 'SELECT count(*) FROM pg_shdepend WHERE refclassid=\x27pg_authid\x27::regclass AND refobjid=(SELECT oid FROM pg_roles WHERE rolname=%s);\n' "$(ql "$user")" | sql) || return 1
    [[ $deps == 0 ]] || { fail '用户仍拥有对象或 ACL 权限；请显式转移所有权/撤销权限后重试。不会 DROP OWNED/CASCADE，也不会删数据库。'; return 1; }
    confirm "已选择数据库 $db；即将删除实例级用户 $user（不只是解除本库关联）。确认该用户不再用于任何项目？数据库和实际文件保留。" || return 1
    printf 'DROP ROLE %s;\n' "$(qi "$user")" | sql && registry drop-user "$user"
}
password_change() {
    select_database_item user '请输入需要修改密码的序号 (回车默认取消): ' || return 1
    local user=$SELECTED_NAME; valid_name "$user" && exists_user "$user" || return 1
    ask '新密码（至少12字符）' 1 || return 1; local pass=$REPLY; REPLY=; [[ ${#pass} -ge 12 ]] || return 1
    if ! printf 'ALTER ROLE %s PASSWORD %s;\n' "$(qi "$user")" "$(ql "$pass")" | sql >/dev/null 2>&1; then fail '密码修改失败'; return 1; fi
    if [[ $user == "$PGUSER" ]]; then
        [[ -f $ROOT/config/postgres-password && ! -L $ROOT/config/postgres-password ]] || { unset pass; fail '数据库密码已改，但密码文件异常，未覆盖'; return 1; }
        printf '%s' "$pass" > "$ROOT/config/postgres-password" && chmod 600 "$ROOT/config/postgres-password" || { unset pass; fail '数据库密码已改，但本地密码文件同步失败'; return 1; }
    fi
    unset pass; say '密码已更新（未输出）'
}
permissions() {
    local user=${1:-} db action owner
    if [[ -z $user ]]; then
        say '选择数据库用户'
        select_database_item user || return 1
        user=$SELECTED_NAME
    fi
    valid_name "$user" && exists_user "$user" || return 1
    say '选择数据库'
    select_database_item database || return 1
    db=$SELECTED_NAME; valid_name "$db" && exists_db "$db" || return 1
    select_numbered '请输入序号选择（回车默认取消）：' '查看权限' '分配数据库权限（读写）' '修改为只读' '撤销直接授权' || return 1
    case $SELECTED_NAME in
        查看权限) action=1;;
        '分配数据库权限（读写）') action=2;;
        修改为只读) action=3;;
        撤销直接授权) action=4;;
    esac
    case $action in
        1) printf "SELECT datname,datacl FROM pg_database WHERE datname=%s;\nSELECT rolname,rolsuper,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname=%s;\nSELECT has_database_privilege(%s,%s,'CONNECT');\n\\dp\n\\ddp\n" "$(ql "$db")" "$(ql "$user")" "$(ql "$user")" "$(ql "$db")" | sql "$db";;
        2|3|4)
            [[ $user != "$PGUSER" ]] || { fail '不修改管理账户权限'; return 1; }
            owner=$(printf 'SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=%s;\n' "$(ql "$db")" | sql) || return 1
            if [[ $action == 3 || $action == 4 ]] && [[ $owner == "$user" ]]; then
                fail '数据库所有者仍拥有固有权限，不能用撤销授权将其变成只读；请先显式转移所有权'; return 1
            fi
            confirm '仅调整目标用户的直接授权；所有权、PUBLIC、继承角色及其他对象创建者的默认权限可能另有授权，不会自动剥夺。继续？' || return 1
            {
                printf 'BEGIN; REVOKE ALL ON DATABASE %s FROM %s;\nREVOKE ALL ON SCHEMA public FROM %s;\nREVOKE ALL ON ALL TABLES IN SCHEMA public FROM %s;\nREVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %s;\nALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM %s;\nALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM %s;\n' "$(qi "$db")" "$(qi "$user")" "$(qi "$user")" "$(qi "$user")" "$(qi "$user")" "$(qi "$user")" "$(qi "$user")"
                if [[ $action != 4 ]]; then
                    printf 'GRANT CONNECT ON DATABASE %s TO %s; GRANT USAGE ON SCHEMA public TO %s;\n' "$(qi "$db")" "$(qi "$user")" "$(qi "$user")"
                    if [[ $action == 2 ]]; then
                        printf 'GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO %s; GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO %s; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT,INSERT,UPDATE,DELETE ON TABLES TO %s; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE,SELECT ON SEQUENCES TO %s;\n' "$(qi "$user")" "$(qi "$user")" "$(qi "$user")" "$(qi "$user")"
                    else printf 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO %s; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO %s;\n' "$(qi "$user")" "$(qi "$user")"; fi
                fi
                printf 'COMMIT;\n'
            } | sql "$db";;
        *) fail '无效选项';;
    esac
}
view_db() {
    say '请选择需要查看的数据库'
    select_database_item database || return 1
    local db=$SELECTED_NAME result
    # Identifiers come from a numbered database snapshot; quote SQL literals independently.
    result=$(
        {
            printf "SELECT json_build_object('database',d.datname,'owner',pg_get_userbyid(d.datdba),'size',pg_size_pretty(pg_database_size(d.oid)),'version',current_setting('server_version'),'users',COALESCE((SELECT json_agg(row_to_json(u)) FROM (SELECT r.rolname AS username,r.rolsuper AS superuser,pg_get_userbyid(d.datdba)=r.rolname AS owner,has_database_privilege(r.oid,d.oid,'CONNECT') AS connect,has_database_privilege(r.oid,d.oid,'CREATE') AS create_database_objects,has_database_privilege(r.oid,d.oid,'TEMP') AS temporary,has_schema_privilege(r.oid,'public','USAGE') AS schema_usage,has_schema_privilege(r.oid,'public','CREATE') AS schema_create FROM pg_roles r WHERE r.rolcanlogin AND (r.rolsuper OR d.datdba=r.oid OR has_database_privilege(r.oid,d.oid,'CONNECT')) ORDER BY r.rolname) u),'[]'::json)) FROM pg_database d WHERE d.datname=%s;\n" "$(ql "$db")"
        } | sql "$db"
    ) || { fail '数据库信息读取失败'; return 1; }
    printf '%s' "$result" | python3 -c '
import json,sys,unicodedata
info=json.load(sys.stdin)
def clean(value):return "".join(c if c.isprintable() else "?" for c in str(value))
def width(value):return sum(2 if unicodedata.east_asian_width(c) in ("W","F") else 1 for c in value)
print("==================================")
print("数据库名称："+clean(info["database"]))
print("数据库所有者："+clean(info["owner"]))
print("数据库大小："+clean(info["size"]))
print("PostgreSQL版本："+clean(info["version"]))
print("可登录用户及权限（包含PUBLIC/继承授予的有效连接权限）")
users=info["users"]
if not users:print("暂无")
else:
 names=[str(i)+". "+clean(u["username"]) for i,u in enumerate(users,1)]
 column=max(20,max(width(name) for name in names)+2)
 print("用户名"+" "*14+"身份 / 权限")
 for name,u in zip(names,users):
  role="超级管理员" if u["superuser"] else "数据库所有者" if u["owner"] else "普通用户"
  labels=[label for key,label in (("connect","连接"),("create_database_objects","库内创建"),("temporary","临时表"),("schema_usage","public使用"),("schema_create","public创建")) if u[key]]
  print(name+" "*(column-width(name))+role+" / "+("、".join(labels) or "无"))
print("说明：连接权限不等于表读写权限；表及序列授权请在6号权限管理中查看。")
print("==================================")
' || { fail '数据库信息解析失败'; return 1; }
}
blog_create() (
    ask '自定义项目名称（字母开头，小写字母/数字/-/_，最多48字符）' || exit 1
    local name=$REPLY user db pass made_user=0 made_db=0 made_dir=0 done=0
    valid_project "$name" || { fail '项目名称不合法或保留'; exit 1; }
    db=$name
    ask '自定义项目专用数据库用户名（字母开头，小写字母/数字/-/_，最多48字符）' || exit 1
    user=$REPLY
    valid_name "$user" || { fail '数据库用户名不合法'; exit 1; }
    [[ ! -e $ROOT/$name && ! -L $ROOT/$name && $(registry get "$name") == null ]] || { fail '项目或目录已存在'; exit 1; }
    local lookup_rc=0
    exists_db "$db" || lookup_rc=$?
    case $lookup_rc in 0) fail '同名数据库存在'; exit 1;; 1) :;; *) fail '数据库冲突检查失败'; exit 1;; esac
    lookup_rc=0
    exists_user "$user" || lookup_rc=$?
    case $lookup_rc in 0) fail '同名用户存在'; exit 1;; 1) :;; *) fail '用户名冲突检查失败'; exit 1;; esac
    ask '项目数据库用户密码（至少12字符）' 1 || exit 1; pass=$REPLY; REPLY=; [[ ${#pass} -ge 12 ]] || exit 1
    blog_exit() {
        local rc=$?; trap - EXIT INT TERM HUP
        if (( ! done )); then
            (( ! made_db )) || printf 'DROP DATABASE %s;\n' "$(qi "$db")" | sql >/dev/null 2>&1 || fail "回滚数据库失败：$db"
            (( ! made_user )) || printf 'DROP ROLE %s;\n' "$(qi "$user")" | sql >/dev/null 2>&1 || fail "回滚用户失败：$user"
            if (( made_dir )); then find "$ROOT/$name" -depth -type d -empty -delete; fi
        fi
        exit "$rc"
    }
    trap blog_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
    if ! printf 'CREATE ROLE %s LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %s;\n' "$(qi "$user")" "$(ql "$pass")" | sql >/dev/null 2>&1; then fail '创建项目用户失败'; exit 1; fi
    made_user=1; unset pass
    printf 'CREATE DATABASE %s OWNER %s;\n' "$(qi "$db")" "$(qi "$user")" | sql || { fail '创建项目数据库失败'; exit 1; }; made_db=1
    printf 'REVOKE ALL ON DATABASE %s FROM PUBLIC; GRANT ALL PRIVILEGES ON DATABASE %s TO %s;\n' "$(qi "$db")" "$(qi "$db")" "$(qi "$user")" | sql || exit 1
    # Explicit ownership avoids relying on version-specific template defaults.
    # This user manages its own database, not the PostgreSQL instance.
    printf 'REVOKE ALL ON SCHEMA public FROM PUBLIC; ALTER SCHEMA public OWNER TO %s; GRANT ALL PRIVILEGES ON SCHEMA public TO %s;\n' "$(qi "$user")" "$(qi "$user")" | sql "$db" || exit 1
    mkdir "$ROOT/$name" || exit 1; made_dir=1
    mkdir "$ROOT/$name"/{articles,research,tasks,records,attachments} || exit 1
    registry add "$name" "$db" "$user" || exit 1
    done=1; say "创建成功：项目 $name；数据库 $db；用户 $user（本数据库及public所有者）；目录 $ROOT/$name；具有本库管理权限，无实例超级用户权限。"
    say '注意：该用户可删除自己的数据库；删除用户前须显式转移其数据库和对象所有权，脚本不会自动删库。'
)
blog_delete() {
    local listing name entry catalog records
    local -a projects=()
    catalog=$(printf "SELECT COALESCE(json_agg(datname ORDER BY datname),'[]'::json) FROM pg_database WHERE NOT datistemplate AND datname<>'postgres';\n" | sql) || { fail '实际数据库列表读取失败'; return 1; }
    records=$(printf '%s' "$catalog" | python3 -c '
import json,sys,re
projects=json.load(open(sys.argv[1]))["projects"]
databases=json.load(sys.stdin)
records=[]; covered=set()
for name,entry in sorted(projects.items()):
 if not re.fullmatch(r"[a-z][a-z0-9_-]{0,47}",name):raise ValueError("invalid project name")
 records.append({"name":name,"entry":entry,"label":entry["database"]+"（项目："+name+"）"});covered.add(entry["database"])
for db in databases:
 if db not in covered and db!=sys.argv[2]:
  records.append({"name":db,"entry":{"database":db,"users":[],"unregistered":True},"label":db+"（无项目索引，仅删除数据库）"})
print(json.dumps(records,ensure_ascii=False))
' "$ROOT/config/manager.json" "$PGDB") || { fail '项目/数据库列表解析失败'; return 1; }
    listing=$(printf '%s' "$records" | python3 -c 'import json,sys;print("\n".join(x["label"] for x in json.load(sys.stdin)))') || return 1
    [[ -n $listing ]] || { say '暂无可删除的业务数据库或博客项目（管理库受保护）'; return 0; }
    mapfile -t projects <<< "$listing"
    select_numbered '请输入序号选择（回车默认取消）：' "${projects[@]}" || return 1
    local selected_record
    selected_record=$(printf '%s' "$records" | python3 -c 'import json,sys;print(json.dumps(next(x for x in json.load(sys.stdin) if x["label"]==sys.argv[1]),ensure_ascii=False))' "$SELECTED_NAME") || return 1
    name=$(printf '%s' "$selected_record" | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])') || return 1
    valid_project "$name" || { fail '项目名称不安全'; return 1; }
    entry=$(printf '%s' "$selected_record" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["entry"],ensure_ascii=False))') || return 1
    printf '%s' "$entry" | python3 -c '
import json,sys
entry=json.load(sys.stdin)
def clean(s):return "".join(c if c.isprintable() else "?" for c in str(s))
print("项目名称："+sys.argv[1])
print("数据库名称："+clean(entry["database"]))
print("关联用户："+(", ".join(clean(x) for x in entry["users"]) or "无"))
print("文件目录："+("无可靠关联，不删除任何目录" if entry.get("unregistered") else sys.argv[2]+"/"+sys.argv[1]))
' "$name" "$ROOT" || return 1
    delete_blog_resources "$name" "$entry"
}
delete_blog_resources() {
    local name=$1 entry=$2 db user status answer statements='' owner_check unregistered
    unregistered=$(printf '%s' "$entry" | python3 -c 'import json,sys;print("yes" if json.load(sys.stdin).get("unregistered") else "no")') || return 1
    local -a users=()
    valid_project "$name" || { fail '项目名称不安全'; return 1; }
    db=$(printf '%s' "$entry" | python3 -c 'import json,sys;print(json.load(sys.stdin)["database"])') || return 1
    valid_name "$db" && [[ $db != "$PGDB" && $db != postgres && $db != template0 && $db != template1 ]] || { fail '拒绝处理管理库或系统库'; return 1; }
    if api_engine db-active "$db"; then fail '该库仍有API，请先在8号删除对应API配置'; return 1; fi
    python3 - "$ROOT/config/manager.json" "$name" "$db" <<'PY_SHARED_DB'
import json,sys
projects=json.load(open(sys.argv[1]))['projects']
if any(p!=sys.argv[2] and v['database']==sys.argv[3] for p,v in projects.items()):sys.exit('数据库还关联其他项目，拒绝删除')
PY_SHARED_DB
    [[ $? == 0 ]] || return 1
    local user_lines
    user_lines=$(printf '%s' "$entry" | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin)["users"]))') || return 1
    [[ -z $user_lines ]] || mapfile -t users <<< "$user_lines"
    paths_safe && [[ ! -L $ROOT/$name ]] && [[ $(realpath -m "$ROOT/$name") == "$ROOT/$name" ]] || { fail '项目目录路径不安全'; return 1; }
    # The registry, not PUBLIC CONNECT access, defines users belonging to this project.
    for user in "${users[@]}"; do
        valid_name "$user" && [[ $user != "$PGUSER" && $user != postgres ]] || { fail '关联用户包含管理账户或非法名称'; return 1; }
        python3 - "$ROOT/config/manager.json" "$name" "$user" <<'PY_SHARED_USER'
import json,sys
projects=json.load(open(sys.argv[1]))['projects']
if any(p!=sys.argv[2] and sys.argv[3] in v['users'] for p,v in projects.items()):sys.exit('用户还关联其他项目，拒绝删除')
PY_SHARED_USER
        [[ $? == 0 ]] || return 1
        status=$(printf 'SELECT rolsuper FROM pg_roles WHERE rolname=%s;\n' "$(ql "$user")" | sql) || return 1
        [[ -n $status ]] || continue
        [[ $status == f ]] || { fail '拒绝删除超级管理员'; return 1; }
        owner_check=$(printf "SELECT count(*) FROM pg_shdepend WHERE refclassid='pg_authid'::regclass AND refobjid=(SELECT oid FROM pg_roles WHERE rolname=%s) AND dbid<>(SELECT oid FROM pg_database WHERE datname=%s) AND NOT (dbid=0 AND classid='pg_database'::regclass AND objid=(SELECT oid FROM pg_database WHERE datname=%s));\n" "$(ql "$user")" "$(ql "$db")" "$(ql "$db")" | sql) || return 1
        [[ $owner_check == 0 ]] || { fail "用户 $user 存在其他数据库或实例级依赖，拒绝删除"; return 1; }
        statements+=$(printf 'DROP ROLE IF EXISTS %s;\n' "$(qi "$user")")
    done
    if [[ $unregistered == yes ]]; then
        say "危险操作：永久删除无索引数据库 $db 及其中全部数据；不删除任何角色或本地目录。"
    else
        say "危险操作：永久删除数据库 $db 及其中全部数据、整个目录 $ROOT/$name（含文章和附件），以及上方列出的全部项目关联用户。"
    fi
    say '此操作不可恢复；有活跃数据库连接时拒绝删库，不强制断开连接，不处理其他项目。建议先完成完整备份。'
    printf '确认删除请输入 yes（其他输入取消）: ' >&2
    IFS= read -r answer && [[ $answer == yes ]] || { say '已取消删除'; return 1; }
    # DROP DATABASE cannot run in a transaction. Keep files/index until all SQL succeeds.
    # IF EXISTS permits retry after a partial failure without recreating a removed database.
    if ! printf 'DROP DATABASE IF EXISTS %s;\n' "$(qi "$db")" | sql; then
        fail '数据库删除失败，未删除用户、目录或项目索引'; return 1
    fi
    if [[ $unregistered == yes ]]; then
        say "遗留数据库 $db 已删除；未删除任何角色或本地目录。"
        return 0
    fi
    if ! printf 'BEGIN;\n%s\nCOMMIT;\n' "$statements" | sql; then
        fail '数据库已删除，但用户删除失败；用户事务已回滚，目录和项目索引保留供重试。数据库无法自动回滚，请使用备份恢复。'; return 1
    fi
    if [[ -e $ROOT/$name || -L $ROOT/$name ]]; then
        paths_safe && [[ -d $ROOT/$name && ! -L $ROOT/$name && $(realpath -m "$ROOT/$name") == "$ROOT/$name" ]] || { fail '数据库及用户已删除，但目录路径异常，未清理文件或索引'; return 1; }
        rm -rf -- "$ROOT/$name" || { fail '数据库及用户已删除，但目录清理失败；索引保留供重试'; return 1; }
    fi
    registry remove "$name" || { fail '数据库、用户及目录已删除，但项目索引清理失败'; return 1; }
    say "项目 $name 的数据库 $db、全部关联用户和本地文件夹已删除。"
}
db_action() { ensure_docker && managed && healthy || return 1; "$@"; }
show_database_summary() (
    say '检测数据库PostgreSQL'
    [[ ${1:-submenu} == homepage ]] || say '=================================='
    say '数据库名       用户数       API数据'
    if ! command -v docker >/dev/null 2>&1; then
        say '未安装'; return 0
    fi
    local state rows
    if ! timeout 5 docker info >/dev/null 2>&1; then
        say '检测失败（Docker不可用）'; return 0
    fi
    if ! state=$(timeout 5 docker inspect --type container -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null); then
        local names
        if names=$(timeout 5 docker container ls -a --format '{{.Names}}' 2>/dev/null) && ! printf '%s\n' "$names" | grep -Fxq -- "$CONTAINER"; then
            say '未安装'
        else
            say '检测失败（无法读取容器状态）'
        fi
        return 0
    fi
    if [[ $state != running ]]; then
        case $state in exited|created) say '数据库已停止';; *) say '检测失败（容器状态异常）';; esac
        return 0
    fi
    # Only query this manager's own container; never start services or load passwords.
    if ! managed >/dev/null 2>&1; then
        say '检测失败（项目配置或容器归属异常）'; return 0
    fi
    # Count every LOGIN role with effective CONNECT, including the administrator.
    # Read full catalog names without abbreviation; include maintenance and template DBs.
    if ! rows=$(timeout 8 docker exec -i -e 'PGOPTIONS=-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=2000' "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$PGUSER" -d "$PGDB" -At 2>/dev/null <<'SQL_SUMMARY'
SELECT COALESCE(json_agg(row_to_json(summary)), '[]'::json)
FROM (
    SELECT d.datname AS database_name,
           (SELECT count(*) FROM pg_roles r
            WHERE r.rolcanlogin
              AND has_database_privilege(r.oid, d.oid, 'CONNECT')) AS user_count
    FROM pg_database d
    ORDER BY d.datname
) summary;
SQL_SUMMARY
    ); then
        say '检测失败（数据库连接或查询异常）'; return 0
    fi
    local api_counts
    api_counts=$(api_engine counts) || api_counts='null'
    printf '%s' "$rows" | python3 -c '
import json,sys,unicodedata,os
rows=json.load(sys.stdin)
counts=json.loads(sys.argv[1])
color=sys.stdout.isatty() and os.environ.get("TERM","dumb")!="dumb"
def paint(text,code):return "\033["+str(code)+"m"+text+"\033[0m" if color else text
def clean(value):return "".join(c if c.isprintable() else "?" for c in str(value))
def width(value):return sum(2 if unicodedata.east_asian_width(c) in ("W","F") else 1 for c in value)
if not rows:print("暂无")
else:
 names=[str(index)+". "+clean(row["database_name"]) for index,row in enumerate(rows,1)]
 column=max(15,max(width(name) for name in names)+2)
 for name,row in zip(names,rows):
  count=counts.get(row["database_name"],0) if counts is not None else None
  label=paint("检测失败",31) if count is None else paint(str(count),32) if count else paint("无",31)
  print(name+" "*(column-width(name))+str(row["user_count"]).ljust(12)+label)
' "$api_counts" || say '检测失败（数据库结果解析异常）'
)
api_prompt_binding() {
    ask 'API绑定地址 [127.0.0.1]（仅允许127.0.0.1或0.0.0.0；与数据库绑定独立）' || return 1
    API_BIND_INPUT=${REPLY:-127.0.0.1}
    [[ $API_BIND_INPUT == 127.0.0.1 || $API_BIND_INPUT == 0.0.0.0 ]] || { fail '绑定地址不合法'; return 1; }
    if [[ $API_BIND_INPUT == 0.0.0.0 ]]; then
        confirm '警告：API端口将监听所有IPv4接口，可能被公网直接访问并绕过Nginx HTTPS。请自行限制来源，确认继续？' || return 1
    fi
}
api_engine() {
    python3 - "$ROOT" "$@" 3<&0 <<'PY_API_CONFIG'
import sys,json,pathlib,re,hashlib,secrets,os,getpass
root=pathlib.Path(sys.argv[1]);mode=sys.argv[2];path=root/'config/apis.json'
def load():
 if path.is_symlink():raise ValueError('API配置不能是链接')
 return json.loads(path.read_text()) if path.exists() else {'version':1,'port':5501,'bind':'127.0.0.1','apis':{}}
def save(d):
 tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(d,ensure_ascii=False,indent=2));tmp.chmod(0o600);tmp.replace(path)
sys.stdin=os.fdopen(3)
def ask(label,secret=False):
 print(label+'（回车取消）: ',end='',file=sys.stderr,flush=True)
 v=getpass.getpass('',stream=sys.stderr) if secret and sys.stdin.isatty() else sys.stdin.readline().rstrip('\n')
 if not v or v in (':quit',':cancel'):raise EOFError()
 if any(c in v for c in ('\r','\0')):raise ValueError('输入包含非法字符')
 return v
try:
 d=load()
 if mode=='list':
  import unicodedata
  def clean(v):return ''.join(c if c.isprintable() else '?' for c in str(v))
  def width(v):return sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in v)
  rows=[['序号','API名称','数据库名','数据库用户','绑定地址']]
  for i,(n,a) in enumerate(sorted(d['apis'].items()),1):
   rows.append([str(i),clean(n),clean(a['database']),clean(a['user']),clean(d.get('bind','127.0.0.1'))+':'+str(d['port'])])
  widths=[max(width(row[i]) for row in rows)+3 for i in range(5)]
  print('API配置明细（配置存在不代表服务已就绪）')
  for row in rows:print(''.join(v+' '*(widths[i]-width(v)) for i,v in enumerate(row)).rstrip())
  if not d['apis']:print('暂无API配置，请选择1添加。')
  for n in sorted(d['apis']):
   print('API '+clean(n)+' 路径：/v1/'+clean(n)+'/records/<记录ID>；/v1/'+clean(n)+'/files/<子目录>/<文件名>')
 elif mode=='names':
  for n in sorted(d['apis']):print(n)
 elif mode=='counts':print(json.dumps({db:sum(a['database']==db for a in d['apis'].values()) for db in {a['database'] for a in d['apis'].values()}}))
 elif mode=='active':sys.exit(0 if d['apis'] else 1)
 elif mode=='port':print(d['port'])
 elif mode=='bind':print(d.get('bind','127.0.0.1'))
 elif mode=='set-bind':
  if sys.argv[3] not in ('127.0.0.1','0.0.0.0'):raise ValueError('invalid bind address')
  d['bind']=sys.argv[3];save(d)
 elif mode in ('add','edit'):
  db,user,project=sys.argv[3:6]
  name=ask('API名称（小写字母开头，字母数字_-，最多32字符）') if mode=='add' else sys.argv[6]
  if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}',name):raise ValueError('API名称不合法')
  if mode=='add' and name in d['apis']:raise ValueError('API名称重复')
  if mode=='edit':
   old=d['apis'][name];db,user,project=old['database'],old['user'],old['project']
  password=ask('该数据库用户的实际密码（隐藏）',True)
  token=ask('API访问密钥（至少32字符，隐藏）',True)
  if len(token)<32:raise ValueError('访问密钥至少32字符')
  d['apis'][name]={'database':db,'user':user,'password':password,'project':project,'token_hash':hashlib.sha256(token.encode()).hexdigest()}
  save(d);print('API配置已保存，密钥不回显。')
 elif mode=='delete':del d['apis'][sys.argv[3]];save(d)

 elif mode=='db-active':sys.exit(0 if any(a['database']==sys.argv[3] for a in d['apis'].values()) else 1)
 else:raise ValueError('未知API操作')
except EOFError:sys.exit('已取消')
except Exception as e:
 print('API配置失败：'+(str(e) if isinstance(e,ValueError) else type(e).__name__),file=sys.stderr);sys.exit(2)
PY_API_CONFIG
}
api_service_source() {
    cat <<'PY_API_SERVICE'
import os,json,pathlib,hashlib,hmac,threading,urllib.parse,re
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import psycopg
from psycopg.types.json import Jsonb
CONFIG='/run/config/apis.json'
BUCKETS={'articles','research','tasks','records','attachments'}
LIMIT=8*1024*1024
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def reply(self,status,value):
  body=json.dumps(value,ensure_ascii=False).encode();self.send_response(status);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(body)
 def handle_api(self):
  try:
   parts=urllib.parse.urlsplit(self.path)
   if parts.path=='/health' and self.command=='GET':self.reply(200,{'status':'ok'});return
   route=parts.path.strip('/').split('/')
   if len(route)<4 or route[0]!='v1':self.reply(404,{'error':'not found'});return
   name,kind=route[1:3]
   config=json.load(open(CONFIG));a=config['apis'].get(name)
   auth=self.headers.get('Authorization','')
   if not a or not auth.startswith('Bearer ') or not hmac.compare_digest(hashlib.sha256(auth[7:].encode()).hexdigest(),a['token_hash']):self.reply(401,{'error':'unauthorized'});return
   length=int(self.headers.get('Content-Length','0'))
   if self.headers.get('Transfer-Encoding') or not 0<=length<=LIMIT:self.reply(413,{'error':'request too large or unsupported encoding'});return
   # Each call reloads configuration, so deleted API names/rotated tokens stop authenticating immediately.
   if kind=='records' and len(route)==4:
    key=urllib.parse.unquote(route[3])
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',key):raise ValueError('invalid record id')
    with psycopg.connect(host=os.environ['PGHOST'],dbname=a['database'],user=a['user'],password=a['password'],connect_timeout=5,options='-c statement_timeout=10000 -c lock_timeout=3000') as conn:
     with conn.cursor() as cur:
      if self.command=='GET':
       cur.execute('SELECT payload FROM public.aiwiki_api_records WHERE api_name=%s AND record_id=%s',(name,key));row=cur.fetchone();self.reply(200 if row else 404,{'data':row[0] if row else None})
      elif self.command=='PUT':
       payload=json.loads(self.rfile.read(length));cur.execute('INSERT INTO public.aiwiki_api_records(api_name,record_id,payload) VALUES(%s,%s,%s) ON CONFLICT(api_name,record_id) DO UPDATE SET payload=excluded.payload',(name,key,Jsonb(payload)));conn.commit();self.reply(200,{'saved':True})
      elif self.command=='DELETE':cur.execute('DELETE FROM public.aiwiki_api_records WHERE api_name=%s AND record_id=%s',(name,key));conn.commit();self.reply(200,{'deleted':True})
      else:self.reply(405,{'error':'method not allowed'})
   elif kind=='files' and len(route)==5:
    bucket,filename=route[3],urllib.parse.unquote(route[4])
    if bucket not in BUCKETS or not re.fullmatch(r'[A-Za-z0-9_\-][A-Za-z0-9_.\-]{0,199}',filename) or filename in ('.','..'):raise ValueError('invalid file path')
    project=a['project']
    if not project or not re.fullmatch(r'[a-z][a-z0-9_-]{0,47}',project):self.reply(403,{'error':'database has no registered project directory'});return
    # openat with O_NOFOLLOW at each step prevents symlink escape; no arbitrary host paths.
    rootfd=os.open('/projects',os.O_RDONLY|os.O_DIRECTORY)
    try:
     pfd=os.open(project,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=rootfd)
     try:bfd=os.open(bucket,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=pfd)
     finally:os.close(pfd)
    finally:os.close(rootfd)
    try:
     if self.command=='GET':
      fd=os.open(filename,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=bfd)
      with os.fdopen(fd,'rb') as f:body=f.read(LIMIT+1)
      if len(body)>LIMIT:self.reply(413,{'error':'file too large'});return
      self.send_response(200);self.send_header('Content-Type','application/octet-stream');self.send_header('Content-Length',str(len(body)));self.send_header('X-Content-Type-Options','nosniff');self.end_headers();self.wfile.write(body)
     elif self.command=='PUT':
      import secrets
      tmp='.upload-'+secrets.token_hex(16)
      try:
       fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=bfd)
       with os.fdopen(fd,'wb') as f:
        data=self.rfile.read(length)
        if len(data)!=length:raise ValueError('incomplete request')
        f.write(data);f.flush();os.fsync(f.fileno())
       os.rename(tmp,filename,src_dir_fd=bfd,dst_dir_fd=bfd);os.fsync(bfd)
      finally:
       try:os.unlink(tmp,dir_fd=bfd)
       except FileNotFoundError:pass
      self.reply(200,{'saved':True})
     elif self.command=='DELETE':os.unlink(filename,dir_fd=bfd);self.reply(200,{'deleted':True})
     else:self.reply(405,{'error':'method not allowed'})
    finally:os.close(bfd)
   else:self.reply(404,{'error':'not found'})
  except FileNotFoundError:self.reply(404,{'error':'not found'})
  except (ValueError,json.JSONDecodeError):self.reply(400,{'error':'invalid input'})
  except Exception:self.reply(503,{'error':'operation failed'})
 def setup(self):super().setup();self.connection.settimeout(20)
 do_GET=handle_api
 do_PUT=handle_api
 do_DELETE=handle_api
class Server(ThreadingHTTPServer):
 daemon_threads=False
 block_on_close=True
 def __init__(self,*args):self.slots=threading.BoundedSemaphore(16);super().__init__(*args)
 def process_request(self,request,address):
  if not self.slots.acquire(False):request.close();return
  try:super().process_request(request,address)
  except BaseException:self.slots.release();raise
 def process_request_thread(self,*args):
  try:super().process_request_thread(*args)
  finally:self.slots.release()
if __name__=='__main__':
 import signal
 server=Server(('0.0.0.0',8000),Handler)
 def stop(*args):threading.Thread(target=server.shutdown,daemon=True).start()
 signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
 server.serve_forever();server.server_close()
PY_API_SERVICE
}
api_container_owned() {
    local cname=$CONTAINER-API
    if docker container inspect "$cname" >/dev/null 2>&1; then
        [[ $(docker inspect -f '{{index .Config.Labels "aiwiki.api.owner"}}' "$cname") == "$PROJECT" ]] || { fail 'API同名容器不属于本项目'; return 1; }
    fi
}
api_running() { [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER-API" 2>/dev/null) == true ]]; }
api_remove_runtime() {
    api_container_owned || return 1
    if docker container inspect "$CONTAINER-API" >/dev/null 2>&1; then
        docker stop -t 60 "$CONTAINER-API" >/dev/null || return 1
        api_running && { fail 'API仍在运行，拒绝移除'; return 1; }
        docker rm "$CONTAINER-API" >/dev/null || return 1
    fi
    say 'API端口映射已关闭；PostgreSQL保持其独立配置的绑定地址与端口。'
}
api_apply() {
    api_container_owned || return 1
    local active_rc=0
    api_engine active || active_rc=$?
    case $active_rc in 0) :;; 1) api_remove_runtime; return;; *) fail 'API配置异常，未改变映射'; return 1;; esac
    local port bind mounts project
    local -a project_mounts=()
    port=$(api_engine port) || return 1
    bind=$(api_engine bind) || return 1
    [[ $bind == 127.0.0.1 || $bind == 0.0.0.0 ]] || return 1
    [[ $port =~ ^[0-9]{2,5}$ ]] && (( port>=1024 && port<=65535 )) || return 1
    mkdir -p "$ROOT/api-runtime" || return 1
    api_service_source > "$ROOT/api-runtime/server.py" || return 1
    printf 'FROM python:3.13-slim-bookworm\nRUN pip install --no-cache-dir "psycopg[binary]>=3.2,<4"\nWORKDIR /app\nCOPY server.py /app/server.py\nCMD ["python", "-u", "/app/server.py"]\n' > "$ROOT/api-runtime/Dockerfile" || return 1
    docker build -t "$PROJECT-api:local" "$ROOT/api-runtime" || return 1
    mounts=$(python3 - "$ROOT/config/apis.json" <<'PY_API_MOUNTS'
import json,sys,re
for p in sorted({a['project'] for a in json.load(open(sys.argv[1]))['apis'].values() if a['project']}):
 if not re.fullmatch(r'[a-z][a-z0-9_-]{0,47}',p):raise ValueError('unsafe project')
 print(p)
PY_API_MOUNTS
    ) || return 1
    while IFS= read -r project; do
        [[ -n $project ]] || continue
        valid_project "$project" && [[ -d $ROOT/$project && ! -L $ROOT/$project && $(realpath -m "$ROOT/$project") == "$ROOT/$project" ]] || return 1
        project_mounts+=(--mount "type=bind,src=$ROOT/$project,dst=/projects/$project")
    done <<< "$mounts"
    api_remove_runtime || return 1
    docker run -d --name "$CONTAINER-API" --label "aiwiki.api.owner=$PROJECT" --restart unless-stopped --network "$NETWORK" -p "$bind:$port:8000" -e "PGHOST=$CONTAINER" --mount "type=bind,src=$ROOT/config/apis.json,dst=/run/config/apis.json,readonly" "${project_mounts[@]}" --read-only --cap-drop ALL --security-opt no-new-privileges --pids-limit 100 --memory 256m --cpus 1 --ulimit core=0:0 --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 "$PROJECT-api:local" >/dev/null || return 1
    local i
    for i in {1..15}; do
        if docker exec "$CONTAINER-API" python -c 'import urllib.request;assert urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=2).status==200' >/dev/null 2>&1; then
            say "API绑定：$bind:$port；本机访问：http://127.0.0.1:$port。未修改Nginx或防火墙。"; return 0
        fi
        sleep 1
    done
    fail 'API启动健康检查失败，配置保留供修复'
}
api_add() {
    select_database_item database '输入要添加API的数据库序号（回车默认取消）：' || return 1
    local db=$SELECTED_NAME user project
    valid_name "$db" || return 1
    select_user_in_database "$db" || return 1; user=$SELECTED_NAME
    [[ $(printf 'SELECT rolsuper FROM pg_roles WHERE rolname=%s;\n' "$(ql "$user")" | sql) == f ]] || { fail 'API禁止使用超级管理员账户'; return 1; }
    project=$(python3 - "$ROOT/config/manager.json" "$db" <<'PY_API_PROJECT'
import json,sys
names=[n for n,v in json.load(open(sys.argv[1]))['projects'].items() if v['database']==sys.argv[2]]
if len(names)>1:sys.exit('数据库关联多个目录，拒绝自动映射')
print(names[0] if names else '')
PY_API_PROJECT
    ) || return 1
    api_prompt_binding || return 1
    local api_bind=$API_BIND_INPUT
    say "API将使用用户 $user；文件项目：${project:-无（仅数据库记录接口）}；API绑定：$api_bind，映射端口$(api_engine port)。"
    confirm '确认创建API？会创建专用记录表并授予该用户该表的读写权限。' || return 1
    # No arbitrary SQL endpoint. Only this API-owned key/value table is exposed.
    printf 'BEGIN; CREATE TABLE IF NOT EXISTS public.aiwiki_api_records(api_name text NOT NULL,record_id text NOT NULL,payload jsonb NOT NULL,PRIMARY KEY(api_name,record_id)); GRANT SELECT,INSERT,UPDATE,DELETE ON public.aiwiki_api_records TO %s; COMMIT;\n' "$(qi "$user")" | sql "$db" || return 1
    api_engine add "$db" "$user" "$project" && api_engine set-bind "$api_bind" && api_apply
}
api_edit() {
    local names name
    local -a entries=()
    names=$(api_engine names) || return 1; [[ -z $names ]] || mapfile -t entries <<< "$names"
    select_numbered '请输入序号选择（回车默认取消）：' "${entries[@]}" || return 1; name=$SELECTED_NAME
    api_prompt_binding || return 1
    local api_bind=$API_BIND_INPUT
    if api_engine edit '' '' '' "$name"; then
        api_engine set-bind "$api_bind" || return 1
        api_remove_runtime || return 1
        api_apply
    fi
}
api_delete() {
    local names name
    local -a entries=()
    names=$(api_engine names) || return 1; [[ -z $names ]] || mapfile -t entries <<< "$names"
    select_numbered '请输入序号选择（回车默认取消）：' "${entries[@]}" || return 1; name=$SELECTED_NAME
    confirm "删除API $name 配置？保留数据库及文件；最后一个API删除后撤销本地映射。" || return 1
    if api_engine delete "$name"; then
        api_remove_runtime || return 1
        api_apply
    fi
}
api_database_details() (
    load_env && managed || { say '数据库用户明细读取失败（项目未就绪）'; return; }
    local result
    result=$(printf "SELECT COALESCE(json_agg(row_to_json(x)),'[]'::json) FROM (SELECT d.datname AS database_name,COALESCE((SELECT json_agg(r.rolname ORDER BY r.rolname) FROM pg_roles r WHERE r.rolcanlogin AND has_database_privilege(r.oid,d.oid,'CONNECT')),'[]'::json) AS users FROM pg_database d ORDER BY d.datname) x;\n" | sql 2>/dev/null) || { say '数据库用户明细查询失败'; return; }
    printf '%s' "$result" | python3 -c '
import json,sys
rows=json.load(sys.stdin)
def clean(v):return "".join(c if c.isprintable() else "?" for c in str(v))
print("数据库用户明细（有效连接权限，包含PUBLIC/继承授权）")
for i,row in enumerate(rows,1):
 print(str(i)+". "+clean(row["database_name"])+"："+(", ".join(clean(u) for u in row["users"]) or "无可登录用户"))
' || say '数据库用户明细解析失败'
)
api_menu() {
    local choice
    while :; do
        [[ ! -t 1 || ${TERM:-dumb} == dumb ]] || clear
        say '=================================='
        say '管理API配置（PostgreSQL 5432不发布）'
        say '=================================='
        show_database_summary homepage
        say '=================================='
        api_database_details
        say '=================================='
        api_engine list
        say '=================================='
        say '1. 添加API'; say '2. 修改API配置/密钥'; say '3. 删除API配置'; say '0. 返回上一级'
        printf '请输入你的选择: ' >&2
        IFS= read -r choice || return
        case $choice in
            1) locked db_action api_add;;
            2) locked db_action api_edit;;
            3) locked db_action api_delete;;
            0) return;;
            *) fail '无效选项';;
        esac
        pause
    done
}
db_menu() {
    local choice
    while :; do
        [[ ! -t 1 || ${TERM:-dumb} == dumb ]] || clear
        say '=================================='
        say 'PostgreSQL 数据库管理'
        show_database_summary
        say '=================================='
        say '1. 创建博客项目'
        say '2. 删除博客项目'
        say '3. 创建数据库用户'
        say '4. 删除数据库用户'
        say '5. 修改用户密码'
        say '6. 管理数据库权限'
        say '7. 查看数据库及用户'
        say '8. 管理API配置'
        say '0. 返回上一级'
        printf '请输入你的选择：' >&2
        IFS= read -r choice || return
        case $choice in
            1) locked db_action blog_create;;
            2) locked db_action blog_delete;;
            3) locked db_action user_create;;
            4) locked db_action user_delete;;
            5) locked db_action password_change;;
            6) locked db_action permissions;;
            7) locked db_action view_db;;
            8) api_menu; continue;;
            0) return;;
            *) fail '无效选项';;
        esac
        pause
    done
}
choose_backup() {
    local n selected; local -a names=(); mapfile -t names < <(list_backups)
    ((${#names[@]})) || { fail '没有备份'; return 1; }
    say '检测到以下备份文件：' >&2
    for n in "${!names[@]}"; do printf '%s. %s\n' "$((n+1))" "${names[$n]}" >&2; done
    printf '请选择要恢复/管理的备份编号（回车选择最新备份，0取消）: ' >&2
    IFS= read -r selected || return 1
    [[ $selected != 0 ]] || return 1
    selected=${selected:-1}
    [[ $selected =~ ^[1-9][0-9]{0,5}$ ]] && (( selected <= ${#names[@]} )) || { fail '无效编号'; return 1; }
    SELECTED=${names[$((selected-1))]}
}
backup_manage() {
    local choice name
    while :; do
        say '1. 查看本地备份及时间/大小'; say '2. 检查备份完整性'; say '3. 删除指定备份'; say '4. 清理过期备份（始终保留最新有效备份）'; say '0. 返回'
        IFS= read -r choice || return
        case $choice in
            1) while IFS= read -r name; do [[ -z $name ]] || { say "$name"; du -sh "$name"; }; done < <(list_backups);;
            2) choose_backup && locked bundle_verify "$SELECTED";;
            3) choose_backup && confirm "永久删除备份 $SELECTED？" && locked delete_backup "$SELECTED";;
            4) ask '保留天数（最少1天）' && [[ $REPLY =~ ^[1-9][0-9]{0,4}$ ]] && locked expire_backups "$REPLY";;
            0) return;; *) fail '无效选项';;
        esac
        pause
    done
}
delete_backup() {
    local target=$1 keep
    [[ $(dirname "$target") == "$BACKUPS" || $(dirname "$target") == "$RESTORE_HOME" ]] && [[ ${target##*/} =~ ^Ai-wiki-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.tar\.gz$ && -f $target && ! -L $target ]] || return 1
    keep=$(latest_valid) || { fail '无法确认有有效备份，拒绝删除'; return 1; }
    [[ $target != "$keep" ]] || { fail '保护最新有效备份，不允许删除'; return 1; }
    rm -f -- "$target"
}
expire_backups() {
    local days=$1 n keep; local -a candidates=()
    keep=$(latest_valid) || return 1
    while IFS= read -r n; do
        [[ -n $n && $n != "$keep" ]] || continue
        if [[ -n $(find "$n" -maxdepth 0 -mtime "+$days" -print) ]]; then candidates+=("$n"); say "$n"; fi
    done < <(list_backups)
    ((${#candidates[@]})) || { say '没有过期备份'; return 0; }
    confirm '删除以上过期备份？最新有效备份始终保留。' || return 1
    for n in "${candidates[@]}"; do delete_backup "$n" || return 1; done
}
# Canonical CLIProxyAPI named SSH/S3 transport adapted to Ai-wiki archives.
BACKUP_DIR=$BACKUPS
REMOTE_DIR=$CONFIG_BASE
RETENTION_FILE=$CONFIG_BASE/local-retention.json
AI_APP_ID=ai-wiki-postgresql
AI_APP_LABEL=Ai-wiki-PostgreSQL
LOG_MAX_BYTES=2097152
LOG_BACKUPS=3
export AIWIKI_SCRIPT="${BASH_SOURCE[0]}"
error() { fail "$@"; }
ensure_environment() {
    prepare_base_environment || return 1
    AIWIKI_SCRIPT=$(realpath "$AIWIKI_SCRIPT") || return 1
    export AIWIKI_SCRIPT
    local cmd missing=0
    for cmd in rclone ssh-keyscan ssh-keygen; do command -v "$cmd" >/dev/null || missing=1; done
    if (( missing )); then install_packages rclone openssh-client ca-certificates || return 1; fi
    for cmd in rclone ssh-keyscan ssh-keygen; do command -v "$cmd" >/dev/null || { error "安装后仍缺少 $cmd"; return 1; }; done
    paths_safe || return 1
    [[ $(realpath -m "$CONFIG_BASE") == "$CONFIG_BASE" ]] || return 1
}
configure_local_retention() {
    ask '本地保留数量（默认3，至少1份，仅清理Ai-wiki时间戳归档）' || return 1
    local keep=${REPLY:-3}; [[ $keep =~ ^[1-9][0-9]{0,5}$ ]] && (( keep <= 100000 )) || return 1
    mkdir -p "$(dirname "$RETENTION_FILE")" || return 1
    printf '{"keep":%s}\n' "$keep" > "$RETENTION_FILE"
}
single_remote_engine() {
    python3 - "$REMOTE_DIR" "$BACKUP_DIR" "$@" 3<&0 <<'PY'
import os,sys,pathlib,json,re,subprocess,getpass,urllib.parse,tempfile,time,hashlib
sys.stdin=os.fdopen(3)
def secret_input(label):
    if sys.stdin.isatty(): return getpass.getpass(label,stream=sys.stderr)
    print(label,end='',file=sys.stderr,flush=True)
    value=sys.stdin.readline()
    if not value:raise EOFError()
    return value.rstrip('\n')
root=pathlib.Path(sys.argv[1]); backups=pathlib.Path(sys.argv[2]); mode=sys.argv[3]; kind=sys.argv[4]
if kind not in ('ssh-backup','ssh','s3'): raise ValueError('未知目标')
if root.resolve()!=root: raise ValueError('配置路径不能包含链接')
root.mkdir(parents=True,exist_ok=True,mode=0o700); os.chmod(root,0o700)
if any(x.is_symlink() for x in root.iterdir()):raise ValueError('配置文件不能为链接')
p=root/(kind+'.json'); conf=root/(kind+'.conf'); known=root/(kind+'-known-hosts')
def run(args,**kw):
    return subprocess.run(args,check=True,text=True,capture_output=True,timeout=900,**kw)
def ask(label,default=''):
    s=input(label+(' [默认 '+default+']' if default else '')+'（:quit取消）：').strip()
    if s in (':quit',':cancel','退出配置向导'): raise EOFError()
    return s or default
def valid(s):
    if not s or any(c in s for c in '\r\n\0'): raise ValueError('输入为空或含非法字符')
    if s in (':quit',':cancel','退出配置向导'): raise EOFError()
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
                print('密码认证需在本机配置中保存可还原密码（权限600），保存在项目外的配置目录，不会自动打入新完整备份；rclone obscure不是强加密。')
                if ask('输入yes确认保存SSH密码')!='yes': sys.exit(0)
                password=valid(secret_input('SSH密码（隐藏输入）：'))
            dest=valid(ask('远端专用备份目录',str(backups)))
            if not dest.startswith('/') or '..' in pathlib.PurePosixPath(dest).parts or dest=='/': raise ValueError('远端目录无效')
            print('将通过SFTP上传，保留全部远端备份，不删除远端文件：'+dest)
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            keys=run(['ssh-keyscan','-T','10','-p',port,host]).stdout
            if not keys.strip(): raise ValueError('未取得主机公钥')
            with tempfile.NamedTemporaryFile(mode='w',dir=root,delete=False) as f:f.write(keys); tmp=f.name
            try: print(run(['ssh-keygen','-lf',tmp]).stdout)
            finally: os.unlink(tmp)
            print('请与远端服务器管理员提供的指纹独立核对；扫描到的指纹本身不是信任证明。')
            if ask('核对无误请输入yes')!='yes': sys.exit(0)
            text='[remote]\ntype = sftp\nhost = '+host+'\nuser = '+user+'\nport = '+port+'\nknown_hosts_file = '+str(known)+'\n'
            if auth=='1': text+='key_file = '+str(key)+'\n'
            else:
                # 密码经stdin传入obscure，不进入命令行参数或日志。
                obscured=run(['rclone','obscure','-'],input=password+'\n').stdout.strip()
                if not obscured or '\n' in obscured: raise ValueError('密码处理失败')
                text+='pass = '+obscured+'\n'
            d['auth']='key' if auth=='1' else 'password'
            save(known,keys); d['dest']='remote:'+dest
            # Explicit configure action may create only the selected remote directory after authentication.
            # Actual mkdir follows conf commit; read-only test never creates paths.
        else:
            endpoint=valid(ask('S3 API Endpoint（非管理网页）'))
            u=urllib.parse.urlsplit(endpoint)
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in ('','/'): raise ValueError('Endpoint必须为HTTPS API地址，无用户名/路径/查询参数')
            bucket=valid(ask('存储桶名称（需提前创建）'))
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]{1,62}',bucket): raise ValueError('桶名无效')
            prefix=valid(ask('桶内专用备份前缀','备份/ai-wiki-postgresql')).strip('/')
            if not prefix or '..' in prefix.split('/') or ':' in prefix: raise ValueError('前缀无效')
            region=valid(ask('Region','us-east-1'))
            access=valid(secret_input('Access Key ID（隐藏输入）：')); secret=valid(secret_input('Secret Access Key（隐藏输入）：'))
            while True:
                keep=ask('S3远端备份保留数量','3')
                if keep.isdigit() and 1<=int(keep)<=100000: d['keep']=int(keep); break
                print('请输入1–100000的正整数。')
            d['dest']='remote:'+bucket+'/'+prefix
            print('目标：'+endpoint+'/'+bucket+'/'+prefix+'；保留最新'+str(d['keep'])+'份ai-wiki-postgresql时间戳归档')
            if ask('输入yes确认目标及清理范围')!='yes': sys.exit(0)
            text='[remote]\ntype = s3\nprovider = Other\nenv_auth = false\naccess_key_id = '+access+'\nsecret_access_key = '+secret+'\nendpoint = '+endpoint+'\nregion = '+region+'\nforce_path_style = true\nsign_accept_encoding = false\n'
        if d['action']=='backup':
            while True:
                print('备份间隔（1h/2h/4h/6h/8h/12h，1d/2d/3d/5d/7d/14d/30d）')
                interval=(input('h等于小时，d等于天[默认 7d]：').strip() or '7d')
                if interval in (':quit',':cancel','退出配置向导'):raise EOFError()
                if interval in ('1h','2h','4h','6h','8h','12h','1d','2d','3d','5d','7d','14d','30d'): break
                print('请输入完整间隔，例如4h或2d。')
            d['interval']=interval
            if interval.endswith('h'):
                hours=int(interval[:-1])
                minute=ask('北京时间每个周期的分钟','0')
                if not minute.isdigit() or not 0<=int(minute)<=59: raise ValueError('分钟无效')
                d['calendar']='*-*-* 00/'+str(hours)+':'+f'{int(minute):02}'+':00 Asia/Shanghai'
            else:
                hour=ask('每日备份北京时间小时','5'); minute=ask('分钟','0')
                if not hour.isdigit() or not minute.isdigit() or not 0<=int(hour)<=23 or not 0<=int(minute)<=59: raise ValueError('时间无效')
                d['calendar']='*-*-* '+f'{int(hour):02}:{int(minute):02}:00 Asia/Shanghai'
                d['anchor_day']=int((time.time()+8*3600)//86400)
        else:
            d['calendar']='*:*:00/30'
            print('传送监控每30秒检查；仅发送最新完整归档，已成功发送的不重复上传。')
        save(conf,text); save(p,json.dumps(d,ensure_ascii=False))
        if kind in ('ssh','ssh-backup'):
            rc(['mkdir',d['dest']]); rc(['lsjson',d['dest'],'--max-depth','1'])
        state=root/(kind+'-sent.json')
        if state.exists(): state.unlink()
        print('配置已保存，权限0600；凭据不进入备份包。')
    elif mode=='calendar': print(load()['calendar'])
    elif mode=='action': print(load().get('action','backup'))
    elif mode=='due':
        d=load(); interval=d.get('interval','7d')
        if d.get('action','backup')=='backup' and interval.endswith('d'):
            days=int(interval[:-1]); today=int((time.time()+(8*3600 if 'Asia/Shanghai' in d.get('calendar','') else 0))//86400)
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
    elif mode=='list':
        d=load(); listing=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
        for item in listing:
            if not item.get('IsDir'):print(str(item.get('Size',0))+' '+str(item.get('Path','')))
    elif mode=='download':
        d=load(); name=ask('要下载的Ai-wiki时间戳归档文件名')
        if not re.fullmatch(r'Ai-wiki-\d{4}-\d{2}-\d{2}-\d{6}\.tar\.gz',name):raise ValueError('归档名无效')
        dest=backups/name
        if dest.exists() or dest.is_symlink():raise ValueError('本地文件已存在，未覆盖')
        fd,tmppath=tempfile.mkstemp(prefix='.aiwiki-download-',dir=backups);os.close(fd)
        try:
            rc(['copyto',d['dest'].rstrip('/')+'/'+name,tmppath])
            run(['/bin/bash',os.environ['AIWIKI_SCRIPT'],'--verify-bundle',tmppath])
            os.chmod(tmppath,0o600);os.link(tmppath,dest)
        finally:os.unlink(tmppath)
        print('下载并完整验证成功，未自动恢复：'+name)
    elif mode=='upload':
        d=load(); files=[x for x in backups.glob('Ai-wiki-*.tar.gz') if x.is_file() and not x.is_symlink()]
        if not files: print('暂无归档，等待新备份。'); sys.exit(0)
        exact=os.environ.get('AIWIKI_EXACT_ARCHIVE')
        f=pathlib.Path(exact) if exact else max(files,key=lambda x:x.name)
        if f.parent!=backups or not f.is_file() or f.is_symlink():raise ValueError('精确归档不存在或越界')
        if not re.fullmatch(r'Ai-wiki-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',f.name): raise ValueError('归档名无效')
        st=f.stat()
        if not exact and time.time()-st.st_mtime<60: print('最新归档尚未稳定，稍后再传。'); sys.exit(0)
        state=root/(kind+'-sent.json')
        identity=[f.name,st.st_size,st.st_mtime_ns,st.st_ctime_ns,st.st_dev,st.st_ino]
        previous=json.loads(state.read_text()) if state.exists() else None
        if isinstance(previous,dict) and previous.get('version')==2 and previous.get('identity')==identity:
            print('最新归档已传送，跳过。'); sys.exit(0)
        run(['/bin/bash',os.environ['AIWIKI_SCRIPT'],'--verify-bundle',str(f)])
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
        rc(['copyto',str(f),target,'--immutable','--s3-upload-cutoff','32Mi','--s3-chunk-size','8Mi'])
        info=json.loads(rc(['lsjson',target,'--stat']).stdout)
        if info.get('IsDir') or info.get('Size')!=f.stat().st_size: raise ValueError('上传后远端大小校验失败；未执行清理')
        # 按字节比较本次归档；成功后才允许远端保留清理。
        rc(['check',str(f.parent),d['dest'],'--include',f.name,'--one-way','--download'])
        if kind=='s3':
            listing=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            owned=sorted([x['Path'] for x in listing if not x.get('IsDir') and re.fullmatch(r'Ai-wiki-(?:\d{4}-\d{2}-\d{2}-\d{6}|\d{14})\.tar\.gz',x.get('Path',''))],key=lambda name:name.replace('-',''),reverse=True)
            keep=d.get('keep',3)
            if not isinstance(keep,int) or isinstance(keep,bool) or keep<1: raise ValueError('S3保留数量无效，未清理')
            for name in owned[keep:]: rc(['deletefile',d['dest'].rstrip('/')+'/'+name])
            remaining=json.loads(rc(['lsjson',d['dest'],'--max-depth','1']).stdout)
            if any(x.get('Path') in owned[keep:] for x in remaining): raise ValueError('远端保留清理验证失败')
        now=f.stat()
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity: raise ValueError('归档在传送中发生变化；未提交成功记录')
        save(state,json.dumps(record))
        retention='SSH远端不删除' if kind in ('ssh','ssh-backup') else 'S3远端保留最新'+str(d.get('keep',3))+'份'
        print('上传并校验成功：'+f.name+'；'+retention+'；本地数量由本地备份设置独立控制。')
    else: raise ValueError('未知操作')
except (EOFError,KeyboardInterrupt):
    print('已取消。'); sys.exit(1)
except Exception as e:
    # 不回显rclone原始输出、S3凭据或完整配置。
    print('远程备份失败：'+(str(e) if isinstance(e,ValueError) else type(e).__name__),file=sys.stderr); sys.exit(1)
PY
}

# 配置修改顺序：配置锁→对应任务锁，均非阻塞；不同应用路径独立。
single_configuration_locked() (
    local kind=$1
    shift
    umask 077
    [[ $(realpath -m "$REMOTE_DIR") == "$REMOTE_DIR" ]] || exit 1
    mkdir -p "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { error "配置正在修改，请稍后重试。"; exit 1; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { error "该任务正在执行，未修改配置。"; exit 1; }
    "$@"
)
remote_schedule() { configuration_locked "$1" remote_schedule_unlocked "$@"; }

delete_remote_task() {
    remote_schedule_unlocked "$1" remove && remote_engine delete "$1"
}
single_remote_schedule_unlocked() {
    local kind=$1 action=$2 calendar script unit="${AI_APP_ID}-backup-$1"
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || return 1
    command -v systemctl >/dev/null && [[ -n ${AIWIKI_TEST_ROOT:-} || -d /run/systemd/system ]] || { error "定时备份需要systemd；配置可保留，仍可手动执行。"; return 1; }
    if [[ $action == remove ]]; then
        local owned
        for owned in "$UNIT_DIR/$unit.service" "$UNIT_DIR/$unit.timer"; do
            [[ ! -L $owned ]] || { error 'unit为链接，拒绝删除'; return 1; }
            if [[ -e $owned ]] && [[ $(IFS= read -r line < "$owned"; printf '%s' "$line") != '# Ai-wiki-PostgreSQL managed remote backup' ]]; then error '非本应用unit，拒绝删除'; return 1; fi
        done
        # 不强行终止正在传送的service；删除配置前检查。
        systemctl is-active --quiet "$unit.service" && { error "任务正在运行，请完成后再删除配置。"; return 1; }
        if [[ -e $UNIT_DIR/$unit.timer ]]; then systemctl disable --now "$unit.timer" || return 1; fi
        rm -f "$UNIT_DIR/$unit.timer" "$UNIT_DIR/$unit.service"
        systemctl daemon-reload
        return
    fi
    calendar=$(remote_engine calendar "$kind") || return 1
    script=$(readlink -f "${BASH_SOURCE[0]}") || return 1
    [[ $script =~ ^/[A-Za-z0-9_./-]+$ ]] || { error "定时运行的脚本路径不支持空格或特殊字符。"; return 1; }
    local target
    for target in "$UNIT_DIR/$unit.service" "$UNIT_DIR/$unit.timer"; do
        if [[ -L $target ]]; then error "unit为链接，拒绝覆盖：$target"; return 1; fi
        if [[ -e $target ]] && [[ $(IFS= read -r line < "$target"; printf '%s' "$line") != '# Ai-wiki-PostgreSQL managed remote backup' ]]; then error "同名外部unit，拒绝覆盖：$target"; return 1; fi
    done
    local changed
    changed=$(python3 - "$unit" "$script" "$kind" "$calendar" "${AIR_TASK_NAME:-}" "$UNIT_DIR" <<'PY'
import sys,pathlib
unit,script,kind,calendar,task_name=sys.argv[1:6]
base=pathlib.Path(sys.argv[6])
remote_args=('--remote-task '+task_name+' '+kind) if task_name else ('--remote '+kind)
service_content=('# Ai-wiki-PostgreSQL managed remote backup\n[Unit]\nDescription=Ai-wiki-PostgreSQL remote backup\n[Service]\nType=oneshot\nUMask=0077\nExecStart=/bin/bash '+script+' '+remote_args+' --scheduled\nStandardOutput=null\nStandardError=null\nTimeoutStartSec=2h\n')
timer_content=('# Ai-wiki-PostgreSQL managed remote backup\n[Unit]\nDescription=Ai-wiki-PostgreSQL daily remote backup\n[Timer]\nOnCalendar='+calendar+'\nPersistent=false\n[Install]\nWantedBy=timers.target\n')
changed=False
for suffix,content in (('.service',service_content),('.timer',timer_content)):
    base.mkdir(parents=True,exist_ok=True)
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
backup_event_log() {
    python3 - "$REMOTE_DIR" "$LOG_MAX_BYTES" "$LOG_BACKUPS" "$1" "$2" <<'PY'
import pathlib,sys,logging,logging.handlers,fcntl,os
root=pathlib.Path(sys.argv[1]); root.mkdir(parents=True,exist_ok=True,mode=0o700)
with (root/'log.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX)
    h=logging.handlers.RotatingFileHandler(root/'backup-transfer.log',maxBytes=int(sys.argv[2]),backupCount=int(sys.argv[3]),encoding='utf-8')
    h.setFormatter(logging.Formatter('%(asctime)s %(message)s'))
    logger=logging.getLogger('ai-wiki-postgresql'); logger.setLevel(logging.INFO); logger.addHandler(h)
    logger.info('%s %s',sys.argv[4],sys.argv[5]); h.close()
    for p in root.glob('backup-transfer.log*'): os.chmod(p,0o600)
PY
}
remote_run() {
    local kind=$1
    [[ -f $REMOTE_DIR/$kind.json ]] || { error "尚未配置远端。"; return 1; }
    local action rc=0 result
    unset AIWIKI_EXACT_ARCHIVE
    action=$(remote_engine action "$kind") || return 1
    local handoff=''
    if [[ $action == backup ]]; then
        backup_event_log "$kind" "本地备份开始" || return 1
        handoff=$(mktemp "$REMOTE_DIR/.result-XXXXXXXX") || return 1
        if ! AIWIKI_RESULT_FILE="$handoff" locked backup_pg; then rm -f "$handoff"; backup_event_log "$kind" '本地备份失败'; return 1; fi
        IFS= read -r AIWIKI_EXACT_ARCHIVE < "$handoff" || { rm -f "$handoff"; return 1; }
        rm -f "$handoff"
        [[ -f $AIWIKI_EXACT_ARCHIVE ]] || return 1
        export AIWIKI_EXACT_ARCHIVE
        locked prune_local_backups || return 1
        backup_event_log "$kind" '本地完整备份和原运行状态恢复完成' || return 1
    fi
    command -v rclone >/dev/null || {
        error "缺少rclone；本地备份保留，可由其他传送任务发送。"
        backup_event_log "$kind" "传送工具缺失，本地备份保留"; return 1;
    }
    result=$(remote_engine upload "$kind" 2>&1) || rc=$?
    [[ -z $result ]] || printf '%s\n' "$result"
    if (( rc )); then
        backup_event_log "$kind" "传送失败，本地备份保留" || return 1
    elif [[ $result == *'上传并校验成功'* ]]; then
        backup_event_log "$kind" "传送校验完成" || return 1
    fi
    # 无新文件/稳定等待/已发送跳过不写日志，防止空闲日志膨胀。
    return "$rc"
}
single_remote_locked_run() (
    local kind=$1
    [[ $kind == ssh-backup || $kind == ssh || $kind == s3 ]] || exit 1
    umask 077
    [[ $(realpath -m "$REMOTE_DIR") == "$REMOTE_DIR" ]] || exit 1
    mkdir -p "$REMOTE_DIR" || exit 1
    exec 7>"$REMOTE_DIR/configuration.lock" || exit 1
    flock -n 7 || { echo "配置正在修改，本次跳过。"; exit 0; }
    exec 8>"$REMOTE_DIR/$kind.lock" || exit 1
    flock -n 8 || { echo "该目标正在传送，本次跳过。"; exit 0; }
    flock -u 7
    exec 7>&-
    if [[ ${2:-} == --scheduled ]]; then
        local due_rc=0
        remote_engine due "$kind" || due_rc=$?
        [[ $due_rc != 3 ]] || exit 0
        [[ $due_rc == 0 ]] || exit "$due_rc"
    fi
    remote_run "$kind"
)

# Named-task context: old singleton configurations remain usable unchanged.
task_context() {
    local selector="$1"
    AIR_BASE_APP_ID="${AIR_BASE_APP_ID:-$AI_APP_ID}"
    if [[ "$selector" == *@* ]]; then
        AIR_TASK_KIND="${selector%%@*}"
        AIR_TASK_NAME="${selector#*@}"
        [[ "$AIR_TASK_NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { error '配置名称无效'; return 1; }
        [[ "$AIR_TASK_KIND" == ssh-backup || "$AIR_TASK_KIND" == ssh || "$AIR_TASK_KIND" == s3 ]] || return 1
        REMOTE_DIR="$CONFIG_BASE/tasks/$AIR_TASK_NAME"
        RETENTION_FILE="$REMOTE_DIR/local-retention.json"
        AI_APP_ID="$AIR_BASE_APP_ID-task-$AIR_TASK_NAME"
    else
        [[ $selector == ssh-backup || $selector == ssh || $selector == s3 ]] || return 1
        AIR_TASK_KIND="$selector"
    fi
}
remote_engine() (
    local mode="$1" selector="$2"; shift 2
    task_context "$selector" || exit 1
    single_remote_engine "$mode" "$AIR_TASK_KIND" "$@"
)
configuration_locked() (
    local selector="$1"; shift
    task_context "$selector" || exit 1
    single_configuration_locked "$AIR_TASK_KIND" "$@"
)
remote_schedule_unlocked() (
    local selector="$1"; shift
    task_context "$selector" || exit 1
    single_remote_schedule_unlocked "$AIR_TASK_KIND" "$@"
)
remote_locked_run() (
    local selector="$1"; shift
    require_tools || exit 1
    AIWIKI_SCRIPT=$(realpath "$AIWIKI_SCRIPT") || exit 1
    export AIWIKI_SCRIPT
    task_context "$selector" || exit 1
    single_remote_locked_run "$AIR_TASK_KIND" "$@"
)
task_selectors() {
    python3 - "$CONFIG_BASE" "${1:-all}" <<'PY_NTASKS'
import sys,re
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
named_summary() {
    local scope="${1:-all}" selector dir kind idx=0 title group
    local -a selectors=()
    if ! command -v python3 >/dev/null; then echo '任务汇总暂不可用（请通过安装或恢复入口补齐Python3）'; return 0; fi
    mapfile -t selectors < <(task_selectors "$scope")
    for group in ssh-backup ssh s3; do
        [[ "$scope" != ssh || "$group" != s3 ]] || continue
        [[ "$scope" != s3 || "$group" == s3 ]] || continue
        case "$group" in ssh-backup) title=SSH备份;; ssh) title=传送任务;; s3) title='S3 API 兼容传送任务';; esac
        echo "$title"; echo '备注名   状态'
        local found=0
        for selector in "${selectors[@]}"; do
            kind="${selector%%@*}"; [ "$kind" = "$group" ] || continue
            idx=$((idx+1));found=1
            dir="$CONFIG_BASE"
            [[ "$selector" != *@* ]] || dir="$dir/tasks/${selector#*@}"
            python3 - "$dir/$kind.json" "$idx" "$selector" "$AI_APP_ID" <<'PY_NSUMMARY'
import sys,json,subprocess
p,index,selector,base_app=sys.argv[1:]; d=json.load(open(p));kind=selector.split('@')[0]
app=base_app+'-task-'+selector.split('@')[1] if '@' in selector else base_app
unit=app+'-backup-'+kind+'.timer'
try: active=subprocess.run(['systemctl','is-active','--quiet',unit],capture_output=True,timeout=2).returncode==0
except (OSError,subprocess.TimeoutExpired): active=False
state='\033[32m正常（定时运行中）\033[0m' if active else '\033[33m异常（定时未运行）\033[0m'
name=''.join(c for c in str(d.get('name',selector)) if c.isprintable())
interval=str(d.get('interval','7d')); unit_label='小时' if interval.endswith('h') else '天'
timing='每30秒检测新备份并传送' if d.get('action')=='transfer' else '每'+interval[:-1]+unit_label+' '+str(d.get('calendar',''))+'（按配置时区）'
print(index+'. '+name+'   '+state+'  '+timing)
PY_NSUMMARY
        done
        [ "$found" = 1 ] || echo 暂无
        [ "$group" != ssh-backup ] && echo '==================================' || echo '------------------------'
    done
}
repair_remote_schedules() {
    local selector failed=0
    while IFS= read -r selector; do
        [ -n "$selector" ] || continue
        remote_schedule "$selector" enable >/dev/null || { error "修复 $selector 失败"; failed=1; }
    done < <(task_selectors all)
    return "$failed"
}
remote_menu() {
    local scope="$1" choice name target selected confirm
    local -a selectors=()
    ensure_environment || return 1
    repair_remote_schedules
    while true; do
        if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
        echo '=================================='
        echo "$AI_APP_LABEL ${scope^^} 远程备份配置"
        echo '=================================='
        named_summary "$scope"
        if [ "$scope" = ssh ]; then
            echo '1. 添加SSH备份任务（定时备份并上传）'
            echo '2. 添加传送任务（有新备份直接传送，不打包）'
        else echo '1. 添加S3任务（有新备份直接传送，不打包）'; fi
        echo '4. 查看远端备份'; echo '5. 下载远端完整备份'; echo '7. 测试远端读取';echo '8. 立即执行任务';echo '9. 删除任务（保留备份）';echo '0. 返回'
        read -r -p '请输入选项：' choice || return 0
        case "$choice" in
            1|2)
                if [ "$scope" = s3 ]; then [ "$choice" = 1 ] || continue; target=s3
                elif [ "$choice" = 1 ]; then target=ssh-backup; else target=ssh; fi
                read -r -p '配置名称（小写字母开头，数字/横线/下划线，最多32位）: ' name || return 0
                [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo '名称无效'; continue; }
                named_task_available "$name" || continue
                configuration_locked "$target@$name" named_configure "$target" || echo '任务添加未完成，已保存配置可在重开菜单时重试定时修复。'
                ;;
            4|5|7|8|9)
                mapfile -t selectors < <(task_selectors "$scope")
                read -r -p '任务编号（0返回）: ' selected || return 0
                [ "$selected" != 0 ] || continue
                [[ "$selected" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$selected" -le "${#selectors[@]}" ] || { echo '编号无效'; continue; }
                target="${selectors[$((selected-1))]}"
                case "$choice" in
                    4) remote_engine list "$target" ;;
                    5) configuration_locked "$target" remote_engine download "$target" ;;
                    7) remote_engine test "$target" ;;
                    8) remote_locked_run "$target" ;;
                    9) read -r -p '输入yes删除该任务（保留备份）: ' confirm; [ "$confirm" != yes ] || configuration_locked "$target" delete_remote_task "${target%%@*}" ;;
                esac
                ;;
            0) return 0 ;;
            *) echo 无效选项 ;;
        esac
    done
}
named_task_available() {
    python3 - "$CONFIG_BASE/tasks/$1" <<'PY_AVAILABLE'
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

named_configure() {
    local kind="$1" existing
    for existing in ssh ssh-backup s3; do
        if [[ -e "$REMOTE_DIR/$existing.json" || -e "$REMOTE_DIR/$existing.conf" ]]; then
            error '本应用同名任务配置已存在，未覆盖。'; return 1
        fi
    done
    if [ "$kind" = ssh-backup ]; then configure_local_retention || return 1; fi
    remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    remote_schedule_unlocked "$kind" enable
}
prune_local_backups() {
    python3 - "$BACKUPS" "$RETENTION_FILE" <<'PY_PRUNE'
import pathlib,sys,re,json
root=pathlib.Path(sys.argv[1]);cfg=pathlib.Path(sys.argv[2])
keep=json.loads(cfg.read_text())['keep'] if cfg.is_file() else 3
if type(keep)!=int or not 1<=keep<=100000:raise ValueError('invalid retention')
files=sorted((p for p in root.glob('Ai-wiki-*.tar.gz') if p.is_file() and not p.is_symlink() and re.fullmatch(r'Ai-wiki-\d{4}-\d{2}-\d{2}-\d{6}\.tar\.gz',p.name)),key=lambda p:p.name,reverse=True)
for p in files[keep:]:p.unlink()
PY_PRUNE
}
uninstall_pg() (
    ensure_docker && managed || exit 1
    local answer selector directory kind fd listing backup_file handoff
    local -a selectors=()
    local -A acquired_locks=()
    say "彻底卸载范围：$CONTAINER 容器、$NETWORK 网络、整个 $ROOT（所有数据库、博客文件和凭据）。"
    say "同时删除 $CONFIG_BASE 中的SSH/S3配置、凭据、状态及本项目定时任务。"
    say "先自动生成并验证完整项目冷备份；保留 $BACKUPS 中全部正式备份和远端已上传归档，不删除共享镜像或Docker。"
    say '注意：完整项目备份不包含安装目录外的SSH/S3配置；这些传送配置删除后需重新配置。'
    printf '确认先备份再彻底卸载请输入 yes（其他输入取消）: ' >&2
    IFS= read -r answer && [[ $answer == yes ]] || { say '已取消卸载'; exit 1; }
    [[ $(realpath -m "$CONFIG_BASE") == "$CONFIG_BASE" && ! -L $CONFIG_BASE && $CONFIG_BASE == "$BACKUPS/config" ]] || { fail '远程配置目录不安全'; exit 1; }
    listing=$(task_selectors all) || exit 1
    [[ -z $listing ]] || mapfile -t selectors <<< "$listing"
    # Application operation lock is held by the caller. Acquire task locks nonblocking:
    # an active producer waiting for that lock causes a safe abort, never a deadlock.
    for selector in "${selectors[@]}"; do
        directory=$CONFIG_BASE; kind=${selector%%@*}
        [[ $selector != *@* ]] || directory=$CONFIG_BASE/tasks/${selector#*@}
        [[ $(realpath -m "$directory") == "$directory" ]] || exit 1
        for listing in "$directory/configuration.lock" "$directory/$kind.lock"; do
            [[ -z ${acquired_locks[$listing]:-} ]] || continue
            [[ ! -L $listing ]] || exit 1
            exec {fd}>"$listing" || exit 1
            flock -n "$fd" || { fail '远程任务正在配置或传送，未执行备份或卸载，请完成后重试'; exit 1; }
            acquired_locks[$listing]=$fd
        done
    done
    # Preflight every owned unit before producing a backup or disabling any schedule.
    for selector in "${selectors[@]}"; do
        (
            task_context "$selector" || exit 1
            local unit="${AI_APP_ID}-backup-$AIR_TASK_KIND" file
            for file in "$UNIT_DIR/$unit.service" "$UNIT_DIR/$unit.timer"; do
                [[ ! -L $file ]] || exit 1
                if [[ -e $file ]] && [[ $(IFS= read -r line < "$file"; printf '%s' "$line") != '# Ai-wiki-PostgreSQL managed remote backup' ]]; then fail '发现非本项目定时单元，拒绝卸载'; exit 1; fi
            done
            if command -v systemctl >/dev/null && systemctl is-active --quiet "$unit.service"; then fail '定时服务仍在执行，拒绝卸载'; exit 1; fi
        ) || exit 1
    done
    handoff=$(mktemp "$TMPDIR/aiwiki-uninstall-result-XXXXXXXX") || exit 1
    trap 'rm -f -- "$handoff"' EXIT
    # Already inside the application's operation lock: do not call locked again.
    AIWIKI_RESULT_FILE="$handoff" backup_pg || { fail '卸载前备份失败，未卸载、未删除数据或配置'; exit 1; }
    IFS= read -r backup_file < "$handoff" || exit 1
    [[ -f $backup_file && ! -L $backup_file ]] && bundle_verify "$backup_file" || { fail '卸载前备份复核失败，未卸载'; exit 1; }
    say "卸载前备份已验证：$backup_file"
    # All task locks are held here; no nested configuration_locked acquisition.
    for selector in "${selectors[@]}"; do
        remote_schedule_unlocked "$selector" remove || { fail '定时任务停止失败，数据和配置保留'; exit 1; }
    done
    api_remove_runtime || { fail 'API资源卸载失败，目录和配置保留'; exit 1; }
    dc down --timeout 120 || { fail '容器资源卸载失败，目录和配置保留'; exit 1; }
    docker info >/dev/null 2>&1 || { fail 'Docker连接中断，未删除文件'; exit 1; }
    docker container inspect "$CONTAINER" >/dev/null 2>&1 && { fail '容器仍存在，未删除文件'; exit 1; }
    docker network inspect "$NETWORK" >/dev/null 2>&1 && { fail '网络仍存在，未删除文件'; exit 1; }
    paths_safe && [[ -f $ROOT/config/manager.json && ! -L $ROOT ]] || exit 1
    rm -rf -- "$ROOT" || { fail '安装目录清理失败，备份已保留'; exit 1; }
    if [[ -e $CONFIG_BASE ]]; then
        [[ $(realpath -m "$CONFIG_BASE") == "$CONFIG_BASE" && ! -L $CONFIG_BASE ]] || exit 1
        rm -rf -- "$CONFIG_BASE" || { fail '远程配置清理失败，数据库安装目录已删除，备份保留'; exit 1; }
    fi
    say "彻底卸载完成：本项目容器、网络、安装目录及远程备份配置已删除；本地备份保留：$backup_file。"
)
show_runtime_status() {
    local status='错误' color=31 state names
    if ! command -v docker >/dev/null 2>&1; then
        status='未安装'
    elif ! timeout 5 docker info >/dev/null 2>&1; then
        status='错误'
    elif state=$(timeout 5 docker inspect --type container -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null); then
        case $state in
            running\|unhealthy) status='错误';;
            running\|*) status='运行中'; color=32;;
            exited\|*|created\|*) status='停止'; color=33;;
            *) status='错误';;
        esac
    elif names=$(timeout 5 docker container ls -a --format '{{.Names}}' 2>/dev/null); then
        # Only a successful listing can establish absence; failed inspect alone cannot.
        if ! printf '%s\n' "$names" | grep -Fxq -- "$CONTAINER"; then status='未安装'; fi
    fi
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        printf '运行状态：\033[%sm%s\033[0m\n' "$color" "$status"
    else
        printf '运行状态：%s\n' "$status"
    fi
}
show_menu() {
    [[ ! -t 1 || ${TERM:-dumb} == dumb ]] || clear
    say '=================================='
    say 'Ai-wiki-PostgreSQL Docker 管理脚本'
    say "安装目录: $ROOT"
    say "备份目录: $BACKUPS"
    show_runtime_status
    [[ -z ${AIWIKI_TEST_ROOT:-} ]] || say '【隔离测试模式】'
    say '=================================='
    named_summary all
    show_database_summary homepage
    say '=================================='
    say '1. 安装 PostgreSQL'; say '2. 更新 PostgreSQL'; say '3. 完整备份'; say '4. 完整恢复'; say '5. SSH 远程备份配置'; say '6. S3 API 兼容备份配置'; say '7. PostgreSQL 数据库管理'; say '8. 备份管理'; say '9. 卸载 PostgreSQL'; say '0. 返回上一级'
}
main() {
    [[ $EUID == 0 ]] || { fail '请以 root 执行（物理数据所有权恢复需要）'; return 1; }
    local choice
    while :; do
        show_menu
        printf '请输入你的选择：' >&2
        IFS= read -r choice || { say '已退出'; return 0; }
        case $choice in
            1) bootstrap_operation install_pg;; 2) locked update_pg;; 3) locked backup_pg;; 4) bootstrap_operation restore_pg;;
            5) remote_menu ssh; continue;; 6) remote_menu s3; continue;; 7) db_menu; continue;; 8) backup_manage; continue;;
            9) locked uninstall_pg;; 0) say '已退出'; return 0;; *) fail '无效选项';;
        esac
        pause
    done
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case ${1:-} in
        --help) say 'sudo bash Ai-wiki-PostgreSQL.sh；默认只显示菜单。SSH/S3 使用 rclone；配置在 /home/备份/Ai-wiki-PostgreSQL/config。';;
        --verify-bundle) bundle_verify "${2:-}";;
        --remote) remote_locked_run "${2:-}" "${3:-}";;
        --remote-task) [[ ${2:-} =~ ^[a-z][a-z0-9_-]{0,31}$ ]] && remote_locked_run "${3:-}@${2}" "${4:-}";;
        '') main;;
        *) fail '不支持该参数'; exit 1;;
    esac
fi
