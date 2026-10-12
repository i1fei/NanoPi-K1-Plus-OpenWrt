#!/bin/sh
set -eu

root=${1:?rootfs is required}
report=${2:?report path is required}
script=/etc/uci-defaults/99-k1-plus-wifi-release-v1
mounted=0

record() {
	printf '%s\n' "$1" >> "$report"
}

run_firstboot() {
	sudo -n chroot "$root" /bin/sh -c '. /lib/functions/system.sh; . "$1"' sh "$script"
}

run_firstboot_checked() {
	firstboot_log=$(mktemp)
	if run_firstboot >"$firstboot_log" 2>&1; then
		rm -f "$firstboot_log"
		return 0
	fi
	# Preserve the reason in CI evidence, but never emit a generated credential.
	sed -E 's/(Password: ).*/\1[redacted]/' "$firstboot_log" >> "$report"
	if sudo -n test -f "$root/root/FIRSTBOOT-FAILED.txt"; then
		record 'FIRSTBOOT_FAILURE_MARKER_BEGIN'
		sudo -n sed -E 's/(Password: ).*/\1[redacted]/' \
			"$root/root/FIRSTBOOT-FAILED.txt" >> "$report"
		record 'FIRSTBOOT_FAILURE_MARKER_END'
	fi
	rm -f "$firstboot_log"
	return 1
}

cleanup() {
	if [ "$mounted" -eq 1 ]; then
		sudo -n umount "$root/dev" || true
	fi
}
trap cleanup EXIT INT HUP TERM
: > "$report"

[ -x "$root$script" ] || { record 'FIRSTBOOT_SCRIPT=FAIL'; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || {
	record 'QEMU_AARCH64_BINFMT=SKIPPED(environment unavailable)'
	exit 2
}
record 'QEMU_AARCH64_BINFMT=PASS'

sudo -n mkdir -p "$root/dev"
sudo -n mount --bind /dev "$root/dev"
mounted=1
# OpenWrt creates the UCI lock directory during early boot.  The extracted
# squashfs is tested without init/procd, so initialize both layouts explicitly:
# current rootfs uses /var/lock, while older layouts may resolve it via /tmp.
sudo -n mkdir -p "$root/var/lock" "$root/tmp/lock" "$root/tmp/sysinfo" "$root/sys/class/net/eth0"
record 'DRYRUN_OPENWRT_RUNTIME_DIRS=PASS'
printf '%s\n' friendlyelec,nanopi-k1-plus | sudo -n tee "$root/tmp/sysinfo/board_name" >/dev/null
printf '%s\n' 02:11:22:33:44:55 | sudo -n tee "$root/sys/class/net/eth0/address" >/dev/null

for path in \
	$script \
	/etc/init.d/k1plus-hw-watchdog \
	/etc/init.d/k1plus-network \
	/etc/init.d/k1plus-wifi-watchdog \
	/etc/profile.d/99-k1-plus-wifi.sh \
	/usr/libexec/k1plus-dhcp-event \
	/usr/sbin/k1plus-network-mode \
	/usr/sbin/k1plus-wifi-watchdog; do
	if sudo -n chroot "$root" /bin/sh -n "$path"; then
		record "ASH_SYNTAX_${path#/}=PASS"
	else
		record "ASH_SYNTAX_${path#/}=FAIL"
		exit 1
	fi
done

if run_firstboot_checked; then
	record 'FIRSTBOOT_SUCCESS_RUN=PASS'
else
	record 'FIRSTBOOT_SUCCESS_RUN=FAIL'
	exit 1
fi

for check in \
	"system.@system[0].hostname=nanopi-k1plus" \
	"network.lan.device=br-lan" \
	"network.lan.proto=none" \
	"network.br_lan.ports=eth0" \
	"dhcp.lan.ignore=1" \
	"wireless.default_radio0.network=lan" \
	"wireless.default_radio0.mode=ap" \
	"wireless.default_radio0.disabled=0"; do
	key=${check%%=*}
	expected=${check#*=}
	actual=$(sudo -n chroot "$root" /sbin/uci -q get "$key")
	if [ "$actual" = "$expected" ]; then
		record "DRYRUN_${key}=PASS"
	else
		record "DRYRUN_${key}=FAIL"
		exit 1
	fi
done

[ -e "$root/etc/wifi-release-done" ] || { record 'DRYRUN_DONE_MARKER=FAIL'; exit 1; }
if sudo -n test -e "$root/root/FIRSTBOOT-FAILED.txt"; then
	record 'DRYRUN_FAILURE_MARKER_ABSENT=FAIL'
	exit 1
fi
[ "$(sudo -n stat -c %a "$root/root/WIFI-PASSWORD.txt")" = 600 ] || { record 'DRYRUN_CREDENTIAL_MODE=FAIL'; exit 1; }
sudo -n chroot "$root" /usr/bin/awk -F ': ' \
	'/^Password:/ { valid = (length($2) == 12) } END { exit !valid }' \
	/root/WIFI-PASSWORD.txt || { record 'DRYRUN_CREDENTIAL_LENGTH=FAIL'; exit 1; }
record 'DRYRUN_DONE_MARKER=PASS'
record 'DRYRUN_FAILURE_MARKER_ABSENT=PASS'
record 'DRYRUN_CREDENTIAL_MODE=PASS'
record 'DRYRUN_CREDENTIAL_LENGTH=PASS'

# Exercise the runner contract: failures 1 and 2 retain the script, failure 3 is final.
sudo -n rm -f "$root/etc/wifi-release-done" "$root/etc/wifi-release-attempts" \
	"$root/root/FIRSTBOOT-FAILED.txt" "$root/root/WIFI-PASSWORD.txt" \
	"$root/sys/class/net/eth0/address"
retry=1
while [ "$retry" -le 3 ]; do
	set +e
	run_firstboot >/dev/null 2>&1
	status=$?
	set -e
	if [ "$retry" -lt 3 ] && [ "$status" -ne 0 ]; then
		[ "$(cat "$root/etc/wifi-release-attempts")" = "$retry" ] || {
			record "DRYRUN_RETRY_${retry}_COUNTER=FAIL"
			exit 1
		}
		sudo -n test -e "$root/root/FIRSTBOOT-FAILED.txt" || {
			record "DRYRUN_RETRY_${retry}_MARKER=FAIL"
			exit 1
		}
		record "DRYRUN_RETRY_${retry}_RETAINED=PASS"
	elif [ "$retry" -eq 3 ] && [ "$status" -eq 0 ]; then
		[ "$(cat "$root/etc/wifi-release-attempts")" = 3 ] || {
			record 'DRYRUN_RETRY_3_COUNTER=FAIL'
			exit 1
		}
		sudo -n rm -f "$root$script"
		[ ! -e "$root$script" ] || { record 'DRYRUN_RETRY_3_REMOVED=FAIL'; exit 1; }
		record 'DRYRUN_RETRY_3_LIMIT=PASS'
		record 'DRYRUN_RETRY_3_REMOVED=PASS'
	else
		record "DRYRUN_RETRY_${retry}=FAIL"
		exit 1
	fi
	retry=$((retry + 1))
done
sudo -n test -e "$root/root/FIRSTBOOT-FAILED.txt" || { record 'DRYRUN_FAILURE_MARKER=FAIL'; exit 1; }
[ ! -e "$root/etc/wifi-release-done" ] || { record 'DRYRUN_FAILED_DONE_MARKER_ABSENT=FAIL'; exit 1; }
record 'DRYRUN_FAILURE_MARKER=PASS'
record 'DRYRUN_FAILED_DONE_MARKER_ABSENT=PASS'
record 'FIRSTBOOT_DRY_RUN=PASS'
