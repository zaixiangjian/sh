#!/bin/bash

bai='\033[0m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

send_stats() { return 0; }

break_end() {
    echo "操作完成"
    read -n 1 -s -r -p "按任意键继续..."
    echo ""
}

install() {
    if [ $# -eq 0 ]; then
        echo "未提供软件包参数!"
        return 1
    fi
    for package in "$@"; do
        if ! command -v "$package" >/dev/null 2>&1; then
            echo -e "${gl_huang}正在安装 $package...${gl_bai}"
            if command -v apt >/dev/null 2>&1; then
                apt update -y && apt install -y "$package"
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y "$package"
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "$package"
            elif command -v apk >/dev/null 2>&1; then
                apk add "$package"
            elif command -v pacman >/dev/null 2>&1; then
                pacman -S --noconfirm "$package"
            elif command -v zypper >/dev/null 2>&1; then
                zypper install -y "$package"
            else
                echo "未知的包管理器，请手动安装: $package"
                return 1
            fi
        else
            echo -e "${gl_lv}$package 已经安装${gl_bai}"
        fi
    done
}

if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 权限运行"
    exit 1
fi

# ===== Hermes: 应用端口白名单管理（990） =====
KJ_APP_ALLOW_REMARK_FILE="/etc/kj_app_port_allow_remarks"

kj_app_sort_ports_csv() {
	local ports="$1"
	echo "$ports" | tr ',' '\n' | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {print $1}' | sort -n -u | paste -sd, -
}

kj_app_ports_contains() {
	local csv="$1"
	local port="$2"
	case ",$csv," in *",$port,"*) return 0 ;; esac
	return 1
}

kj_app_validate_ports_csv() {
	local ports="$1"
	[ -n "$ports" ] || return 1
	echo "$ports" | grep -Eq '^[0-9]+(,[0-9]+)*$' || return 1
	local p
	for p in ${ports//,/ }; do
		[ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null || return 1
	done
	return 0
}

kj_app_ssh_ports_detect() {
	{
		[ -f /etc/ssh/sshd_config ] && awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}' /etc/ssh/sshd_config 2>/dev/null
		command -v ss >/dev/null 2>&1 && ss -ltnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); p=a[length(a)]; if (p ~ /^[0-9]+$/) print p}'
		[ -n "${SSH_CONNECTION:-}" ] && echo "$SSH_CONNECTION" | awk '{print $4}'
		echo 22
	} | awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 {print $1}' | sort -n -u
}

kj_app_protected_allow_ports() {
	{
		kj_app_ssh_ports_detect
		echo 80
		echo 443
	} | awk '/^[0-9]+$/ {print}' | sort -n -u
}

kj_app_prompt_allow_remark() {
	local remark
	while true; do
		read -e -p "请输入备注: " remark
		remark=$(echo "$remark" | tr '|' ' ' | xargs 2>/dev/null)
		if [ -n "$remark" ]; then
			echo "$remark"
			return 0
		fi
		echo -e "${gl_hong}备注不能为空${gl_bai}" >&2
	done
}

kj_app_allow_file_init_default() {
	mkdir -p "$(dirname "$KJ_APP_ALLOW_REMARK_FILE")"
	if [ -s "$KJ_APP_ALLOW_REMARK_FILE" ]; then
		return 0
	fi
	: > "$KJ_APP_ALLOW_REMARK_FILE"
	local p
	for p in $(kj_app_protected_allow_ports); do
		echo "默认|$p" >> "$KJ_APP_ALLOW_REMARK_FILE"
	done
}

kj_app_all_allowed_ports() {
	[ -f "$KJ_APP_ALLOW_REMARK_FILE" ] || return 0
	awk -F'|' '{gsub(/,/,"\n",$2); print $2}' "$KJ_APP_ALLOW_REMARK_FILE" 2>/dev/null | awk '/^[0-9]+$/ {print}' | sort -n -u | paste -sd, -
}

kj_app_save_iptables_rules() {
	mkdir -p /etc/iptables
	iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
	command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
	if command -v crontab >/dev/null 2>&1; then
		(
			crontab -l 2>/dev/null \
				| grep -v 'iptables-restore < /etc/iptables/rules.v4' \
				| grep -v 'ip6tables-restore < /etc/iptables/rules.v6' \
				| grep -v 'ip6tables-restore < /etc/iptables/rules$' \
				| grep -v '^# 990应用 端口白名单（勿删）$' \
			| grep -v '^# 990应用 安装的应用以及应用端口封禁（勿删）$' \
				| grep -v '^# 990应用 安装的应用以及应用端口封禁（勿删）$'
			echo '# 990应用 端口白名单（勿删）'
			echo '@reboot iptables-restore < /etc/iptables/rules.v4'
			echo '@reboot ip6tables-restore < /etc/iptables/rules.v6'
		) | crontab - 2>/dev/null || true
	fi
}

kj_app_allow_remove_ports() {
	local ports="$1"
	local quiet="$2"
	ports=$(kj_app_sort_ports_csv "$ports")
	[ -z "$ports" ] && return 0
	[ -f "$KJ_APP_ALLOW_REMARK_FILE" ] || return 0
	local tmp p old_remark old_ports keep_ports protected skipped=""
	tmp=$(mktemp)
	protected=",$(kj_app_protected_allow_ports | paste -sd, -),"
	while IFS='|' read -r old_remark old_ports; do
		[ -z "$old_remark" ] && continue
		keep_ports=""
		for p in ${old_ports//,/ }; do
			[ -z "$p" ] && continue
			if kj_app_ports_contains "$ports" "$p"; then
				# SSH/80/443 只保护“默认”项；如果用户误把它们加进自定义备注，删除该备注时不要残留重复项。
				if [ "$old_remark" = "默认" ] && kj_app_ports_contains "$protected" "$p"; then
					keep_ports="${keep_ports:+$keep_ports,}$p"
					skipped="${skipped:+$skipped,}$p"
				fi
				continue
			fi
			keep_ports="${keep_ports:+$keep_ports,}$p"
		done
		keep_ports=$(kj_app_sort_ports_csv "$keep_ports")
		[ -n "$keep_ports" ] && echo "$old_remark|$keep_ports" >> "$tmp"
	done < "$KJ_APP_ALLOW_REMARK_FILE"
	mv "$tmp" "$KJ_APP_ALLOW_REMARK_FILE"
	if [ -n "$skipped" ] && [ "$quiet" != "quiet" ]; then
		skipped=$(kj_app_sort_ports_csv "$skipped")
		local sshp
		for sshp in $(kj_app_ssh_ports_detect); do
			kj_app_ports_contains "$skipped" "$sshp" && echo -e "${gl_hong}检测到SSH端口为${sshp}，不允许阻止${gl_bai}"
		done
		if kj_app_ports_contains "$skipped" "80" || kj_app_ports_contains "$skipped" "443"; then
			if [ "$skipped" = "80" ] || [ "$skipped" = "443" ] || [ "$skipped" = "80,443" ]; then
				echo -e "${gl_hong}80/443为默认放行端口，不允许阻止${gl_bai}"
			fi
		fi
	fi
}

kj_app_allow_firewall_active() {
	iptables -S KJ_APP_ALLOW >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -q -- '-j KJ_APP_ALLOW'
}

kj_app_allow_repair_reboot_cron() {
	command -v crontab >/dev/null 2>&1 || return 0
	mkdir -p /etc/iptables
	(
		crontab -l 2>/dev/null \
			| grep -v 'iptables-restore < /etc/iptables/rules.v4' \
			| grep -v 'ip6tables-restore < /etc/iptables/rules.v6' \
			| grep -v 'ip6tables-restore < /etc/iptables/rules$' \
			| grep -v '^# 990应用 端口白名单（勿删）$'
		echo '# 990应用 端口白名单（勿删）'
		echo '@reboot iptables-restore < /etc/iptables/rules.v4'
		echo '@reboot ip6tables-restore < /etc/iptables/rules.v6'
	) | crontab - 2>/dev/null || true
}

kj_app_allow_add_entry() {
	local remark="$1"
	local ports="$2"
	ports=$(kj_app_sort_ports_csv "$ports")
	[ -z "$remark" ] || [ -z "$ports" ] && return 1
	mkdir -p "$(dirname "$KJ_APP_ALLOW_REMARK_FILE")"
	kj_app_allow_remove_ports "$ports" "quiet"
	echo "$remark|$ports" >> "$KJ_APP_ALLOW_REMARK_FILE"
}

kj_app_apply_allow_firewall() {
	install iptables
	local allowed_ports p
	allowed_ports=$(kj_app_all_allowed_ports)

	iptables -N KJ_APP_ALLOW 2>/dev/null || true
	iptables -F KJ_APP_ALLOW 2>/dev/null || true
	iptables -C INPUT -j KJ_APP_ALLOW 2>/dev/null || iptables -I INPUT 1 -j KJ_APP_ALLOW
	iptables -A KJ_APP_ALLOW -i lo -j ACCEPT
	iptables -A KJ_APP_ALLOW -m state --state ESTABLISHED,RELATED -j ACCEPT
	iptables -A KJ_APP_ALLOW -i docker0 -j ACCEPT
	iptables -A KJ_APP_ALLOW -i br+ -j ACCEPT
	for p in ${allowed_ports//,/ }; do
		[ -z "$p" ] && continue
		iptables -A KJ_APP_ALLOW -p tcp --dport "$p" -j ACCEPT
		iptables -A KJ_APP_ALLOW -p udp --dport "$p" -j ACCEPT
	done
	iptables -A KJ_APP_ALLOW -p tcp -j DROP
	iptables -A KJ_APP_ALLOW -p udp -j DROP
	iptables -A KJ_APP_ALLOW -j RETURN

	iptables -N DOCKER-USER 2>/dev/null || true
	iptables -N KJ_APP_DOCKER_ALLOW 2>/dev/null || true
	iptables -F KJ_APP_DOCKER_ALLOW 2>/dev/null || true
	iptables -C DOCKER-USER -j KJ_APP_DOCKER_ALLOW 2>/dev/null || iptables -I DOCKER-USER 1 -j KJ_APP_DOCKER_ALLOW
	iptables -A KJ_APP_DOCKER_ALLOW -i br+ -j ACCEPT
	iptables -A KJ_APP_DOCKER_ALLOW -i docker0 -j ACCEPT
	iptables -A KJ_APP_DOCKER_ALLOW -m state --state ESTABLISHED,RELATED -j ACCEPT
	for p in ${allowed_ports//,/ }; do
		[ -z "$p" ] && continue
		iptables -A KJ_APP_DOCKER_ALLOW -p tcp -m conntrack --ctorigdstport "$p" -j ACCEPT
		iptables -A KJ_APP_DOCKER_ALLOW -p udp -m conntrack --ctorigdstport "$p" -j ACCEPT
	done
	iptables -A KJ_APP_DOCKER_ALLOW -p tcp -j DROP
	iptables -A KJ_APP_DOCKER_ALLOW -p udp -j DROP
	iptables -A KJ_APP_DOCKER_ALLOW -j RETURN

	if command -v ip6tables >/dev/null 2>&1; then
		ip6tables -N KJ_APP_ALLOW 2>/dev/null || true
		ip6tables -F KJ_APP_ALLOW 2>/dev/null || true
		ip6tables -C INPUT -j KJ_APP_ALLOW 2>/dev/null || ip6tables -I INPUT 1 -j KJ_APP_ALLOW
		ip6tables -A KJ_APP_ALLOW -i lo -j ACCEPT
		ip6tables -A KJ_APP_ALLOW -m state --state ESTABLISHED,RELATED -j ACCEPT
		for p in ${allowed_ports//,/ }; do
			[ -z "$p" ] && continue
			ip6tables -A KJ_APP_ALLOW -p tcp --dport "$p" -j ACCEPT
			ip6tables -A KJ_APP_ALLOW -p udp --dport "$p" -j ACCEPT
		done
		ip6tables -A KJ_APP_ALLOW -p tcp -j DROP
		ip6tables -A KJ_APP_ALLOW -p udp -j DROP
		ip6tables -A KJ_APP_ALLOW -j RETURN
	fi
	kj_app_save_iptables_rules
}

kj_app_show_allow_list() {
	kj_app_allow_file_init_default
	echo -e "${gl_hong}=============================================${gl_bai}"
	echo -e "${gl_lv}允许公网IP+端口访问${gl_bai}"
	echo "备注名  端口"
	local tmp line_no=0
	tmp=$(mktemp)
	while IFS='|' read -r remark ports; do
		[ -z "$remark" ] && continue
		ports=$(kj_app_sort_ports_csv "$ports")
		[ -z "$ports" ] && continue
		printf '%s|%s|%s\n' "${ports%%,*}" "$remark" "$ports" >> "$tmp"
	done < "$KJ_APP_ALLOW_REMARK_FILE"
	if [ -s "$tmp" ]; then
		sort -n -t'|' -k1,1 "$tmp" | while IFS='|' read -r min_port remark ports; do
			line_no=$((line_no + 1))
			printf "%s. %-14s %s\n" "$line_no" "$remark" "$ports"
		done
	fi
	rm -f "$tmp"
	echo -e "${gl_hong}=============================================${gl_bai}"
}

kj_app_allow_menu_add() {
	local remark ports
	remark=$(kj_app_prompt_allow_remark)
	read -e -p "请输入需要放行的端口，多个端口用英文逗号分隔:" ports
	ports=$(echo "$ports" | tr -d ' ')
	if ! kj_app_validate_ports_csv "$ports"; then
		echo -e "${gl_hong}端口格式无效，请输入 1-65535，多个端口用英文逗号分隔${gl_bai}"
		return 1
	fi
	kj_app_allow_add_entry "$remark" "$ports"
	kj_app_apply_allow_firewall
	echo "放行成功"
}

kj_app_allow_menu_remove() {
	clear
	kj_app_allow_file_init_default
	local tmp line_no=0 choice ports
	tmp=$(mktemp)
	echo -e "${gl_hong}=============================================${gl_bai}"
	echo -e "${gl_lv}允许公网IP+端口访问${gl_bai}"
	echo "备注名  端口"
	while IFS='|' read -r remark row_ports; do
		[ -z "$remark" ] && continue
		row_ports=$(kj_app_sort_ports_csv "$row_ports")
		[ -z "$row_ports" ] && continue
		printf '%s|%s|%s\n' "${row_ports%%,*}" "$remark" "$row_ports" >> "$tmp"
	done < "$KJ_APP_ALLOW_REMARK_FILE"
	if [ -s "$tmp" ]; then
		sort -n -t'|' -k1,1 "$tmp" | while IFS='|' read -r min_port remark row_ports; do
			line_no=$((line_no + 1))
			printf "%s|%s|%s\n" "$line_no" "$remark" "$row_ports"
		done > "${tmp}.sorted"
		while IFS='|' read -r n remark row_ports; do
			printf "%s. %-14s %s\n" "$n" "$remark" "$row_ports"
		done < "${tmp}.sorted"
	fi
	echo -e "${gl_hong}=============================================${gl_bai}"
	read -e -p "输入需要封禁的序号（回车返回上一级）: " choice
	[ -z "$choice" ] && { rm -f "$tmp" "${tmp}.sorted"; return 0; }
	[[ "$choice" =~ ^[0-9]+$ ]] || { rm -f "$tmp" "${tmp}.sorted"; echo "无效选择"; return 1; }
	ports=$(awk -F'|' -v n="$choice" '$1==n {print $3; exit}' "${tmp}.sorted" 2>/dev/null)
	rm -f "$tmp" "${tmp}.sorted"
	[ -n "$ports" ] || { echo "无效选择"; return 1; }
	kj_app_allow_remove_ports "$ports"
	kj_app_apply_allow_firewall
	echo "阻止成功"
}

kj_app_allow_reset_default() {
	local extra_ports="$1"
	local extra_remark="${2:-手动}"
	local confirm default_ports p
	default_ports=$(kj_app_protected_allow_ports | paste -sd, -)
	echo "检测到SSH端口: $(kj_app_ssh_ports_detect | paste -sd, -)"
	echo "将默认允许: ${default_ports//,/ }"
	[ -n "$extra_ports" ] && echo "额外允许: ${extra_ports//,/ }"
	read -e -p "确认启用全部阻止模式 [确认请输入yes，默认n]: " confirm
	[ "$confirm" = "yes" ] || { echo "已取消"; return 1; }
	mkdir -p "$(dirname "$KJ_APP_ALLOW_REMARK_FILE")"
	: > "$KJ_APP_ALLOW_REMARK_FILE"
	for p in ${default_ports//,/ }; do
		[ -n "$p" ] && echo "默认|$p" >> "$KJ_APP_ALLOW_REMARK_FILE"
	done
	[ -n "$extra_ports" ] && kj_app_allow_add_entry "$extra_remark" "$extra_ports"
	kj_app_apply_allow_firewall
	echo "全部阻止模式已启用"
}

linux_app_ports() {
	while true; do
		clear
		send_stats "安装的应用端口"
		kj_app_allow_file_init_default
		if ! kj_app_allow_firewall_active; then
			echo -e "${gl_huang}检测到当前还没有启用端口白名单模式。${gl_bai}"
			echo -e "${gl_huang}启用后只允许列表中的公网IP+端口访问，其它端口默认阻止。${gl_bai}"
			echo -e "${gl_huang}建议先选择 3. 全部阻止，确认默认放行 SSH/80/443。${gl_bai}"
			echo ""
		else
			kj_app_allow_repair_reboot_cron
		fi
		echo -e "${gl_kjlan}安装的应用端口${gl_bai}"
		kj_app_show_allow_list
		echo "------------------------"
		echo -e "1. ${gl_lv}放行端口${gl_bai}"
		echo -e "2. ${gl_hong}阻止端口${gl_bai}"
		echo -e "3. ${gl_huang}全部阻止${gl_bai}"
		echo "------------------------"
		echo "0. 返回上一级"
		echo "------------------------"
		read -e -p "请输入序号进入应用管理: " app_choice
		case "$app_choice" in
			1) kj_app_allow_menu_add; break_end ;;
			2) kj_app_allow_menu_remove; break_end ;;
			3)
				local extra_ports extra_remark
				echo "需要手动放行的端口，多个端口用英文逗号分隔"
				read -e -p "请输入端口（可留空）: " extra_ports
				extra_ports=$(echo "$extra_ports" | tr -d ' ')
				if [ -n "$extra_ports" ]; then
					if ! kj_app_validate_ports_csv "$extra_ports"; then
						echo -e "${gl_hong}端口格式无效，请输入 1-65535，多个端口用英文逗号分隔${gl_bai}"
						break_end
						continue
					fi
					while [ -z "$extra_remark" ]; do
						read -e -p "请输入备注: " extra_remark
						extra_remark=$(echo "$extra_remark" | tr '|' ' ' | xargs 2>/dev/null)
						[ -z "$extra_remark" ] && echo -e "${gl_hong}备注不能为空${gl_bai}"
					done
				fi
				kj_app_allow_reset_default "$extra_ports" "$extra_remark"
				break_end
				;;
			0) break ;;
			*) echo "无效的输入!"; break_end ;;
		esac
	done
}
# ===== Hermes: 应用端口白名单管理（990）结束 =====

linux_app_ports
