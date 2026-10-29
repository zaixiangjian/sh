#!/bin/bash
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


# 备份保存目录、文件名前缀与还原自动查找目录
HERMES_BACKUP_DIR="/home/备份/hermes"
HERMES_BACKUP_PREFIX="hermes"
HERMES_RESTORE_DIRS=("$HERMES_BACKUP_DIR" "/home" "/root")
# Hermes Agent 终端管理脚本 (轻量版)
# 设计哲学：极简、直观、调用原生功能

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Debian/Ubuntu 精简系统：启动时按需补装 Python 3。
hermes_manager_ensure_python3() {
    command -v python3 >/dev/null 2>&1 && return 0
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 缺少 python3，请使用 root 运行脚本以自动安装。" >&2
        return 1
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "❌ 未找到 apt-get，请手动安装 python3。" >&2
        return 1
    fi
    echo "正在安装缺失的依赖：python3"
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y python3 || {
        echo "❌ python3 安装失败，请检查软件源或网络后重试。" >&2
        return 1
    }
    command -v python3 >/dev/null 2>&1 || {
        echo "❌ 安装后仍未找到 python3。" >&2
        return 1
    }
}
hermes_manager_ensure_python3 || exit 1

# 确保 hermes 命令可用 (处理环境变量未加载的情况)
if ! command -v hermes >/dev/null 2>&1; then
    if [ -d "$HOME/.hermes/hermes-agent/venv/bin" ]; then
        export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"
    fi
fi

# 检查是否安装

# --- 科技lion 增强版 API 管理核心 ---
CONFIG_FILE="$HOME/.hermes/config.yaml"

config_tool() {
    # 自动适配 CONFIG_FILE 路径
    if [ ! -f "$CONFIG_FILE" ]; then
        local p
        for p in "/root/.hermes/config.yaml" /home/*/.hermes/config.yaml; do
            if [ -f "$p" ]; then
                CONFIG_FILE="$p"
                break
            fi
        done
    fi

    # 寻找可用的 Python 解释器，优先使用带有 pyyaml (yaml) 的环境
    local python_bin=""

    # 1. 尝试从 command -v hermes 指向的文件的 shebang/内容中提取 python 路径
    local hermes_cmd
    hermes_cmd=$(command -v hermes)
    if [ -n "$hermes_cmd" ] && [ -f "$hermes_cmd" ]; then
        # A. 检查第一行是否是 shebang
        local shebang
        shebang=$(head -n 1 "$hermes_cmd" 2>/dev/null)
        if [[ "$shebang" =~ ^#\! ]]; then
            local potential_py="${shebang#\#!}"
            if [ -f "$potential_py" ]; then
                if "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                    python_bin="$potential_py"
                fi
            fi
        fi
        # B. 检查是否是 Bash wrapper，追踪其实际指向的 bin 并提取 python3
        if [ -z "$python_bin" ]; then
            local wrapped_bin
            wrapped_bin=$(grep -Eo '"/[^"]+/venv/bin/hermes"' "$hermes_cmd" | tr -d '"' | head -n 1)
            if [ -z "$wrapped_bin" ]; then
                wrapped_bin=$(grep -Eo '/[a-zA-Z0-9_\.\-]+/hermes-agent/venv/bin/hermes' "$hermes_cmd" | head -n 1)
            fi
            if [ -n "$wrapped_bin" ] && [ -f "$wrapped_bin" ]; then
                local wrapped_shebang
                wrapped_shebang=$(head -n 1 "$wrapped_bin" 2>/dev/null)
                if [[ "$wrapped_shebang" =~ ^#\! ]]; then
                    local potential_py="${wrapped_shebang#\#!}"
                    if [ -f "$potential_py" ] && "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                        python_bin="$potential_py"
                    fi
                fi
                if [ -z "$python_bin" ]; then
                    local potential_py="${wrapped_bin%/hermes}/python3"
                    if [ -f "$potential_py" ] && "$potential_py" -c "import yaml" >/dev/null 2>&1; then
                        python_bin="$potential_py"
                    fi
                fi
            fi
        fi
    fi

    # 2. 尝试从常见绝对路径查找
    if [ -z "$python_bin" ]; then
        local paths=(
            "$HOME/.hermes/hermes-agent/venv/bin/python3"
            "$HOME/.hermes/hermes-agent/venv/bin/python"
            "/root/.hermes/hermes-agent/venv/bin/python3"
            "/root/.hermes/hermes-agent/venv/bin/python"
            "/usr/local/lib/hermes-agent/venv/bin/python3"
            "/usr/local/lib/hermes-agent/venv/bin/python"
            "/usr/lib/hermes-agent/venv/bin/python3"
            "/usr/lib/hermes-agent/venv/bin/python"
            "$HOME/.hermes/hermes-agent/.venv/bin/python3"
            "/root/.hermes/hermes-agent/.venv/bin/python3"
            "/usr/local/lib/hermes-agent/.venv/bin/python3"
            "/usr/lib/hermes-agent/.venv/bin/python3"
            /home/*/.hermes/hermes-agent/venv/bin/python3
            /home/*/.hermes/hermes-agent/venv/bin/python
            /home/*/.hermes/hermes-agent/.venv/bin/python3
        )
        local p
        for p in "${paths[@]}"; do
            if [ -f "$p" ]; then
                if "$p" -c "import yaml" >/dev/null 2>&1; then
                    python_bin="$p"
                    break
                fi
            fi
        done
    fi

    # 3. 兜底退回到系统全局 python3 或 python
    if [ -z "$python_bin" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python_bin="python3"
        else
            python_bin="python"
        fi
    fi

    $python_bin - "$CONFIG_FILE" "$@" <<'EOF'
import sys, yaml, json, os

path = sys.argv[1]
action = sys.argv[2]

def load():
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except:
        return {}

def save(d):
    with open(path, 'w', encoding='utf-8') as f:
        yaml.dump(d, f, sort_keys=False, allow_unicode=True)

try:
    data = load()
    if action == "get_info":
        m = data.get('model', {})
        res = {"m": m.get('default', '-'), "p": m.get('provider', '-'), "u": m.get('base_url', '-')}
        print(json.dumps(res))
    
    elif action == "list_p":
        print(json.dumps(data.get('custom_providers', [])))
    
    elif action == "add_p":
        n, u, k, m = sys.argv[3:7]
        ps = data.get('custom_providers', [])
        if not isinstance(ps, list): ps = []
        ps = [p for p in ps if p.get('name') != n]
        ps.append({"name": n, "base_url": u, "api_key": k, "model": m})
        data['custom_providers'] = ps
        save(data)
    
    elif action == "bulk_add":
        n_base, u, k, models_json = sys.argv[3:7]
        new_m_ids = json.loads(models_json)
        ps = data.get('custom_providers', [])
        if not isinstance(ps, list): ps = []
        # 移除旧的同前缀条目
        ps = [p for p in ps if not (isinstance(p, dict) and p.get('name', '').startswith(n_base + "/"))]
        # 移除可能存在的同名根条目
        ps = [p for p in ps if p.get('name') != n_base]
        for m_id in new_m_ids:
            ps.append({"name": f"{n_base}/{m_id}", "base_url": u, "api_key": k, "model": m_id})
        data['custom_providers'] = ps
        save(data)
    
    elif action == "del_p":
        n = sys.argv[3]
        ps = data.get('custom_providers', [])
        if isinstance(ps, list):
            data['custom_providers'] = [p for p in ps if p.get('name') != n and not p.get('name', '').startswith(n + "/")]
            save(data)

    elif action == "list_groups":
        ps = data.get('custom_providers', [])
        groups = []
        seen = set()
        for p in (ps if isinstance(ps, list) else []):
            name = p.get('name', '')
            g = name.split('/')[0] if '/' in name else name
            if g and g not in seen:
                seen.add(g)
                cnt = sum(1 for x in ps if x.get('name', '') == g or x.get('name', '').startswith(g + '/'))
                groups.append({"name": g, "count": cnt})
        print(json.dumps(groups))
    
    elif action == "list_groups_latency":
        import threading, urllib.request, time
        ps = data.get('custom_providers', [])
        groups = {}
        for p in (ps if isinstance(ps, list) else []):
            name = p.get('name', '')
            g = name.split('/')[0] if '/' in name else name
            if g not in groups:
                groups[g] = {'name': g, 'base_url': p.get('base_url', ''), 'api_key': p.get('api_key', ''), 'count': 0}
            groups[g]['count'] += 1
        results = {}
        def worker(g, url, key):
            if not url or not (url.startswith('http://') or url.startswith('https://')):
                results[g] = "N/A"
                return
            start = time.time()
            try:
                url = url.rstrip('/') + '/models'
                req = urllib.request.Request(url, headers={'Authorization': f'Bearer {key}'} if key else {})
                with urllib.request.urlopen(req, timeout=1.5) as r:
                    r.read()
                results[g] = f"{int((time.time() - start) * 1000)}ms"
            except urllib.error.HTTPError:
                results[g] = f"{int((time.time() - start) * 1000)}ms"
            except Exception:
                results[g] = "timeout"
        threads = []
        for g, info in groups.items():
            t = threading.Thread(target=worker, args=(g, info['base_url'], info['api_key']))
            t.start()
            threads.append(t)
        for t in threads:
            t.join()
        out = []
        for g, info in groups.items():
            out.append({'name': g, 'base_url': info['base_url'], 'count': info['count'], 'latency': results.get(g, 'N/A')})
        print(json.dumps(out))
    elif action == "switch":
        n, u, k, m = sys.argv[3:7]
        data['model'] = {"default": m, "provider": "custom", "base_url": u, "api_key": k}
        save(data)

except Exception as e:
    # 确保出错时返回合法的 JSON 避免 Bash 报错
    print(json.dumps([]))
    sys.exit(1)
EOF
}

install_gum() {
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}正在安装 gum (交互式选择器)...${NC}"
    if command -v apt >/dev/null 2>&1; then
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg 2>/dev/null
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | tee /etc/apt/sources.list.d/charm.list > /dev/null
        apt update -qq && apt install -y -qq gum
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        cat > /etc/yum.repos.d/charm.repo <<'REPO'
[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key
REPO
        rpm --import https://repo.charm.sh/yum/gpg.key
        if command -v dnf >/dev/null 2>&1; then dnf install -y gum; else yum install -y gum; fi
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install gum
    fi
}

install_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}检测到 jq 未安装，正在自动安装 jq...${NC}"

    if command -v apt >/dev/null 2>&1; then
        apt update -qq && apt install -y -qq jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y jq
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install jq
    else
        echo -e "${RED}无法自动安装 jq：未识别的包管理器，请手动安装 jq。${NC}"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${RED}jq 安装失败，请手动安装后重试。${NC}"
        return 1
    fi
}

hermes_model_probe() {
    local target_model="$1"
    local ps_json="$2"
    local probe_timeout=15
    local provider_name request_model base_url api_key

    # 从 custom_providers 中查找对应条目
    provider_name="$target_model"
    local entry=$(echo "$ps_json" | jq -c --arg n "$provider_name" '.[] | select(.name == $n)' 2>/dev/null)
    if [ -z "$entry" ]; then
        HERMES_PROBE_STATUS="ERROR"
        HERMES_PROBE_MESSAGE="未找到模型配置"
        HERMES_PROBE_LATENCY="-"
        HERMES_PROBE_REPLY="-"
        return 1
    fi

    base_url=$(echo "$entry" | jq -r .base_url)
    api_key=$(echo "$entry" | jq -r .api_key)
    request_model=$(echo "$entry" | jq -r .model)
    base_url="${base_url%/}"

    local tmp_response
    tmp_response=$(mktemp)

    # 使用 Python 探测，精确计时
    local probe_result
    probe_result=$(python3 - "$base_url" "$api_key" "$request_model" "$tmp_response" "$probe_timeout" <<'PYEOF'
import sys, time, json
try:
    import urllib.request, urllib.error
except ImportError:
    print("1|0|0")
    sys.exit(0)

base_url, api_key, model, resp_path, timeout = sys.argv[1:6]
timeout = int(timeout)
url = base_url + "/chat/completions"
payload = json.dumps({"model": model, "messages": [{"role": "user", "content": "hi"}], "temperature": 0, "max_tokens": 16}).encode()
req = urllib.request.Request(url, data=payload, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bearer {api_key}",
}, method="POST")

start = time.time()
body = b""
status = 0
exit_code = 0
try:
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        status = getattr(resp, "status", 200)
        body = resp.read()
except urllib.error.HTTPError as e:
    status = getattr(e, "code", 0) or 0
    body = e.read()
    exit_code = 22
except Exception as e:
    body = str(e).encode("utf-8", errors="replace")
    exit_code = 1

elapsed = int((time.time() - start) * 1000)
with open(resp_path, "wb") as f:
    f.write(body)
print(f"{exit_code}|{status}|{elapsed}")
PYEOF
)

    local p_exit p_http p_latency
    p_exit=${probe_result%%|*}
    p_http=${probe_result#*|}
    p_http=${p_http%%|*}
    p_latency=${probe_result##*|}

    # 提取回复摘要
    local reply_preview
    reply_preview=$(python3 - "$tmp_response" <<'PYEOF'
import json, sys
from pathlib import Path
raw = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip()
reply = ""
if raw:
    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            choices = data.get("choices") or []
            if choices and isinstance(choices[0], dict):
                msg = choices[0].get("message") or {}
                if isinstance(msg, dict):
                    reply = msg.get("content") or ""
            if not reply:
                for key in ("error", "message", "detail"):
                    v = data.get(key)
                    if isinstance(v, str) and v.strip():
                        reply = v.strip(); break
                    if isinstance(v, dict):
                        n = v.get("message")
                        if isinstance(n, str) and n.strip():
                            reply = n.strip(); break
    except:
        reply = raw
reply = " ".join(str(reply).split())[:120]
print(reply if reply else "(空返回)")
PYEOF
)
    rm -f "$tmp_response"

    if [ "$p_exit" = "0" ] && [ "$p_http" -ge 200 ] 2>/dev/null && [ "$p_http" -lt 300 ] 2>/dev/null; then
        HERMES_PROBE_STATUS="OK"
        HERMES_PROBE_MESSAGE="HTTP ${p_http}"
        HERMES_PROBE_LATENCY="${p_latency}ms"
        HERMES_PROBE_REPLY="$reply_preview"
        return 0
    else
        HERMES_PROBE_STATUS="FAIL"
        HERMES_PROBE_MESSAGE="HTTP ${p_http:-0} / exit ${p_exit:-1}"
        HERMES_PROBE_LATENCY="${p_latency:-?}ms"
        HERMES_PROBE_REPLY="$reply_preview"
        return 1
    fi
}

hermes_probe_status_line() {
    local status_text="$1"
    local color_ok='\033[32m' color_fail='\033[31m' reset='\033[0m'
    if [ "$status_text" = "可用" ]; then
        printf "%b最小检测结果：%s%b\n" "$color_ok" "$status_text" "$reset"
    else
        printf "%b最小检测结果：%s%b\n" "$color_fail" "$status_text" "$reset"
    fi
}

sync_single_api_provider_models() {
    local provider_name="$1"
    local ps_json="$2"

    local entry base_url api_key m_json m_list_str old_list added_list deleted_list
    entry=$(echo "$ps_json" | jq -c --arg n "$provider_name" '[.[] | select(.name == $n or (.name | startswith($n + "/")))] | .[0] // empty' 2>/dev/null)
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
        echo -e "${RED}❌ $provider_name: 未找到供应商配置${NC}"
        return 1
    fi

    base_url=$(echo "$entry" | jq -r '.base_url // empty')
    api_key=$(echo "$entry" | jq -r '.api_key // empty')
    base_url="${base_url%/}"
    if [ -z "$base_url" ]; then
        echo -e "${RED}❌ $provider_name: Base URL 为空${NC}"
        return 1
    fi

    m_json=$(curl -s -m 20 -H "Authorization: Bearer ${api_key}" "$base_url/models")
    m_list_str=$(echo "$m_json" | jq -r '.data[]?.id' 2>/dev/null | sed '/^$/d' | sort -u)
    if [ -z "$m_list_str" ]; then
        echo -e "${RED}❌ $provider_name: 无法获取模型列表${NC}"
        return 1
    fi

    old_list=$(echo "$ps_json" | jq -r --arg n "$provider_name" '
        .[]
        | select(.name == $n or (.name | startswith($n + "/")))
        | if .name == $n then (.model // empty) else ((.name | sub("^" + $n + "/"; "")) // .model // empty) end
    ' 2>/dev/null | sed '/^$/d' | sort -u)

    added_list=$(comm -13 <(printf '%s\n' "$old_list") <(printf '%s\n' "$m_list_str"))
    deleted_list=$(comm -23 <(printf '%s\n' "$old_list") <(printf '%s\n' "$m_list_str"))

    local added_count deleted_count current_count m_json_list
    added_count=$(printf '%s\n' "$added_list" | sed '/^$/d' | wc -l | tr -d ' ')
    deleted_count=$(printf '%s\n' "$deleted_list" | sed '/^$/d' | wc -l | tr -d ' ')
    current_count=$(printf '%s\n' "$m_list_str" | sed '/^$/d' | wc -l | tr -d ' ')

    m_json_list=$(printf '%s\n' "$m_list_str" | jq -R . | jq -s -c .)
    config_tool bulk_add "$provider_name" "$base_url" "$api_key" "$m_json_list"

    echo -e "${GREEN}✅ $provider_name: 新增 $added_count 个，删除 $deleted_count 个，当前 $current_count 个${NC}"
    if [ "$added_count" -gt 0 ]; then
        echo -e "${GREEN}＋ 新增模型($added_count):${NC}"
        printf '%s\n' "$added_list" | sed '/^$/d' | sed 's/^/  + /'
    fi
    if [ "$deleted_count" -gt 0 ]; then
        echo -e "${YELLOW}－ 删除模型($deleted_count):${NC}"
        printf '%s\n' "$deleted_list" | sed '/^$/d' | sed 's/^/  - /'
    fi
    return 0
}

sync_api_provider_models() {
    local target_provider="$1"
    local ps_json groups_json g_count synced_count failed_count provider_name

    ps_json=$(config_tool list_p)
    if [ "$(echo "$ps_json" | jq '. | length' 2>/dev/null)" -eq 0 ] 2>/dev/null; then
        echo -e "${RED}无 API 配置! 请先添加供应商。${NC}"
        return 1
    fi

    groups_json=$(config_tool list_groups)
    g_count=$(echo "$groups_json" | jq '. | length' 2>/dev/null)
    if [ "$g_count" -eq 0 ] 2>/dev/null || [ -z "$g_count" ]; then
        echo -e "${RED}无 API 供应商分组可同步。${NC}"
        return 1
    fi

    synced_count=0
    failed_count=0
    if [ -n "$target_provider" ]; then
        if sync_single_api_provider_models "$target_provider" "$ps_json"; then
            synced_count=$((synced_count + 1))
        else
            failed_count=$((failed_count + 1))
        fi
    else
        while read -r provider_name; do
            [ -z "$provider_name" ] && continue
            ps_json=$(config_tool list_p)
            if sync_single_api_provider_models "$provider_name" "$ps_json"; then
                synced_count=$((synced_count + 1))
            else
                failed_count=$((failed_count + 1))
            fi
        done < <(echo "$groups_json" | jq -r '.[].name')
    fi

    if [ "$failed_count" -eq 0 ]; then
        echo -e "${GREEN}✅ API 供应商模型列表同步完成并已写入配置${NC}"
    else
        echo -e "${YELLOW}⚠️ API 供应商模型列表同步完成：成功 $synced_count 个，失败 $failed_count 个${NC}"
    fi
}

api_management_submenu() {
    while true; do
        clear
        info=$(config_tool get_info)
        echo -e "${BLUE}=======================================${NC}"
        echo -e "      ${PURPLE}API & 模型管理 (OpenClaw 风格)${NC}"
        echo -e "${BLUE}=======================================${NC}"
        echo -e "${CYAN}当前激活模型:${NC} ${GREEN}$(echo $info | jq -r .m)${NC}"
        echo -e "---------------------------------------"
        echo -e "${CYAN}已配置 API 列表:${NC}"
        local groups_lat_json
        groups_lat_json=$(config_tool list_groups_latency)
        if [ "$(echo "$groups_lat_json" | jq '. | length' 2>/dev/null)" -eq 0 ] 2>/dev/null || [ -z "$groups_lat_json" ]; then
            echo -e "  ${YELLOW}(暂无配置)${NC}"
        else
            while read -r row; do
                local g_name g_url g_count g_latency lat_color lat_num
                g_name=$(echo "$row" | jq -r .name)
                g_url=$(echo "$row" | jq -r .base_url)
                g_count=$(echo "$row" | jq -r .count)
                g_latency=$(echo "$row" | jq -r .latency)
                lat_color="${GREEN}"
                if [ "$g_latency" = "timeout" ] || [ "$g_latency" = "N/A" ]; then
                    lat_color="${RED}"
                elif [[ "$g_latency" =~ ^[0-9]+ms$ ]]; then
                    lat_num=$(echo "$g_latency" | tr -d 'ms')
                    if [ "$lat_num" -gt 800 ]; then
                        lat_color="${RED}"
                    elif [ "$lat_num" -gt 300 ]; then
                        lat_color="${YELLOW}"
                    fi
                fi
                echo -e "  ● [${g_name}] (${g_count} 个模型) | 延迟: ${lat_color}${g_latency}${NC} | ${g_url}"
            done < <(echo "$groups_lat_json" | jq -c '.[]')
        fi
        echo -e "---------------------------------------"
        echo -e "1. ${YELLOW}切换模型 (带测速)${NC}"
        echo -e "2. 添加 API 供应商 (自动同步)${NC}"
        echo -e "3. ${YELLOW}同步 API 供应商模型列表${NC}"
        echo -e "4. 删除 API 供应商"
        echo -e "0. 返回主菜单"
        echo -e "---------------------------------------"
        read -p "选择序号: " sub_choice
        case "$sub_choice" in
            1)
                local orange="#FF8C00"
                local ps_json models_list model_count default_model selected_model confirm_switch

                ps_json=$(config_tool list_p)
                model_count=$(echo "$ps_json" | jq '. | length')

                if [ "$model_count" -eq 0 ] 2>/dev/null || [ -z "$model_count" ]; then
                    echo -e "${RED}无 API 配置! 请先添加供应商。${NC}"
                    sleep 1
                    continue
                fi

                # 构建带编号的模型列表
                models_list=$(echo "$ps_json" | jq -r '.[].name' | awk '{print "(" NR ") " $0}')
                default_model=$(config_tool get_info | jq -r .m)

                while true; do
                    clear
                    install_gum

                    # 若 gum 不可用，降级为手动输入
                    if ! command -v gum >/dev/null 2>&1; then
                        echo "--- 模型管理 ---"
                        echo "当前可用模型："
                        echo "$models_list"
                        echo "当前默认：${default_model}"
                        echo "----------------"
                        read -e -p "请输入模型编号或名称 (输入 0 退出): " selected_model

                        if [ "$selected_model" = "0" ]; then
                            break
                        fi
                        if [ -z "$selected_model" ]; then
                            echo "错误：不能为空，请重试。"
                            sleep 1
                            continue
                        fi
                        # 如果输入的是纯数字，从列表中取名称
                        if [[ "$selected_model" =~ ^[0-9]+$ ]]; then
                            selected_model=$(echo "$ps_json" | jq -r --argjson i "$((selected_model-1))" '.[$i].name // empty')
                            if [ -z "$selected_model" ]; then
                                echo "序号无效，请重试。"
                                sleep 1
                                continue
                            fi
                        fi
                    else
                        # gum 模式 — 完全复刻 openclaw 风格
                        gum style --foreground "$orange" --bold "模型管理"
                        gum style --foreground "$orange" "可用模型：${model_count}"
                        gum style --foreground "$orange" "当前默认：${default_model}"
                        echo ""
                        gum style --faint "↑↓ 选择 / 输入搜索 / Enter 测试 / Esc 退出"
                        echo ""

                        selected_model=$(echo "$models_list" | gum filter \
                            --placeholder "搜索模型（如 cli-api/gpt-4o）" \
                            --prompt "选择模型 > " \
                            --indicator "➜ " \
                            --prompt.foreground "$orange" \
                            --indicator.foreground "$orange" \
                            --cursor-text.foreground "$orange" \
                            --match.foreground "$orange" \
                            --header "" \
                            --height 35)

                        if [ -z "$selected_model" ] || echo "$selected_model" | head -n 1 | grep -iqE '^(error|usage|gum:)'; then
                            echo "操作已取消，正在退出..."
                            break
                        fi
                    fi

                    # 去掉编号前缀 "(N) "
                    selected_model=$(echo "$selected_model" | sed -E 's/^\([0-9]+\)[[:space:]]+//')

                    echo ""
                    echo "正在检测模型: $selected_model"
                    if hermes_model_probe "$selected_model" "$ps_json"; then
                        hermes_probe_status_line "可用"
                    else
                        hermes_probe_status_line "不可用"
                    fi
                    echo "状态：$HERMES_PROBE_MESSAGE"
                    echo "延迟：$HERMES_PROBE_LATENCY"
                    echo "摘要：$HERMES_PROBE_REPLY"
                    echo ""

                    printf "是否切换到该模型？[y/N，Esc 返回列表]: "
                    IFS= read -rsn1 confirm_switch
                    echo ""
                    if [ "$confirm_switch" = $'\x1b' ]; then
                        confirm_switch="no"
                    else
                        case "$confirm_switch" in
                            [yY])
                                IFS= read -rsn1 -t 5 _enter_key
                                confirm_switch="yes"
                                ;;
                            *) confirm_switch="no" ;;
                        esac
                    fi

                    if [ "$confirm_switch" != "yes" ]; then
                        echo "已返回模型选择列表。"
                        sleep 1
                        continue
                    fi

                    # 执行切换
                    local entry_data
                    entry_data=$(echo "$ps_json" | jq -c --arg n "$selected_model" '.[] | select(.name == $n)')
                    local sw_u sw_k sw_m
                    sw_u=$(echo "$entry_data" | jq -r .base_url)
                    sw_k=$(echo "$entry_data" | jq -r .api_key)
                    sw_m=$(echo "$entry_data" | jq -r .model)

                    echo "正在切换模型为: $selected_model ..."
                    config_tool switch "$selected_model" "$sw_u" "$sw_k" "$sw_m"

                    # 重启 gateway
                    echo -e "${YELLOW}正在重启 Gateway...${NC}"
                    hermes gateway stop >/dev/null 2>&1
                    hermes gateway start >/dev/null 2>&1
                    echo -e "${GREEN}✅ 模型已切换为: $sw_m${NC}"
                    sleep 2
                    break
                done
                ;;
            2)
                echo -e "${CYAN}--- 添加新 API 供应商 ---${NC}"
                read -p "请输入供应商名称 (如: DeepSeek): " n
                [ -z "$n" ] && continue
                read -p "请输入 Base URL (如: https://api.deepseek.com/v1): " u
                [ -z "$u" ] && continue
                u="${u%/}"
                echo -ne "${YELLOW}请输入 API Key (输入隐藏): ${NC}"
                read -s k
                echo ""
                [ -z "$k" ] && continue
                
                echo -e "${YELLOW}🔍 正在获取完整模型列表...${NC}"
                m_json=$(curl -s -m 10 -H "Authorization: Bearer $k" "$u/models")
                # 提取所有 ID
                m_list_str=$(echo "$m_json" | jq -r '.data[].id' 2>/dev/null | sort)
                
                if [ -n "$m_list_str" ]; then
                    # 转换为数组
                    m_array=()
                    while read -r line; do m_array+=("$line"); done <<< "$m_list_str"
                    m_count=${#m_array[@]}
                    
                    echo -e "${GREEN}✅ 发现 $m_count 个模型。请选择一个作为当前默认：${NC}"
                    PS3="请输入序号: "
                    select m_default in "${m_array[@]}"; do
                        [ -n "$m_default" ] && break
                    done
                    
                    echo -e "---------------------------------------"
                    read -p "是否同时添加该供应商的所有 $m_count 个模型？(y/N): " bulk_confirm
                    if [[ "$bulk_confirm" =~ ^[Yy]$ ]]; then
                        # 转换数组为 JSON
                        m_json_list=$(echo "$m_list_str" | jq -R . | jq -s -c .)
                        config_tool bulk_add "$n" "$u" "$k" "$m_json_list"
                        config_tool switch "$n/$m_default" "$u" "$k" "$m_default"
                        echo -e "${GREEN}✅ 已全量导入 $m_count 个模型。${NC}"
                    else
                        config_tool add_p "$n" "$u" "$k" "$m_default"
                        echo -e "${GREEN}✅ 已添加单个模型: $m_default${NC}"
                    fi
                else
                    echo -e "${RED}❌ 无法获取列表。${NC}"
                    read -p "请手动输入模型 ID: " m_manual
                    [ -n "$m_manual" ] && config_tool add_p "$n" "$u" "$k" "$m_manual"
                fi
                sleep 2
                ;;
            3)
                echo -e "${CYAN}--- 同步 API 供应商模型列表 ---${NC}"
                echo -e "${CYAN}已配置的供应商分组:${NC}"
                groups_json=$(config_tool list_groups)
                g_count=$(echo "$groups_json" | jq '. | length' 2>/dev/null)
                if [ "$g_count" -eq 0 ] 2>/dev/null || [ -z "$g_count" ]; then
                    echo -e "  ${YELLOW}(暂无配置)${NC}"
                    sleep 1
                    continue
                fi
                echo "$groups_json" | jq -r '.[] | "  ● \(.name) (\(.count) 个模型)"'
                echo ""
                read -p "请输入要同步的 API 名称(provider)，直接回车同步全部: " sync_provider
                sync_api_provider_models "$sync_provider"
                echo ""
                read -p "按回车键继续..."
                ;;
            4)
                echo -e "${CYAN}已配置的供应商分组:${NC}"
                groups_json=$(config_tool list_groups)
                g_count=$(echo "$groups_json" | jq '. | length')
                if [ "$g_count" -eq 0 ]; then
                    echo -e "  ${YELLOW}(暂无配置)${NC}"
                    sleep 1
                    continue
                fi
                # 列出供应商分组
                g_names=()
                while read -r row; do
                    g_name=$(echo "$row" | jq -r .name)
                    g_cnt=$(echo "$row" | jq -r .count)
                    g_names+=("$g_name")
                    echo -e "  ${GREEN}${#g_names[@]}.${NC} $g_name (${g_cnt} 个模型)"
                done < <(echo "$groups_json" | jq -c '.[]')
                echo -e "  ${GREEN}0.${NC} 取消"
                read -p "选择要删除的供应商序号: " d_idx
                if [ "$d_idx" == "0" ] || [ -z "$d_idx" ]; then continue; fi
                d_name="${g_names[$((d_idx-1))]}"
                if [ -n "$d_name" ]; then
                    read -p "确认删除 [$d_name] 及其所有模型? (y/N): " del_confirm
                    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                        config_tool del_p "$d_name"
                        echo -e "${RED}🗑️ 已删除 $d_name${NC}"
                        sleep 1
                    fi
                fi
                ;;
            0) break ;;
        esac
    done
}
check_installed() {
    if command -v hermes >/dev/null 2>&1; then return 0; else return 1; fi
}

# 只读核对官方 main：不使用 Hermes 的缓存更新提示，也不 fetch/reset。
# 返回：0=一致，1=不同，2=无法确认，3=非官方 main。
verify_official_main() {
    local version_text="$1" install_dir method branch remote local_sha remote_output remote_sha
    HERMES_MAIN_STATUS="无法确认是否最新"
    HERMES_LOCAL_SHA=""
    HERMES_REMOTE_SHA=""
    install_dir=$(printf '%s\n' "$version_text" | sed -n 's/^Install directory: //p' | head -n 1)
    method=$(printf '%s\n' "$version_text" | sed -n 's/^Install method: //p' | head -n 1)
    if [ "$method" != git ] || [ -z "$install_dir" ] || ! command -v git >/dev/null 2>&1; then
        HERMES_MAIN_STATUS="无法确认是否最新（安装信息不完整或非 Git 安装）"
        return 2
    fi
    branch=$(git -C "$install_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    remote=$(git -C "$install_dir" remote get-url origin 2>/dev/null) || remote=""
    case "$remote" in
        https://github.com/NousResearch/hermes-agent|https://github.com/NousResearch/hermes-agent.git|git@github.com:NousResearch/hermes-agent.git|ssh://git@github.com/NousResearch/hermes-agent.git) ;;
        *) HERMES_MAIN_STATUS="非官方 main（安装源不同）"; return 3 ;;
    esac
    if [ "$branch" != main ]; then
        HERMES_MAIN_STATUS="非官方 main（当前分支：${branch:-分离 HEAD}）"
        return 3
    fi
    local_sha=$(git -C "$install_dir" rev-parse --verify HEAD 2>/dev/null) || return 2
    if ! command -v timeout >/dev/null 2>&1; then
        HERMES_MAIN_STATUS="无法确认是否最新（缺少 timeout）"
        return 2
    fi
    # API 仅返回 SHA，比 Git 协议查询更轻；失败再短时尝试 Git。
    remote_sha=""
    if command -v curl >/dev/null 2>&1; then
        remote_sha=$(curl -fsSL --connect-timeout 2 --max-time 4 \
            -H 'Accept: application/vnd.github.sha' -H 'Cache-Control: no-cache' \
            https://api.github.com/repos/NousResearch/hermes-agent/commits/main 2>/dev/null) || remote_sha=""
    fi
    if [[ ! "$remote_sha" =~ ^[0-9a-f]{40}$ ]]; then
        remote_output=$(GIT_TERMINAL_PROMPT=0 timeout 3 git -c credential.helper= ls-remote --exit-code https://github.com/NousResearch/hermes-agent.git refs/heads/main 2>/dev/null) || {
            HERMES_MAIN_STATUS="无法确认是否最新（查询失败；更新请运行 hermes update）"
            return 2
        }
        remote_sha=$(printf '%s\n' "$remote_output" | awk '$2 == "refs/heads/main" {print $1}')
    fi
    if [[ ! "$local_sha" =~ ^[0-9a-f]{40}$ ]] || [[ ! "$remote_sha" =~ ^[0-9a-f]{40}$ ]]; then
        HERMES_MAIN_STATUS="无法确认是否最新（提交信息异常）"
        return 2
    fi
    HERMES_LOCAL_SHA="$local_sha"
    HERMES_REMOTE_SHA="$remote_sha"
    if [ "$local_sha" = "$remote_sha" ]; then
        HERMES_MAIN_STATUS="已是最新（已实时核对官方 main）"
        return 0
    fi
    HERMES_MAIN_STATUS="与官方 main 不一致（远端 ${remote_sha:0:7}；更新：hermes update 或菜单 7）"
    return 1
}

# 使用执行中的 Hermes 运行时及官方通道解析器，只读核对更新目标。
verify_update_channel() {
    local version_text="$1" result channel local_sha target_sha state
    HERMES_LOCAL_SHA=""; HERMES_REMOTE_SHA=""
    HERMES_MAIN_STATUS="无法检测当前更新通道"
    result="$(timeout 15 python3 - <<'PY_CHANNEL' 2>/dev/null
import json, subprocess
cmd=json.loads(subprocess.check_output(['hermes','--print-runtime-command'],text=True,timeout=2))
old="runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)"
if not isinstance(cmd,list) or len(cmd)<3 or cmd[-2]!='-c' or old not in cmd[-1]:
    raise SystemExit(1)
code='''
from pathlib import Path
import subprocess
from hermes_cli.config import load_config
from hermes_cli.update_channel import resolve_update_channel, channel_record, rides_default_channel
from hermes_cli.source_releases import resolve_source_target
root=Path(__import__('hermes_cli').__file__).resolve().parent.parent
config=load_config()
channel=resolve_update_channel(config,root)
head=subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True,timeout=2).strip()
if channel=='main':
    print('main|'+head+'||main')
else:
    try:
        target=resolve_source_target(channel,['git'],str(root),forward_only=rides_default_channel(channel_record(config,root),channel,root))
    except Exception:
        if channel!='stable':
            raise
        # GitHub API 限流时，直接使用官方发布页重定向及官方标签。
        import re, urllib.request
        from types import SimpleNamespace
        with urllib.request.urlopen('https://github.com/NousResearch/hermes-agent/releases/latest',timeout=4) as response:
            url=response.url
        match=re.fullmatch(r'https://github.com/NousResearch/hermes-agent/releases/tag/(v[0-9]+[.][0-9]+[.][0-9]+)',url)
        if not match:
            raise ValueError('invalid official release redirect')
        tag=match[1]
        remote=subprocess.check_output(['git','-c','credential.helper=','ls-remote','--exit-code','https://github.com/NousResearch/hermes-agent.git','refs/tags/'+tag,'refs/tags/'+tag+'^{}'],text=True,timeout=4)
        refs=dict(line.split()[::-1] for line in remote.splitlines())
        sha=refs.get('refs/tags/'+tag+'^{}',refs.get('refs/tags/'+tag,''))
        if not re.fullmatch(r'[0-9a-f]{40}',sha):
            raise ValueError('invalid official release SHA')
        ahead=False
        if head!=sha and rides_default_channel(channel_record(config,root),channel,root):
            ancestry=subprocess.run(['git','-C',str(root),'merge-base','--is-ancestor',sha,head],capture_output=True,timeout=2)
            if ancestry.returncode not in (0,1):
                raise ValueError('cannot verify release ancestry')
            ahead=ancestry.returncode==0
        target=SimpleNamespace(commit=head if ahead else sha,ahead=ahead)
    if not target.commit:
        raise ValueError('unsupported branch delivery')
    state='ahead' if target.ahead else ('equal' if head==target.commit else 'different')
    print(channel+'|'+head+'|'+target.commit+'|'+state)
'''
cmd[-1]=cmd[-1].replace(old,code)
subprocess.run(cmd,check=True,timeout=12)
PY_CHANNEL
    )" || return 2
    IFS='|' read -r channel local_sha target_sha state <<< "$result"
    if [ "$channel" = main ] && [ "$state" = main ]; then
        verify_official_main "$version_text"
        return $?
    fi
    [[ "$local_sha" =~ ^[0-9a-f]{40}$ ]] && [[ "$target_sha" =~ ^[0-9a-f]{40}$ ]] || return 2
    HERMES_LOCAL_SHA="$local_sha"; HERMES_REMOTE_SHA="$target_sha"
    case "$state" in
        equal) HERMES_MAIN_STATUS="已是最新（已核对 ${channel} 更新目标）"; return 0 ;;
        ahead) HERMES_MAIN_STATUS="已是最新（本地代码领先 ${channel} 发布版，等待下一次发布）"; return 0 ;;
        different) HERMES_MAIN_STATUS="${channel} 通道有更新（使用菜单 7 或 hermes update）"; return 1 ;;
        *) return 2 ;;
    esac
}

# 仅显示官方稳定发布版本号；不使用 PyPI 或本地缓存代替官方查询。
get_official_release_version() {
    local release url
    command -v curl >/dev/null 2>&1 || return 1
    release="$(curl -fsSL --connect-timeout 2 --max-time 4 \
        -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
        https://api.github.com/repos/NousResearch/hermes-agent/releases/latest 2>/dev/null |
        python3 -c 'import json,re,sys
try:
    data=json.load(sys.stdin)
    tag=data.get("tag_name", "")
    if data.get("draft") or data.get("prerelease") or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("invalid stable release")
    print(tag)
except (ValueError, TypeError, AttributeError):
    sys.exit(1)' 2>/dev/null)"
    if [[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s\n' "$release"; return 0
    fi
    url="$(curl -fsSL --connect-timeout 2 --max-time 5 -o /dev/null -w '%{url_effective}' \
        https://github.com/NousResearch/hermes-agent/releases/latest 2>/dev/null)" || return 1
    if [[ "$url" =~ ^https://github\.com/NousResearch/hermes-agent/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# 版本行用于展示；是否最新必须实时核对官方 main。
get_version() {
    if ! check_installed; then
        return
    fi

    local hv first_line update_line hermes_bin python_bin venv_dir metadata version

    if command -v timeout >/dev/null 2>&1; then
        # 使用官方运行时输出本地版本信息，关闭其缓存/联网更新检查。
        # 旧版不支持运行时查询时，短时回退到 --version。
        hv="$(timeout 3 python3 - <<'PY_VERSION' 2>/dev/null
import json, subprocess
cmd = json.loads(subprocess.check_output(['hermes', '--print-runtime-command'], text=True, timeout=2))
if not isinstance(cmd, list) or len(cmd) < 3 or cmd[-2] != '-c':
    raise SystemExit(1)
old = "runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)"
if old not in cmd[-1]:
    raise SystemExit(1)
cmd[-1] = cmd[-1].replace(old, 'from hermes_cli._startup_fast import print_fast_version_info; print_fast_version_info(check_updates=False)')
subprocess.run(cmd, check=True, timeout=2)
PY_VERSION
        )" || hv=""
        [ -n "$hv" ] || hv="$(timeout 3 hermes --version 2>/dev/null || true)"
    else
        hv="$(hermes --version 2>/dev/null || true)"
    fi

    first_line="$(echo "$hv" | sed -n '1p')"
    if [ -n "$first_line" ]; then
        local verify_rc display_version official_version local_base
        verify_update_channel "$hv"
        verify_rc=$?
        # 仅保留版本及提交数，不展示日期、分支或本地/远端 SHA。
        display_version="$(printf '%s\n' "$first_line" | sed -E 's/^Hermes Agent //; s/[[:space:]]*\(.*//; s/[[:space:]]*·.*//; s/\+([0-9]+)\.g[0-9a-f]+(\.dirty)?/\+\1个 Git 提交/')"
        # 上方仅比较稳定发布版本号；与下面的 main 提交核对独立。
        official_version="$(get_official_release_version)"
        local_base="$(extract_semver "$display_version")"
        if [ -z "$official_version" ] || [ -z "$local_base" ]; then
            printf '%s %b无法检测%b\n' "$display_version" "$YELLOW" "$NC"
        elif [ "${local_base#v}" = "${official_version#v}" ]; then
            printf '%s %b最新版本%b\n' "$display_version" "$GREEN" "$NC"
        elif version_lt "${local_base#v}" "${official_version#v}"; then
            printf '%s %b新版本 %s%b\n' "$display_version" "$RED" "$official_version" "$NC"
        else
            printf '%s 官方版本%s %b本地版本较新%b\n' "$display_version" "$official_version" "$YELLOW" "$NC"
        fi
        local display_local display_remote
        display_local="$(printf '%s\n' "$first_line" | sed -nE 's/.*\.g([0-9a-f]+).*/\1/p')"
        [ -n "$HERMES_LOCAL_SHA" ] && display_local="$HERMES_LOCAL_SHA"
        display_remote="${HERMES_REMOTE_SHA:0:7}"
        printf '当前版本 : %s\n' "${display_local:0:7}"
        printf '更新目标 : %s\n' "${display_remote:-未获取}"
        case "$verify_rc" in
            0) printf '%b%s%b\n' "$GREEN" "$HERMES_MAIN_STATUS" "$NC" ;;
            1) printf '%b%s%b\n' "$RED" "$HERMES_MAIN_STATUS" "$NC" ;;
            *) printf '%b%s%b\n' "$YELLOW" "$HERMES_MAIN_STATUS" "$NC" ;;
        esac
        printf '%b使用下方代码只在这一次更新最新提交 main 谨慎使用%b\n' "$YELLOW" "$NC"
        printf '%s\n' 'hermes update --channel main'
        return
    fi

    # 兜底：如果 hermes --version 异常，再读 dist-info/METADATA。
    hermes_bin="$(command -v hermes 2>/dev/null)"
    if [ -n "$hermes_bin" ] && [ -r "$hermes_bin" ]; then
        python_bin="$(sed -n '1s/^#!//p' "$hermes_bin" 2>/dev/null)"
        if [ -n "$python_bin" ] && [ -x "$python_bin" ]; then
            venv_dir="$(dirname "$(dirname "$python_bin")")"
            for metadata in "$venv_dir"/lib/python*/site-packages/hermes_agent-*.dist-info/METADATA; do
                [ -r "$metadata" ] || continue
                version="$(sed -n 's/^Version: //p' "$metadata" 2>/dev/null | sed -n '1p')"
                if [ -n "$version" ]; then
                    printf 'v%s %b无法检测%b\n' "${version#v}" "$YELLOW" "$NC"
                    return
                fi
            done
        fi
    fi
}

# 提取语义版本号，例如 v0.13.0 / 0.13.0
extract_semver() {
    echo "$1" | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1
}

# 比较两个版本号：$1 < $2 返回 0
version_lt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" != "$2" ] && [ "$1" != "$2" ]
}

# 获取 PyPI 最新版本：优先读缓存，过期后后台刷新，避免拖慢主菜单显示
get_latest_version() {
    local cache_dir cache_file lock_dir now cache_mtime lock_mtime ttl lock_ttl version
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/hermes-manager"
    cache_file="$cache_dir/hermes-agent-latest-version"
    lock_dir="$cache_dir/hermes-agent-latest-version.lock"
    ttl=21600       # 6 小时内不重复联网检查
    lock_ttl=300    # 后台刷新失败时，5 分钟内不重复启动刷新任务
    now="$(date +%s 2>/dev/null || echo 0)"

    mkdir -p "$cache_dir" 2>/dev/null || true

    # 缓存未过期：直接返回，菜单无网络等待。
    if [ -r "$cache_file" ]; then
        cache_mtime="$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)"
        if [ $((now - cache_mtime)) -lt "$ttl" ]; then
            sed -n '1p' "$cache_file" 2>/dev/null
            return
        fi
        # 缓存过期也先返回旧值，刷新放后台做，避免卡界面。
        version="$(sed -n '1p' "$cache_file" 2>/dev/null)"
    fi

    # 后台刷新：用锁避免每次打开菜单都发起 PyPI 请求。
    if mkdir "$lock_dir" 2>/dev/null; then
        (
            python3 - "$cache_file" <<'PY' 2>/dev/null
import json
import sys
import tempfile
import urllib.request
from pathlib import Path

cache_file = Path(sys.argv[1])
try:
    with urllib.request.urlopen('https://pypi.org/pypi/hermes-agent/json', timeout=2) as response:
        data = json.load(response)
    version = (data.get('info') or {}).get('version') or ''
    if version:
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile('w', dir=str(cache_file.parent), delete=False) as f:
            f.write('v' + version.lstrip('v') + '\n')
            tmp = f.name
        Path(tmp).replace(cache_file)
except Exception:
    pass
PY
            rmdir "$lock_dir" 2>/dev/null || true
        ) >/dev/null 2>&1 &
    elif [ -d "$lock_dir" ]; then
        lock_mtime="$(stat -c %Y "$lock_dir" 2>/dev/null || echo "$now")"
        if [ $((now - lock_mtime)) -gt "$lock_ttl" ]; then
            rmdir "$lock_dir" 2>/dev/null || true
        fi
    fi

    # 首次无缓存时不输出，不阻塞菜单；下次打开菜单会读到后台刷新结果。
    [ -n "$version" ] && echo "$version"
}

# 检查是否有新版本
get_update_notice() {
    if ! check_installed; then
        return
    fi

    local current_version latest_version current_plain latest_plain
    current_version="$(extract_semver "$(get_version)")"
    latest_version="$(extract_semver "$(get_latest_version)")"
    current_plain="${current_version#v}"
    latest_plain="${latest_version#v}"

    if [ -n "$current_plain" ] && [ -n "$latest_plain" ] && version_lt "$current_plain" "$latest_plain"; then
        echo -e "  ${YELLOW}有新版本 ${latest_version^^}${NC}"
    fi
}

# 获取网关状态
get_gateway_status() {
    if ! check_installed; then
        echo -e "${RED}未安装${NC}"
        return
    fi

    # 优先检查 Hermes 安装的 user systemd 服务，速度快且比扫进程更准。
    if command -v systemctl >/dev/null 2>&1; then
        case "$(systemctl --user is-active hermes-gateway.service 2>/dev/null)" in
            active)
                echo -e "${GREEN}运行中${NC}"
                return
                ;;
            inactive|failed|activating|deactivating)
                echo -e "${RED}已停止${NC}"
                return
                ;;
        esac
    fi

    # 兜底：兼容非 systemd 或手动启动的 gateway。
    if pgrep -u "$(id -u)" -f "(^|[[:space:]])(([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+hermes_cli\.main[[:space:]]+gateway[[:space:]]+run|([^[:space:]]*/)?hermes[[:space:]]+gateway[[:space:]]+run|hermes-gateway)([[:space:]]|$)" >/dev/null 2>&1; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}已停止${NC}"
    fi
}


refresh_hermes_path() {
    if ! command -v hermes >/dev/null 2>&1; then
        if [ -d "$HOME/.hermes/hermes-agent/venv/bin" ]; then
            export PATH="$HOME/.hermes/hermes-agent/venv/bin:$PATH"
        fi
    fi
}

add_app_id() {
mkdir -p /home/docker
touch /home/docker/appno.txt
grep -qxF "115" /home/docker/appno.txt || echo "115" >> /home/docker/appno.txt

}


get_hermes_home_dir() {
    local cfg_path
    if command -v hermes >/dev/null 2>&1; then
        cfg_path="$(hermes config path 2>/dev/null | sed -n '1p')"
        if [ -n "$cfg_path" ]; then
            dirname "$cfg_path"
            return
        fi
    fi
    echo "$HOME/.hermes"
}

# Reusable adaptation of CLIProxyAPI.sh original single-kind SSH/S3 engine.
# Parent supplies BACKUP_DIR BACKUP_PREFIX (including separator), REMOTE_DIR,
# LOCK_FILE RETENTION_FILE AI_APP_ID AI_APP_LABEL and ai_local_backup.
# Set AI_MANAGER_SCRIPT to the installed parent manager for systemd ExecStart.
# Source only defines functions; never installs timers or executes backups.
air_init() {
    [[ ${AI_APP_ID:-} == openclaw || ${AI_APP_ID:-} == hermes ]] || return 1
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
                interval=ask('备份间隔（1d/2d/3d/5d/7d/14d/30d）','7d')
                if interval in ('1d','2d','3d','5d','7d','14d','30d'): break
                print('请输入完整间隔，例如7d或14d。')
            d['interval']=interval
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
            print('最新归档已传送且未变化，跳过。'); sys.exit(0)
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
        if [f.name,now.st_size,now.st_mtime_ns,now.st_ctime_ns,now.st_dev,now.st_ino]!=identity:
            raise ValueError('归档在校验中发生变化；未上传或升级记录')
        record={'version':2,'identity':identity,'signature':signature}
        if previous==signature or (isinstance(previous,dict) and previous.get('signature')==signature):
            save(state,json.dumps(record))
            print('最新归档已传送，已更新快速检测记录，跳过。'); sys.exit(0)
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
    elif 'unable to authenticate' in diagnostic or 'authentication failed' in diagnostic or 'unable to connect to ssh-agent' in diagnostic:
        reason='SSH认证失败，请核对用户名、密码或私钥及服务端登录权限。'
    elif 'connection refused' in diagnostic:
        reason='远端拒绝连接，请检查SSH端口及服务是否运行。'
    elif 'timeout' in diagnostic or 'timed out' in diagnostic:
        reason='连接超时，请检查网络、防火墙或远端地址。'
    elif 'permission denied' in diagnostic:
        reason='远端目录权限不足，无法创建或读取。'
    elif 'directory not found' in diagnostic or 'no such file' in diagnostic:
        reason='远程目录或本地私钥文件不存在。'
    elif 'failed to reveal' in diagnostic or 'base64' in diagnostic or 'decrypt' in diagnostic:
        reason='SSH密码编码无效，请重新输入密码保存配置。'
    else:
        reason='远端命令失败（退出码'+str(e.returncode)+'），请检查连接、权限与目标配置。'
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
timing='每30秒检测新备份并传送' if d.get('action')=='transfer' else '每'+str(d.get('interval','7d')).removesuffix('d')+'天 '+str(d.get('calendar',''))+'（北京时间）'
print(index+'. '+name+'   '+state+'  '+timing)
PY_NSUMMARY
        done
        [ "$found" = 1 ] || echo 暂无
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
                if [ -e "$BACKUP_DIR/config/tasks/$name" ]; then echo '配置名称已存在，请使用新名称（不会修改正在运行的任务）。'; continue; fi
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
air_named_configure() {
    local kind="$1"
    if [ "$kind" = ssh-backup ]; then air_configure_local_retention || return 1; fi
    air_remote_engine configure "$kind" || return 1
    [ -f "$REMOTE_DIR/$kind.json" ] && [ -f "$REMOTE_DIR/$kind.conf" ] || return 1
    air_remote_schedule_unlocked "$kind" enable
}


air_manager_init() {
    BACKUP_DIR="$HERMES_BACKUP_DIR"
    BACKUP_PREFIX="${HERMES_BACKUP_PREFIX}-"
    REMOTE_DIR="$BACKUP_DIR/config"
    LOCK_FILE="$BACKUP_DIR/backup.lock"
    RETENTION_FILE="$REMOTE_DIR/local-retention.json"
    AI_APP_ID='hermes'
    AI_APP_LABEL='hermes'
    AI_NATIVE_BACKUP_FUNCTION='backup_memory_full'
    AI_MANAGER_SCRIPT=$(readlink -f "${BASH_SOURCE[0]}")
    air_init
}

ai_local_backup() {
    local result_file rc=0
    mkdir -p "$REMOTE_DIR" || return 1
    chmod 700 "$REMOTE_DIR" || return 1
    result_file=$(mktemp "$REMOTE_DIR/.producer-result.XXXXXX") || return 1
    # Run in the current shell so AI_NEW_ARCHIVE comes from this exact producer.
    AI_REMOTE_RESULT_FILE="$result_file"
    "$AI_NATIVE_BACKUP_FUNCTION" <<< y || rc=$?
    unset AI_REMOTE_RESULT_FILE
    if [ "$rc" -eq 0 ]; then
        IFS= read -r AI_NEW_ARCHIVE < "$result_file" || rc=1
        [ -f "$AI_NEW_ARCHIVE" ] || rc=1
        case "$AI_NEW_ARCHIVE" in "$BACKUP_DIR/"*.tar.gz) : ;; *) rc=1 ;; esac
    fi
    rm -f -- "$result_file"
    if [ "$rc" -ne 0 ]; then
        echo "❌ 本次备份未成功返回新归档，未上传历史文件。"
        return "$rc"
    fi
}

backup_memory_full() {
    local hermes_home backup_dir ts archive parent base confirm was_running wait_i tar_status
    hermes_home="$(get_hermes_home_dir)"
    backup_dir="$HERMES_BACKUP_DIR"
    ts="$(date +%Y%m%d-%H%M%S)"
    archive="$backup_dir/${HERMES_BACKUP_PREFIX}-${ts}.tar.gz"
    was_running=0

    if [ ! -d "$hermes_home" ]; then
        echo -e "${RED}❌ 未找到 Hermes 数据目录：$hermes_home${NC}"
        return 1
    fi

    echo -e "${YELLOW}即将备份 Hermes 记忆/配置/会话数据：${NC}$hermes_home"
    echo -e "${YELLOW}备份前会先停止 Gateway，等待缓存/SQLite WAL 落库，备份完成后再启动 Gateway。${NC}"
    echo -e "${YELLOW}注意：备份可能包含 .env、auth.json、config.yaml 等敏感信息，请妥善保管。${NC}"
    read -p "确认开始全量备份？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi

    mkdir -p "$backup_dir" || return 1
    local partial="${archive}.partial"
    native_archive_reserve "$partial" || return 1

    if command -v hermes >/dev/null 2>&1; then
        if systemctl --user is-active --quiet hermes-gateway 2>/dev/null || pgrep -u "$(id -u)" -f "(^|[[:space:]])(([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+hermes_cli\.main[[:space:]]+gateway[[:space:]]+run|([^[:space:]]*/)?hermes[[:space:]]+gateway[[:space:]]+run|hermes-gateway)([[:space:]]|$)" >/dev/null 2>&1; then
            was_running=1
        fi

        echo -e "${YELLOW}正在停止 Gateway，等待缓存/数据库完全落盘...${NC}"
        hermes_manager_stop_and_flush || return 1
    fi

    mkdir -p "$backup_dir"
    parent="$(dirname "$hermes_home")"
    base="$(basename "$hermes_home")"

    # 备份用户数据而不是 Hermes 安装体/缓存：保留记忆、会话、配置、技能、凭据、cron 等。
    tar \
        --exclude="$base/hermes-agent" \
        --exclude="$base/node" \
        --exclude="$base/installs" \
        --exclude="$base/tools" \
        --exclude="$base/lsp/node_modules" \
        --exclude="$base/lsp/bin" \
        --exclude="$base/bin/browser*" \
        --exclude="$base/bin/bu" \
        --exclude="$base/bin/tirith" \
        --exclude="$base/cache" \
        --exclude="$base/logs/*.log" \
        -czf "$partial" \
        -C "$parent" "$base"
    tar_status=$?
    if [[ $tar_status == 0 ]]; then native_archive_publish "$partial" "$archive" || tar_status=$?; fi
    rm -f -- "$partial"

    if [ "$was_running" -eq 1 ] && command -v hermes >/dev/null 2>&1; then
        echo -e "${YELLOW}正在重新启动 Gateway...${NC}"
        if ! hermes gateway start && ! systemctl --user start hermes-gateway.service; then
            echo "❌ 备份打包结束，但 Gateway 重新启动失败。归档保留：$archive"
            return 1
        fi
    fi

    if [ "$tar_status" -eq 0 ]; then
        chmod 600 "$archive" || return 1
        echo -e "${GREEN}✅ 备份完成：${NC}$archive"
        if [ -n "${AI_REMOTE_RESULT_FILE:-}" ]; then
            printf '%s\n' "$archive" > "$AI_REMOTE_RESULT_FILE" || return 1
        fi
    else
        echo -e "${RED}❌ 备份失败。${NC}"
        rm -f "$archive"
        return 1
    fi
}

hermes_manager_gateway_alive() {
    systemctl --user is-active --quiet hermes-gateway.service 2>/dev/null ||
    pgrep -u "$(id -u)" -f '(^|[[:space:]])(([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+hermes_cli\.main[[:space:]]+gateway[[:space:]]+run|([^[:space:]]*/)?hermes[[:space:]]+gateway[[:space:]]+run|hermes-gateway)([[:space:]]|$)' >/dev/null 2>&1
}

hermes_manager_stop_and_flush() {
    local i
    if command -v hermes >/dev/null 2>&1; then
        hermes gateway stop || echo "提示：CLI 停止未成功，继续检查 systemd。"
    fi
    systemctl --user stop hermes-gateway.service >/dev/null 2>&1 || true
    for i in {1..30}; do
        if ! hermes_manager_gateway_alive; then
            sleep 2
            sync
            return 0
        fi
        sleep 1
    done
    echo "❌ Gateway 未完全退出，已中止，未替换数据。" >&2
    return 1
}

hermes_manager_stage_archive() {
    python3 - "$1" "$2" "$3" <<'PY_HERMES_STAGE'
import os,sys,tarfile,posixpath,gzip,sqlite3,inspect
archive,stage,base=sys.argv[1:]
seen=set(); links=set()
with tarfile.open(archive,'r:gz') as tar:
    members=tar.getmembers()
    for m in members:
        n=m.name
        while n.startswith('./'): n=n[2:]
        n=n.rstrip('/')
        if not n or n.startswith('/') or '..' in n.split('/') or '\\' in n or n.split('/')[0]!=base:
            raise ValueError('备份包含越界路径或不匹配的数据根目录')
        if n in seen: raise ValueError('备份包含重复路径')
        seen.add(n)
        if not (m.isdir() or m.isfile() or m.issym() or m.islnk()):
            raise ValueError('备份包含不支持的特殊文件')
        if m.issym() or m.islnk():
            links.add(n)
            target=posixpath.normpath(posixpath.join(posixpath.dirname(n),m.linkname) if m.issym() else m.linkname)
            if m.linkname.startswith('/') or not (target==base or target.startswith(base+'/')):
                raise ValueError('备份包含外部链接，请先转换为数据目录内的真实文件')
    for n in seen:
        parts=n.split('/')
        if any('/'.join(parts[:i]) in links for i in range(1,len(parts))):
            raise ValueError('备份包含链接下的路径，拒绝解压')
    if 'filter' in inspect.signature(tar.extractall).parameters:
        tar.extractall(stage,filter='data')
    else:
        tar.extractall(stage)
with gzip.open(archive,'rb') as f:
    while f.read(1024*1024): pass
root=os.path.join(stage,base)
if not os.path.isdir(root) or not os.path.isfile(os.path.join(root,'config.yaml')):
    raise ValueError('备份缺少数据目录或 config.yaml')
for name in os.listdir(root):
    if name.endswith('.db'):
        db=os.path.join(root,name)
        if os.path.islink(db): raise ValueError('数据库不允许软链接')
        con=sqlite3.connect(db)
        try:
            if con.execute('pragma quick_check').fetchone()[0]!='ok': raise ValueError('SQLite检查失败')
        finally: con.close()
print('✅ 暂存解压及数据库检查通过。')
PY_HERMES_STAGE
}

# Restore prerequisite checks must complete before stopping Gateway or moving data.
hermes_manager_restore_dependencies() {
    local purpose="${1:-base}" item package
    local -a packages=() checks=(python3 git curl tar gzip xz flock)
    [ "$purpose" != lsp ] || checks+=(node npm)
    for item in "${checks[@]}"; do
        command -v "$item" >/dev/null 2>&1 && continue
        case "$item" in
            xz) package=xz-utils ;;
            flock) package=util-linux ;;
            node) package=nodejs ;;
            *) package="$item" ;;
        esac
        packages+=("$package")
    done
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q '^install ok installed$' || packages+=(ca-certificates)
    else
        packages+=(ca-certificates)
    fi
    if [ "${#packages[@]}" -gt 0 ]; then
        [ "$(id -u)" -eq 0 ] || { echo "❌ 恢复缺少依赖：${packages[*]}，请使用 root 自动安装。"; return 1; }
        command -v apt-get >/dev/null 2>&1 || { echo "❌ 需要 apt-get，请手动安装：${packages[*]}"; return 1; }
        echo "正在补齐恢复依赖：${packages[*]}"
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || {
            echo "❌ 恢复依赖安装失败，当前数据尚未替换。"; return 1;
        }
        hash -r
    fi
    for item in "${checks[@]}"; do
        command -v "$item" >/dev/null 2>&1 || { echo "❌ 安装后仍缺少：$item"; return 1; }
    done
    if [ "$purpose" = lsp ]; then
        node --version >/dev/null 2>&1 && npm --version >/dev/null 2>&1 || {
            echo "❌ Node.js/npm 无法执行，已中止恢复。"; return 1;
        }
    fi
}

hermes_manager_install_restored() {
    local home="$1" work="$2" rc=0
    hermes_manager_restore_dependencies base || return 1
    python3 - "$home" "$work" <<'PY_HERMES_SNAPSHOT'
import os,sys,shutil,json
from pathlib import Path
home,work=map(Path,sys.argv[1:]); dst=work/'protected';dst.mkdir(mode=0o700)
skip={'hermes-agent','node','tools','installs','cache','logs','lsp','bin'}
names=[]
for p in home.iterdir():
    if p.name in skip: continue
    names.append(p.name)
    if p.is_symlink(): (dst/p.name).symlink_to(os.readlink(p))
    elif p.is_dir(): shutil.copytree(p,dst/p.name,symlinks=True)
    else: shutil.copy2(p,dst/p.name)
(work/'protected.json').write_text(json.dumps(names))
PY_HERMES_SNAPSHOT
    [ "$?" -eq 0 ] || return 1
    curl -fsSL --connect-timeout 15 --max-time 180 https://hermes-agent.nousresearch.com/install.sh -o "$work/install.sh" || return 1
    HERMES_HOME="$home" HERMES_INSTALL_DIR="$home/hermes-agent" bash "$work/install.sh" --non-interactive --skip-setup || rc=$?
    python3 - "$home" "$work" <<'PY_HERMES_PROTECT'
import os,sys,json,shutil,hashlib
from pathlib import Path
home,work=map(Path,sys.argv[1:]); src=work/'protected'
for name in json.loads((work/'protected.json').read_text()):
    a=src/name;b=home/name
    if b.is_symlink() or b.is_file(): b.unlink()
    elif b.is_dir(): shutil.rmtree(b)
    if a.is_symlink(): b.symlink_to(os.readlink(a))
    elif a.is_dir(): shutil.copytree(a,b,symlinks=True)
    else: shutil.copy2(a,b)
    def files(p):
        if p.is_file() and not p.is_symlink(): return [(p,Path('.'))]
        if p.is_dir() and not p.is_symlink(): return [(x,x.relative_to(p)) for x in p.rglob('*') if x.is_file() and not x.is_symlink()]
        return []
    for x,rel in files(a):
        y=b if rel==Path('.') else b/rel
        with x.open('rb') as f, y.open('rb') as g:
            def digest(stream):
                h=hashlib.sha256()
                for chunk in iter(lambda:stream.read(1024*1024),b''): h.update(chunk)
                return h.digest()
            if digest(f)!=digest(g):
                raise ValueError('恢复数据校验失败')
print('✅ 恢复的配置、凭据和用户数据已保留并校验。')
PY_HERMES_PROTECT
    [ "$?" -eq 0 ] || return 1
    [ "$rc" -eq 0 ] || { echo "❌ 官方安装失败，用户数据与旧目录均保留。"; return "$rc"; }
    export PATH="$HOME/.local/bin:$PATH"
    hash -r
    command -v hermes >/dev/null 2>&1 || return 1
    HERMES_HOME="$home" hermes --print-runtime-command >/dev/null || return 1
    if [ -f "$home/lsp/package.json" ]; then
        hermes_manager_restore_dependencies lsp || return 1
        local npm_command
        npm_command=$(command -v npm) || return 1
        (cd "$home/lsp" && "$npm_command" install --ignore-scripts --no-audit --no-fund) || return 1
        mkdir -p "$home/lsp/bin"
        local entry
        for entry in "$home/lsp/node_modules/.bin/"*; do
            [ -e "$entry" ] || continue
            ln -sfn "$entry" "$home/lsp/bin/$(basename "$entry")" || return 1
        done
    fi
    return 0
}

hermes_manager_start_verified() {
    local home="$1" i
    export HERMES_HOME="$home"
    hermes gateway install --force --no-start-now --start-on-login || return 1
    systemctl --user daemon-reload || return 1
    systemctl --user enable hermes-gateway.service || return 1
    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$(id -un)" || echo "⚠️ 无法启用 linger，请检查退出 SSH 后服务能否持续运行。"
    fi
    hermes gateway start || return 1
    for i in {1..30}; do
        if systemctl --user is-active --quiet hermes-gateway.service; then
            sleep 5
            systemctl --user is-active --quiet hermes-gateway.service && return 0
        fi
        sleep 1
    done
    echo "❌ Gateway 未稳定运行，请检查：journalctl --user -u hermes-gateway.service -n 60" >&2
    return 1
}

restore_memory_full_install_latest() {
    local hermes_home backup_dir backups count i selected archive parent base ts old_dir manual_path
    hermes_manager_restore_dependencies base || return 1
    hermes_home="$(get_hermes_home_dir)"
    backup_dir="$HERMES_BACKUP_DIR"

    local search_dir
    local -A scanned_dirs=()
    echo "自动查找备份目录：${HERMES_RESTORE_DIRS[*]}"
    mapfile -t backups < <(
        for search_dir in "${HERMES_RESTORE_DIRS[@]}"; do
            search_dir="${search_dir%/}"
            [ -n "$search_dir" ] || search_dir=/
            [ -d "$search_dir" ] || continue
            [ -z "${scanned_dirs[$search_dir]+yes}" ] || continue
            scanned_dirs["$search_dir"]=1
            find "$search_dir" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@\t%p\n'
        done | sort -nr | cut -f2-
    )
    count="${#backups[@]}"

    echo ""
    echo -e "${CYAN}可用的备份${NC}"
    echo "-------------------------"
    if [ "$count" -eq 0 ]; then
    echo "未在配置的还原目录中找到 *.tar.gz 备份包。"
        return 1
    fi
    for i in "${!backups[@]}"; do
        printf "  %s. %s\n" "$((i+1))" "${backups[$i]}"
    done
    echo ""
    read -p "回车键还原最新的备份，序号选择备份恢复。输入0退出：" selected
    if [ -z "$selected" ]; then
        selected=1
    fi
    if [ "$selected" = "0" ]; then
        echo "已取消。"
        return 0
    fi
    if ! [[ "$selected" =~ ^[0-9]+$ ]] || [ "$selected" -lt 1 ] || [ "$selected" -gt "$count" ]; then
        echo -e "${RED}输入错误。${NC}"
        return 1
    fi
    archive="${backups[$((selected-1))]}"

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        echo -e "${RED}❌ 备份包无法读取或已损坏：$archive${NC}"
        return 1
    fi

    if ! tar -tzf "$archive" 2>/dev/null | grep -qx '\.hermes/'; then
        echo -e "${RED}❌ 备份包结构不正确：包内必须包含 .hermes/ 目录。${NC}"
        return 1
    fi
    echo -e "${YELLOW}将从以下备份还原：${NC}$archive"
    echo -e "${RED}警告：当前 $hermes_home 会被移动为 .before_restore 备份，然后替换为所选备份。${NC}"
    read -p "确认还原并安装/启动最新版 Hermes？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi

    parent="$(dirname "$hermes_home")"
    base="$(basename "$hermes_home")"
    [ "$hermes_home" != / ] && [ "$hermes_home" != "$HOME" ] && [ ! -L "$hermes_home" ] || { echo "❌ 数据目录不安全。"; return 1; }
    local work stage
    work=$(mktemp -d "$parent/.hermes-restore.XXXXXX") || return 1
    chmod 700 "$work"
    stage="$work/stage"
    mkdir -m 700 "$stage" || return 1
    cp -- "$archive" "$work/archive.tar.gz" || { rm -rf -- "$work"; return 1; }
    chmod 600 "$work/archive.tar.gz"
    if ! hermes_manager_stage_archive "$work/archive.tar.gz" "$stage" "$base"; then
        echo "❌ 备份校验/暂存失败，当前数据与服务未修改。"
        rm -rf -- "$work"
        return 1
    fi
    if [ -f "$stage/$base/lsp/package.json" ]; then
        if ! hermes_manager_restore_dependencies lsp; then
            rm -rf -- "$work"
            return 1
        fi
    fi
    if ! hermes_manager_stop_and_flush; then
        rm -rf -- "$work"
        return 1
    fi
    old_dir=$(mktemp -d "${hermes_home}.before_restore_$(date +%Y%m%d-%H%M%S).XXXXXX") || return 1
    rmdir "$old_dir" || return 1
    if [ -e "$hermes_home" ]; then
        mv -- "$hermes_home" "$old_dir" || { echo "❌ 无法保留原数据，已停止还原。"; return 1; }
    fi
    if ! mv -- "$stage/$base" "$hermes_home"; then
        [ ! -e "$hermes_home" ] && [ -d "$old_dir" ] && mv -- "$old_dir" "$hermes_home"
        echo "❌ 数据替换失败，已尝试回滚。"
        return 1
    fi
    echo "原数据/程序保留于：$old_dir"
    echo "正在安装最新版 Hermes，保留恢复的配置和平台凭据，不运行初始化向导..."
    if ! hermes_manager_install_restored "$hermes_home" "$work"; then
        echo "❌ 安装或数据校验未完成，未启动 Gateway。"
        echo "恢复数据：$hermes_home；旧数据：$old_dir；暂存目录：$work"
        return 1
    fi
    if ! hermes_manager_start_verified "$hermes_home"; then
        echo "❌ 数据已还原但 Gateway 启动失败，旧数据保留：$old_dir"
        return 1
    fi
    add_app_id
    rm -rf -- "$work"
    echo "✅ 备份数据已还原，最新版 Hermes Gateway 已稳定启动。"
    echo "Telegram/Discord 等平台沿用备份配置；凭据失效或网络异常仍会导致平台连接失败。"
    echo "可检查：hermes gateway status --deep"
    echo "旧数据/程序保留于：$old_dir"
}

backup_restore_submenu() {
    air_manager_init || return 1
    air_repair_remote_schedules
    while true; do
        clear
        echo -e "${CYAN}=================================================${NC}"
        echo -e "${YELLOW}              备份与还原                         ${NC}"
        echo -e "${CYAN}=================================================${NC}"
        echo "备份目录：$HERMES_BACKUP_DIR"
        echo "数据目录：$(get_hermes_home_dir)"
        echo "---------------------------------------"
        air_named_summary all
        echo -e "${GREEN}1.${NC} 备份记忆全量"
        echo -e "${GREEN}2.${NC} 还原记忆全量并安装启动最新版"
        echo -e "${GREEN}3.${NC} SSH 远程备份配置"
        echo -e "${GREEN}4.${NC} S3 API 兼容备份配置"
        echo -e "${GREEN}0.${NC} 返回主菜单"
        echo -e "${CYAN}=================================================${NC}"
        read -p "请选择功能 [0-4]: " br_choice
        echo ""
        case "$br_choice" in
            1) backup_memory_full ;;
            2) restore_memory_full_install_latest ;;
            3) air_remote_menu ssh ;;
            4) air_remote_menu s3 ;;
            0) break ;;
            *) echo -e "${RED}输入错误，请重新选择。${NC}" ;;
        esac
        echo ""
        read -p "按回车键继续..."
    done
}

hermes_update_robust() {
    if ! check_installed; then
        echo -e "${RED}请先安装 Hermes。${NC}"
        return 1
    fi

    local version_text update_rc

    echo -e "${YELLOW}正在执行官方更新：hermes update${NC}"
    hermes update
    update_rc=$?

    refresh_hermes_path
    hash -r 2>/dev/null || true

    version_text="$(timeout 8 hermes --version 2>&1)"
    local verify_rc
    verify_update_channel "$version_text"
    verify_rc=$?
    echo "$version_text" | sed -n '1,8p'
    if [ "$update_rc" -eq 0 ] && [ "$verify_rc" -eq 0 ]; then
        echo -e "${GREEN}✅ 官方更新完成，${HERMES_MAIN_STATUS}。${NC}"
        add_app_id
        return 0
    fi
    if [ "$update_rc" -ne 0 ]; then
        echo -e "${RED}❌ 官方更新命令失败（退出码 $update_rc）。${NC}"
    else
        echo -e "${YELLOW}⚠ 官方更新命令已结束，但未通过实时最新版本验证。${NC}"
    fi
    echo -e "${YELLOW}${HERMES_MAIN_STATUS}${NC}"
    echo ""
    echo -e "${YELLOW}为降低供应链风险，脚本不会执行 git fetch/reset 等强制兜底更新。${NC}"
    echo -e "${YELLOW}请检查上方 hermes update 输出及当前更新通道；查询失败时检查网络或稍后重试。${NC}"
    return 1
}


hermes_messaging_robust() {
    if ! check_installed; then
        echo -e "${RED}请先安装 Hermes。${NC}"
        return 1
    fi

    echo -e "${YELLOW}正在启动 Hermes 机器人连接配置向导...${NC}"
    echo ""

    hermes gateway setup
    local setup_rc=$?

    if [ "$setup_rc" -eq 0 ]; then
        echo -e "${GREEN}✅ Hermes Gateway 配置完成。${NC}"
        echo ""
        echo -e "${YELLOW}现在可以启动 Gateway：${NC}"
        echo "  hermes gateway start"
        echo ""
        echo -e "${YELLOW}查看状态：${NC}"
        echo "  hermes gateway status"
    else
        echo -e "${RED}❌ Hermes Gateway 配置失败。${NC}"
        return "$setup_rc"
    fi
}



# 主菜单UI
show_menu() {
    clear
    echo -e "${CYAN}=================================================${NC}"
    echo -e "${YELLOW}           Hermes Agent 终端管理工具             ${NC}"
    echo -e "${CYAN}=================================================${NC}"
    echo -e "运行状态 : $(get_gateway_status)"
    echo -e "当前版本 : $(get_version)"
    echo -e "${CYAN}-------------------------------------------------${NC}"
    echo -e "${GREEN}1.${NC} 安装 Hermes Agent"
    echo -e "${GREEN}2.${NC} 启动 Gateway (消息网关/后台服务)"
    echo -e "${GREEN}3.${NC} 停止 Gateway"
    echo -e "${GREEN}4.${NC} API/模型管理 (提供商与模型切换)"
    echo -e "${GREEN}5.${NC} 启动终端对话UI (Interactive Chat)"
    echo -e "${GREEN}6.${NC} 运行初始化配置向导 (Setup Wizard)"
    echo -e "${GREEN}7.${NC} 检查并更新 Hermes"
    echo -e "${GREEN}8.${NC} 卸载 Hermes"
    echo -e "${GREEN}9.${NC} 机器人连接对接"
    echo -e "${GREEN}18.${NC} 备份与还原"
    echo -e "${GREEN}0.${NC} 退出"
    echo -e "${CYAN}=================================================${NC}"
    if ! read -p " 请输入数字 [0-18]: " choice; then
        echo -e "\n${GREEN}退出脚本。${NC}"
        exit 0
    fi
    echo ""
    
    case $choice in
        1)
            echo -e "${YELLOW}开始安装 Hermes Agent...${NC}"
            curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
            refresh_hermes_path
            hermes gateway install
            hermes gateway start
            add_app_id
            ;;
        2)
            if check_installed; then
                echo -e "${YELLOW}正在启动 Gateway...${NC}"
                systemctl --user start hermes-gateway
                hermes gateway stop
                hermes gateway start
            else echo -e "${RED}请先安装 Hermes。${NC}"; fi
            ;;
        3)
            if check_installed; then
                echo -e "${YELLOW}正在停止 Gateway...${NC}"
                hermes gateway stop
            else echo -e "${RED}请先安装 Hermes。${NC}"; fi
            ;;
        4)
            if check_installed; then
                install_jq || { read -p "按回车键返回主菜单..."; return; }
                echo -e "${YELLOW}进入模型配置向导...${NC}"
                api_management_submenu
            else echo -e "${RED}请先安装 Hermes。${NC}"; fi
            ;;
        5)
            if check_installed; then
                echo -e "${YELLOW}即将进入交互式终端，输入 /exit 即可退出返回。${NC}"
                sleep 1
                hermes
            else echo -e "${RED}请先安装 Hermes。${NC}"; fi
            ;;
        6)
            if check_installed; then
                echo -e "${YELLOW}正在启动初始化配置向导...${NC}"
                hermes setup
            else echo -e "${RED}请先安装 Hermes。${NC}"; fi
            ;;
        7)
            hermes_update_robust
            ;;
        8)
            if check_installed; then
                read -p "确定要卸载 Hermes 吗？所有数据将被清除。(y/N): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    air_manager_init && bsl_engine purge || { echo "本地定时备份清理失败，取消卸载。" >&2; return 1; }
                    hermes uninstall
                    sed -i "/\b115\b/d" /home/docker/appno.txt
                else echo "已取消。"; fi
            else echo -e "${RED}请先安装 Hermes。${NC}"; fi
            ;;

        9)
            hermes_messaging_robust
            ;;

        18)
            backup_restore_submenu
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}输入错误，请重新选择。${NC}"
            ;;
    esac
    echo ""
    read -p "按回车键返回主菜单..."
}


# Local-only scheduled backups: embedded engine, no SSH/S3 credentials.
BSL_ID='hermes'
BSL_LABEL='Hermes'
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
    python3 - "$BACKUP_DIR" 'hermes-\d{8}-\d{6}\.tar\.gz\.partial' <<'PY_PARTIAL_CLEAN'
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
    BSL_DATA_DIR=""
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
    HERMES_BACKUP_DIR="$BACKUP_DIR"
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
if [[ ${1:-} == --remote-task ]]; then
    air_manager_init || exit 1
    air_ensure_environment || exit 1
    air_remote_locked_run "${3:-}@${2:-}" "${4:-}"
    exit $?
fi
if [[ ${1:-} == --remote ]]; then
    air_manager_init || exit 1
    air_ensure_environment || exit 1
    air_remote_locked_run "${2:-}" "${3:-}"
    exit $?
fi

# 主循环
while true; do
    show_menu
done
