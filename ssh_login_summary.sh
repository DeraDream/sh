#!/bin/bash

set -u

SUMMARY_SCRIPT="/etc/profile.d/kejilion-login-summary.sh"
STATE_DIR="/var/lib/kejilion-login-summary"
MOTD_BACKUP="$STATE_DIR/motd.backup"
MOTD_MISSING="$STATE_DIR/motd.was-missing"
MOTD_EXECUTABLES="$STATE_DIR/update-motd-executables"
MOTD_NEWS_BACKUP="$STATE_DIR/motd-news.backup"

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "该功能需要 root 用户运行。"
		exit 1
	fi
}

disable_default_motd() {
	mkdir -p "$STATE_DIR"

	if [ ! -e "$MOTD_BACKUP" ] && [ ! -e "$MOTD_MISSING" ]; then
		if [ -e /etc/motd ]; then
			cp -p /etc/motd "$MOTD_BACKUP"
		else
			: > "$MOTD_MISSING"
		fi
	fi

	if [ ! -e "$MOTD_EXECUTABLES" ]; then
		: > "$MOTD_EXECUTABLES"
		if [ -d /etc/update-motd.d ]; then
			for motd_script in /etc/update-motd.d/*; do
				[ -f "$motd_script" ] || continue
				[ -x "$motd_script" ] && basename "$motd_script" >> "$MOTD_EXECUTABLES"
			done
		fi
	fi

	: > /etc/motd
	[ -e /run/motd.dynamic ] && : > /run/motd.dynamic

	if [ -d /etc/update-motd.d ]; then
		for motd_script in /etc/update-motd.d/*; do
			[ -f "$motd_script" ] || continue
			chmod a-x "$motd_script"
		done
	fi

	if [ -f /etc/default/motd-news ]; then
		[ -e "$MOTD_NEWS_BACKUP" ] || cp -p /etc/default/motd-news "$MOTD_NEWS_BACKUP"
		if grep -q '^ENABLED=' /etc/default/motd-news; then
			sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
		else
			echo 'ENABLED=0' >> /etc/default/motd-news
		fi
	fi
}

install_summary() {
	disable_default_motd

	cat > "$SUMMARY_SCRIPT" <<'SUMMARY_EOF'
#!/bin/sh

case $- in
	*i*) ;;
	*) return ;;
esac

[ -n "${SSH_CONNECTION:-}" ] || return

value_or_default() {
	if [ -n "${1:-}" ]; then
		printf '%s' "$1"
	else
		printf '%s' "未检测到"
	fi
}

cpu_usage_value() {
	read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 _ < /proc/stat
	total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
	idle_total1=$((idle1 + iowait1))
	sleep 1
	read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ < /proc/stat
	total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
	idle_total2=$((idle2 + iowait2))
	total_delta=$((total2 - total1))
	idle_delta=$((idle_total2 - idle_total1))
	if [ "$total_delta" -gt 0 ]; then
		printf '%s%%' "$(((total_delta - idle_delta) * 100 / total_delta))"
	else
		printf '%s' "0%"
	fi
}

hostname_value=$(hostname 2>/dev/null)
cpu_arch=$(uname -m 2>/dev/null)
cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
cpu_model=$(sed -n 's/^[Mm]odel name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)
[ -n "$cpu_model" ] || cpu_model=$(sed -n 's/^Hardware[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -n 1)
cpu_usage=$(cpu_usage_value)

memory_info=$(free -m 2>/dev/null | awk 'NR==2 {
	total=$2
	used=$3
	available=$7
	if (available == "") available=$4
	percent=(total > 0 ? used * 100 / total : 0)
	printf "%sM / 已用%sM / 可用%sM / 使用率%.1f%%", total, used, available, percent
}')
swap_info=$(free -m 2>/dev/null | awk 'NR==3 {
	total=$2
	used=$3
	percent=(total > 0 ? used * 100 / total : 0)
	printf "%sM / 已用%sM / 使用率%.1f%%", total, used, percent
}')
disk_info=$(df -hP / 2>/dev/null | awk 'NR==2 {
	printf "%s（已用 %s，可用 %s，使用率 %s）", $2, $3, $4, $5
}')

public_ipv4=$(curl -4 -fsS --max-time 4 https://api.ip.sb/ip 2>/dev/null | tr -d '\r\n')
public_ipv6=$(curl -6 -fsS --max-time 4 https://api.ip.sb/ip 2>/dev/null | tr -d '\r\n')
private_ipv4=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4, addr, "/"); print addr[1]}')
private_ipv6=$(ip -6 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4, addr, "/"); print addr[1]}')

printf '%s\n' "========== VPS 摘要 =========="
printf '主机名称：%s\n' "$(value_or_default "$hostname_value")"
printf 'CPU架构：%s\n' "$(value_or_default "$cpu_arch")"
printf 'CPU线程：%s\n' "$(value_or_default "$cpu_cores")"
printf 'CPU型号：%s\n' "$(value_or_default "$cpu_model")"
printf 'CPU使用率：%s\n' "$cpu_usage"
printf '内存：%s\n' "$(value_or_default "$memory_info")"
printf '交换空间：%s\n' "$(value_or_default "$swap_info")"
printf '系统盘：%s\n' "$(value_or_default "$disk_info")"
printf '公网IPv4：%s\n' "$(value_or_default "$public_ipv4")"
printf '公网IPv6：%s\n' "$(value_or_default "$public_ipv6")"
printf '内网IPv4：%s\n' "$(value_or_default "$private_ipv4")"
printf '内网IPv6：%s\n' "$(value_or_default "$private_ipv6")"
printf '%s\n' "=============================="
SUMMARY_EOF

	chmod 644 "$SUMMARY_SCRIPT"
	echo "SSH 登录摘要已启用或更新。"
	echo "系统默认 MOTD 已停用；OpenSSH 的 Last login 保持不变。"
	echo "重新建立 SSH 连接后即可看到效果。"
}

restore_default_motd() {
	rm -f "$SUMMARY_SCRIPT"

	if [ -f "$MOTD_BACKUP" ]; then
		cp -p "$MOTD_BACKUP" /etc/motd
	elif [ -f "$MOTD_MISSING" ]; then
		rm -f /etc/motd
	fi

	if [ -f "$MOTD_EXECUTABLES" ] && [ -d /etc/update-motd.d ]; then
		while IFS= read -r script_name; do
			[ -n "$script_name" ] || continue
			[ -f "/etc/update-motd.d/$script_name" ] && chmod a+x "/etc/update-motd.d/$script_name"
		done < "$MOTD_EXECUTABLES"
	fi

	if [ -f "$MOTD_NEWS_BACKUP" ]; then
		cp -p "$MOTD_NEWS_BACKUP" /etc/default/motd-news
	fi

	rm -rf "$STATE_DIR"
	echo "SSH 登录摘要已关闭，系统默认 MOTD 已恢复。"
	echo "OpenSSH 的 Last login 保持不变。"
}

require_root

while true; do
	clear
	echo "SSH 登录摘要管理"
	echo "------------------------"
	echo "1. 启用或更新登录摘要"
	echo "2. 关闭摘要并恢复系统默认 MOTD"
	echo "0. 返回"
	echo "------------------------"
	read -r -p "请输入你的选择: " choice

	case "$choice" in
		1)
			install_summary
			read -r -p "按回车键继续..." _
			;;
		2)
			restore_default_motd
			read -r -p "按回车键继续..." _
			;;
		0)
			exit 0
			;;
		*)
			echo "无效的输入。"
			sleep 1
			;;
	esac
done
