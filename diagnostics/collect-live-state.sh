#!/bin/sh
set -eu

prefix=${1:-/tmp/k1plus-live-state}
timestamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || date)
out_dir="${prefix}-${timestamp}"
archive="${out_dir}.tar.gz"

mkdir -p "$out_dir"

capture() {
	name=$1
	shift
	"$@" >"$out_dir/$name.txt" 2>&1 || true
}

capture_sh() {
	name=$1
	shift
	sh -c "$*" >"$out_dir/$name.txt" 2>&1 || true
}

copy_if_exists() {
	src=$1
	dst=$2
	if [ -e "$src" ]; then
		cp -a "$src" "$out_dir/$dst" 2>/dev/null || true
	fi
}

capture uname uname -a
capture date date
capture uptime uptime
capture cmdline cat /proc/cmdline
capture mounts mount
capture df df -h
capture dmesg dmesg
capture logread logread
capture lsmod lsmod
capture ip_link ip -br link
capture ip_addr ip -br addr
capture ip_route ip route
capture ip_rule ip rule
capture bridge_link bridge link
capture bridge_vlan bridge vlan
capture ubus_system_board ubus call system board
capture ubus_network_dump ubus call network.interface dump
capture ubus_wireless_status ubus call network.wireless status
capture ifstatus_lan ifstatus lan
capture ifstatus_wan ifstatus wan
capture ifstatus_wan6 ifstatus wan6
capture iw_dev iw dev
capture iw_phy iw phy
capture rfkill rfkill list
capture opkg_list_installed opkg list-installed
capture ps ps w

capture_sh sys_class_ieee80211 "find /sys/class/ieee80211 -maxdepth 3 -type l -o -type f 2>/dev/null | sort"
capture_sh sys_bus_sdio "for d in /sys/bus/sdio/devices/*; do [ -d \"\$d\" ] || continue; echo \"===== \$d =====\"; [ -f \"\$d/uevent\" ] && cat \"\$d/uevent\"; done"
capture_sh sys_bus_platform_wireless "find /sys/devices/platform -maxdepth 5 \\( -iname '*wifi*' -o -iname '*mmc*' -o -iname '*rtl8189*' \\) 2>/dev/null | sort"

copy_if_exists /etc/openwrt_release openwrt_release
copy_if_exists /etc/os-release os-release
copy_if_exists /etc/board.json board.json
copy_if_exists /etc/config/network config.network
copy_if_exists /etc/config/wireless config.wireless
copy_if_exists /etc/config/system config.system
copy_if_exists /etc/config/firewall config.firewall
copy_if_exists /etc/config/dhcp config.dhcp
copy_if_exists /etc/inittab inittab
copy_if_exists /etc/rc.local rc.local
copy_if_exists /etc/modules.d modules.d
copy_if_exists /etc/hotplug.d hotplug.d
copy_if_exists /lib/netifd netifd
copy_if_exists /etc/uci-defaults uci-defaults
copy_if_exists /sys/firmware/devicetree/base devicetree-base

if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz >"$out_dir/kernel.config" 2>/dev/null || true
fi

if command -v fw_printenv >/dev/null 2>&1; then
	capture fw_printenv fw_printenv
fi

tar -C "$(dirname "$out_dir")" -czf "$archive" "$(basename "$out_dir")"
echo "$archive"
