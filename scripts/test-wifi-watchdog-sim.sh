#!/bin/sh
# Host-side simulation for the merged watchdog and collector.
# Run under Git Bash or WSL:
#   sh scripts/test-wifi-watchdog-sim.sh <watchdog> <collector>
set -u

WATCHDOG_SCRIPT="${1:?watchdog script path is required}"
COLLECTOR_SCRIPT="${2:?collector script path is required}"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
fail=0

ck() {
	if eval "$2"; then
		echo "PASS  $1"
	else
		echo "FAIL  $1"
		fail=1
	fi
}

mkdir -p "$T/bin" "$T/cfg"
printf '%s\n' \
	'phy#0' \
	"$(printf '\tInterface phy0-ap0')" \
	"$(printf '\t\tifindex 6')" \
	"$(printf '\t\twdev 0x3')" \
	"$(printf '\t\taddr 7c:c7:09:a5:47:ed')" \
	"$(printf '\t\tssid NanoPi-K1-Plus')" \
	"$(printf '\t\ttype AP')" \
	"$(printf '\t\ttxpower 16.00 dBm')" > "$T/iw-dev-ap.txt"
printf '%s\n' \
	"$(printf '\tInterface phy0-ap0')" \
	"$(printf '\t\tifindex 6')" \
	"$(printf '\t\twdev 0x3')" \
	"$(printf '\t\ttype AP')" > "$T/iw-info-ap.txt"
printf '%s\n' \
	'phy#0' \
	"$(printf '\tInterface wlan0')" \
	"$(printf '\t\tifindex 3')" \
	"$(printf '\t\ttype managed')" \
	'phy#1' \
	"$(printf '\tInterface phy1-ap0')" \
	"$(printf '\t\tifindex 8')" \
	"$(printf '\t\ttype AP')" > "$T/iw-dev-multi.txt"
printf '%s\n' \
	"$(printf '\tInterface phy0-ap0')" \
	"$(printf '\t\tifindex 6')" \
	"$(printf '\t\ttype managed')" > "$T/iw-info-managed.txt"
: > "$T/iw-dev-empty.txt"
cat > "$T/lib-functions.sh" <<'EOF'
config_load() { :; }
config_get() {
	case "$3" in
		interval) eval "$1=${WD_TEST_INTERVAL:-1}" ;;
		failure_threshold) eval "$1=${WD_TEST_THRESHOLD:-3}" ;;
		command_timeout) eval "$1=${WD_TEST_COMMAND_TIMEOUT:-5}" ;;
		reload_grace) eval "$1=${WD_TEST_RELOAD_GRACE:-1}" ;;
		recovery_window) eval "$1=${WD_TEST_RECOVERY_WINDOW:-3600}" ;;
		max_recoveries) eval "$1=${WD_TEST_MAX_RECOVERIES:-3}" ;;
		reboot_cooldown) eval "$1=${WD_TEST_REBOOT_COOLDOWN:-3600}" ;;
		*) eval "$1=" ;;
	esac
}
EOF

cat > "$T/bin/pidof" <<'EOF'
#!/bin/sh
[ "$1" = hostapd ] && exit 0
exit 1
EOF

cat > "$T/bin/iw" <<'EOF'
#!/bin/sh
if [ "$1" = dev ] && [ "$#" -eq 1 ]; then
	if [ -n "$WD_IW_DEV_FIXTURE" ]; then
		cat "$WD_IW_DEV_FIXTURE"
	elif [ -d "$WD_SYSNET/phy0-ap0" ]; then
		cat "$WD_TESTDIR/iw-dev-ap.txt"
	fi
	exit 0
fi
if [ "$1" = dev ] && [ "$3" = info ]; then
	printf '%s\n' "$*" >> "$WD_TESTDIR/iw-calls"
	if [ -n "$WD_IW_INFO_FIXTURE" ]; then
		cat "$WD_IW_INFO_FIXTURE"
	elif [ -d "$WD_SYSNET/$2" ]; then
		cat "$WD_TESTDIR/iw-info-ap.txt"
	fi
	exit 0
fi
printf '%s\n' 'Wiphy phy0'
EOF

cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
ap_ifname=
for ap_path in "$WD_SYSNET"/*-ap*; do
	[ -d "$ap_path" ] || continue
	ap_ifname=${ap_path##*/}
	break
done
if [ -n "$ap_ifname" ]; then
	printf '{"radio0":{"up":true,"interfaces":[{"ifname":"%s"}]}}\n' "$ap_ifname"
else
	printf '%s\n' '{"radio0":{"up":true,"interfaces":[]}}'
fi
EOF

cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "wireless.default_radio0.disabled='0'"
EOF

cat > "$T/bin/wifi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WD_TESTDIR/wifi-calls"
if [ "$1" = reload ]; then
	mkdir -p "$WD_SYSNET/phy0-ap0" "$WD_SYSNET/br-lan/brif"
fi
EOF

cat > "$T/bin/logger" <<'EOF'
printf '%s\n' "$*" >> "$WD_TESTDIR/syslog"
EOF

cat > "$T/bin/kmodloader" <<'EOF'
printf '%s\n' "$*" >> "$WD_TESTDIR/kmodloader-calls"
exit 0
EOF
cat > "$T/bin/sync" <<'EOF'
printf '%s\n' sync >> "$WD_TESTDIR/recovery-actions"
exit 0
EOF
cat > "$T/bin/reboot" <<'EOF'
printf '%s\n' reboot >> "$WD_TESTDIR/recovery-actions"
exit 0
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
count_file="$WD_TESTDIR/sleep-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${WD_TEST_CREATE_ON_SLEEP:-0}" = 1 ] && [ "$count" -ge 4 ]; then
	mkdir -p "$WD_SYSNET/phy0-ap0" "$WD_SYSNET/br-lan/brif"
fi
if [ "${WD_TEST_EXTERNAL_RECOVERY:-0}" = 1 ]; then
	case "$count" in
		2) mkdir -p "$WD_SYSNET/phy0-ap0" "$WD_SYSNET/br-lan/brif" ;;
		3) rm -rf "$WD_SYSNET/phy0-ap0" "$WD_SYSNET/br-lan/brif" ;;
	esac
fi
/usr/bin/sleep "$@"
EOF
chmod +x "$T/bin/"*

printf '%s\n' "config wifi-iface 'x'" "	option key 'SECRETPSK'" "	option ssid 'test'" > "$T/cfg/wireless"
printf '%s\n' "config interface 'lan'" > "$T/cfg/network"
cp "$COLLECTOR_SCRIPT" "$T/real-collector"
cat > "$T/collector" <<'EOF'
#!/bin/sh
base="$WIFI_DIAG_BASE"
tag="$1"
if [ "$tag" != post-reload ] && [ -e "$base/.done-$tag" ]; then
	exit 3
fi
if [ "$tag" != post-reload ]; then
	: > "$base/.done-$tag"
fi
mkdir -p "$base/bundle-sim/$tag"
printf 'tag=%s\nreason=%s\n' "$tag" "$2" > "$base/bundle-sim/$tag/00-meta.txt"
if [ "$tag" = observe ]; then
	mkdir -p "$WD_SYSNET/phy0-ap0" "$WD_SYSNET/br-lan/brif"
fi
if [ "$tag" = pre-reboot ] && [ "${WD_TEST_HEALTHY_ON_RECHECK:-0}" = 1 ]; then
	mkdir -p "$WD_SYSNET/phy0-ap0" "$WD_SYSNET/br-lan/brif"
fi
exit 0
EOF

# Use a temporary path-adjusted copy so the real script can source the test
# config API and use the test filesystem without changing deployed behavior.
sed \
	-e 's#\. /lib/functions.sh#. "$WD_LIB_FUNCTIONS"#' \
	-e 's#\[ -e /etc/wifi-release-done \]#\[ -e "$WD_PROVISION_MARKER" \]#' \
	-e 's#diag_base=/root/wifi-diag#diag_base="$WIFI_DIAG_BASE"#' \
	-e 's#diag_collect=/usr/libexec/wifi-diag-collect.sh#diag_collect="$WD_COLLECT"#' \
	-e 's#diag_mode_file=/etc/wifi-watchdog.mode#diag_mode_file="$WD_MODEFILE"#' \
	-e 's#/root/WATCHDOG-DISABLED.txt#"$WD_DISABLED_MARKER"#g' \
	-e 's#/etc/k1plus-watchdog-last-reboot#"$WD_REBOOT_STAMP"#g' \
	-e 's#/sbin/kmodloader#"$WD_KMODLOADER"#g' \
	-e '/event "collect tag=observe rc=\$?"/a\
	[ "$WD_TEST_STOP_AFTER_OBSERVE" = 1 ] && exit 0' \
	-e "/event 'wifi reload restored kernel AP, hostapd, and netifd UBus state'/a\\
	[ \"\$WD_TEST_STOP_AFTER_RECOVERY\" = 1 ] && exit 0" \
	-e '/while :; do/a\
	test_loop_count=$((test_loop_count + 1))\
	[ "$test_loop_count" -gt 5 ] && exit 0' \
	"$WATCHDOG_SCRIPT" > "$T/watchdog"
chmod +x "$T/watchdog"

run_watchdog() {
	script="$3"
	stop_observe="$4"
	WD_TEST_INTERVAL=1 WD_TEST_THRESHOLD="${8:-3}" WD_TEST_COMMAND_TIMEOUT=5 \
	WD_TEST_RELOAD_GRACE=1 WD_TESTDIR="$T" \
	WD_TEST_CREATE_ON_SLEEP="${2:-0}" \
	WD_TEST_EXTERNAL_RECOVERY="${5:-0}" \
	WD_TEST_MAX_RECOVERIES="${9:-3}" \
	WD_TEST_STOP_AFTER_OBSERVE="$stop_observe" WD_TEST_STOP_AFTER_RECOVERY=1 \
	WD_SYSNET="$1/sysnet" WIFI_DIAG_BASE="$1/diag" WD_MODEFILE="$1/mode" \
	WD_PROVISION_MARKER="$1/provisioned" WD_DISABLED_MARKER="$1/disabled" \
	WD_REBOOT_STAMP="$1/reboot-stamp" WD_LIB_FUNCTIONS="$T/lib-functions.sh" \
	WD_CFGDIR="$T/cfg" WD_COLLECT="$T/collector" \
	WD_KMODLOADER="$T/bin/kmodloader" \
	WD_IW_DEV_FIXTURE="${6:-}" WD_IW_INFO_FIXTURE="${7:-}" \
	PATH="$T/bin:$PATH" sh "$script"
}

run_predicate_case() {
	name=$1
	dev_fixture=$2
	info_fixture=$3
	initial_ap=$4
	setup "$name" observe
	[ "$initial_ap" = 0 ] || mkdir -p "$S/sysnet/phy0-ap0"
	WD_TEST_INTERVAL=1 WD_TEST_THRESHOLD=3 WD_TEST_COMMAND_TIMEOUT=5 \
	WD_TEST_RELOAD_GRACE=1 WD_TESTDIR="$T" WD_TEST_CREATE_ON_SLEEP=0 \
	WD_TEST_EXTERNAL_RECOVERY=0 WD_TEST_STOP_AFTER_OBSERVE=1 WD_TEST_STOP_AFTER_RECOVERY=1 \
	WD_SYSNET="$S/sysnet" WIFI_DIAG_BASE="$S/diag" WD_MODEFILE="$S/mode" \
	WD_PROVISION_MARKER="$S/provisioned" WD_DISABLED_MARKER="$S/disabled" \
	WD_REBOOT_STAMP="$S/reboot-stamp" WD_LIB_FUNCTIONS="$T/lib-functions.sh" \
	WD_CFGDIR="$T/cfg" WD_COLLECT="$T/collector" WD_KMODLOADER="$T/bin/kmodloader" \
	WD_IW_DEV_FIXTURE="$dev_fixture" WD_IW_INFO_FIXTURE="$info_fixture" \
	PATH="$T/bin:$PATH" sh "$T/watchdog"
}

setup() {
	S="$T/$1"
	rm -rf "$S"
	mkdir -p "$S/sysnet" "$S/diag"
	printf '%s\n' "$2" > "$S/mode"
	: > "$S/provisioned"
	: > "$T/sleep-count"
	: > "$T/wifi-calls"
	: > "$T/iw-calls"
	: > "$T/syslog"
	: > "$T/kmodloader-calls"
	: > "$T/recovery-actions"
}

chmod +x "$T/real-collector" "$T/collector"

echo "== A: observe mode =="
setup A observe
run_watchdog "$S" 0 "$T/watchdog" 0 1 || true
ck "A threshold reached logged" "grep -q 'THRESHOLD-REACHED' '$S/diag/watchdog.log'"
ck "A predicate rc line logged" "grep -Eq 'HEALTH hostapd_rc=0 ap_discovery_rc=1 ap_info_rc=1 ubus_rc=0 ubus_up_rc=0 ubus_ifname_rc=1 .*healthy_rc=1' '$S/diag/watchdog.log'"
ck "A observe bundle written" "ls -d '$S'/diag/bundle-*/observe >/dev/null 2>&1"
ck "A NO reload was issued" "! grep -q '^reload' '$T/wifi-calls'"
ck "A self-recovery logged" "grep -q 'health recovered' '$S/diag/watchdog.log'"

echo "== B: recover mode =="
setup B recover
run_watchdog "$S" 0 "$T/watchdog" 0 || true
reload_count=$(grep -c '^reload' "$T/wifi-calls" 2>/dev/null || true)
ck "B exactly one reload" "[ \"$reload_count\" = 1 ]"
ck "B post-reload OK logged" "grep -q 'wifi reload restored' '$S/diag/watchdog.log'"
ck "B pre-reload collection succeeded" "grep -q 'collect tag=pre-reload rc=0' '$S/diag/watchdog.log'"
ck "B pre-reload bundle written" "ls -d '$S'/diag/bundle-*/pre-reload >/dev/null 2>&1"
ck "B post-reload bundle written" "ls -d '$S'/diag/bundle-*/post-reload >/dev/null 2>&1"
rm -rf "$T/redaction"
WIFI_DIAG_BASE="$T/redaction" WD_CFGDIR="$T/cfg" WD_MODEFILE="$S/mode" "$T/real-collector" pre-reload again >/dev/null
rc=$?
ck "B real collector initial rc=0" "[ $rc = 0 ]"
WIFI_DIAG_BASE="$T/redaction" WD_CFGDIR="$T/cfg" WD_MODEFILE="$S/mode" "$T/real-collector" pre-reload again >/dev/null
rc=$?
ck "B second pre-reload skipped rc=3" "[ $rc = 3 ]"
ck "B secret never written to disk" "! grep -rq SECRETPSK '$T/redaction'"
ck "B redaction marker present" "grep -rq '<redacted>' '$T/redaction'"
ck "B watchdog log has timeline" "grep -q 'mode=recover' '$S/diag/watchdog.log'"
ck "B watchdog log has first failure" "grep -q 'health failure 1/' '$S/diag/watchdog.log'"

sed '0,/stage=0/s//stage=1/' "$T/watchdog" > "$T/watchdog-stage1"
chmod +x "$T/watchdog-stage1"
echo "== C: observe mode at driver-reload stage =="
setup C observe
run_watchdog "$S" 0 "$T/watchdog-stage1" 1 || true
ck "C observe did not call driver reload" "[ ! -s '$T/kmodloader-calls' ]"

sed '0,/stage=0/s//stage=2/' "$T/watchdog" > "$T/watchdog-stage2"
chmod +x "$T/watchdog-stage2"
echo "== D: observe mode at reboot stage =="
setup D observe
run_watchdog "$S" 0 "$T/watchdog-stage2" 1 || true
ck "D observe did not call sync or reboot" "! grep -Eq '^(sync|reboot)$' '$T/recovery-actions'"

echo "== E: stage 3 healthy recheck aborts reboot =="
setup E recover
WD_TEST_INTERVAL=1 WD_TEST_THRESHOLD=3 WD_TEST_COMMAND_TIMEOUT=5 \
	WD_TEST_RELOAD_GRACE=1 WD_TESTDIR="$T" WD_TEST_CREATE_ON_SLEEP=0 \
	WD_TEST_HEALTHY_ON_RECHECK=1 WD_TEST_STOP_AFTER_RECOVERY=0 \
	WD_TEST_STOP_AFTER_OBSERVE=0 WD_SYSNET="$S/sysnet" WIFI_DIAG_BASE="$S/diag" \
	WD_MODEFILE="$S/mode" WD_PROVISION_MARKER="$S/provisioned" \
	WD_DISABLED_MARKER="$S/disabled" WD_REBOOT_STAMP="$S/reboot-stamp" \
	WD_LIB_FUNCTIONS="$T/lib-functions.sh" WD_CFGDIR="$T/cfg" \
	WD_COLLECT="$T/collector" WD_KMODLOADER="$T/bin/kmodloader" \
	PATH="$T/bin:$PATH" sh "$T/watchdog-stage2"
ck "E stage 3 abort logged" "grep -q 'stage3 aborted: healthy on recheck' '$S/diag/watchdog.log'"
ck "E stage 3 did not call sync or reboot" "! grep -Eq '^(sync|reboot)$' '$T/recovery-actions'"
ck "E aborted stage 3 did not consume reboot cooldown" "[ ! -e '$S/reboot-stamp' ]"

echo "== F: tab-indented iw parser fixtures =="
run_predicate_case F1 "$T/iw-dev-ap.txt" "$T/iw-info-ap.txt" 1 || true
ck "F1 AP present is healthy" "grep -q 'HEALTH .*ap_discovery_rc=0 ap_info_rc=0 .*healthy_rc=0' '$T/F1/diag/watchdog.log'"
run_predicate_case F2 "$T/iw-dev-empty.txt" "$T/iw-info-ap.txt" 0 || true
ck "F2 missing interface returns unhealthy" "grep -q 'HEALTH .*ap_discovery_rc=1 ap_info_rc=1 .*healthy_rc=1' '$T/F2/diag/watchdog.log'"
run_predicate_case F3 "$T/iw-dev-ap.txt" "$T/iw-info-managed.txt" 1 || true
ck "F3 non-AP info returns unhealthy" "grep -q 'HEALTH .*ap_discovery_rc=0 ap_info_rc=1 .*healthy_rc=1' '$T/F3/diag/watchdog.log'"
setup F4 observe
mkdir -p "$S/sysnet/phy1-ap0"
WD_TEST_INTERVAL=1 WD_TEST_THRESHOLD=3 WD_TEST_COMMAND_TIMEOUT=5 \
	WD_TEST_RELOAD_GRACE=1 WD_TESTDIR="$T" WD_TEST_CREATE_ON_SLEEP=0 \
	WD_TEST_EXTERNAL_RECOVERY=0 WD_TEST_STOP_AFTER_OBSERVE=1 WD_TEST_STOP_AFTER_RECOVERY=1 \
	WD_SYSNET="$S/sysnet" WIFI_DIAG_BASE="$S/diag" WD_MODEFILE="$S/mode" \
	WD_PROVISION_MARKER="$S/provisioned" WD_DISABLED_MARKER="$S/disabled" \
	WD_REBOOT_STAMP="$S/reboot-stamp" WD_LIB_FUNCTIONS="$T/lib-functions.sh" \
	WD_CFGDIR="$T/cfg" WD_COLLECT="$T/collector" WD_KMODLOADER="$T/bin/kmodloader" \
	WD_IW_DEV_FIXTURE="$T/iw-dev-multi.txt" WD_IW_INFO_FIXTURE="$T/iw-info-ap.txt" \
	PATH="$T/bin:$PATH" sh "$T/watchdog" || true
ck "F4 selects AP across multiple phys/interfaces" "grep -q 'HEALTH .*ap_discovery_rc=0 ap_info_rc=0 .*healthy_rc=0' '$T/F4/diag/watchdog.log' && grep -q 'dev phy1-ap0 info' '$T/iw-calls'"

echo "== G: cooldown suppression keeps recovery active =="
sed '0,/stage=0/s//stage=2/' "$T/watchdog" > "$T/watchdog-stage2"
chmod +x "$T/watchdog-stage2"
setup G1 recover
date +%s > "$S/reboot-stamp"
run_watchdog "$S" 0 "$T/watchdog-stage2" 0 0 "$T/iw-dev-empty.txt" "$T/iw-info-ap.txt" 1 3 || true
ck "G1 cooldown suppression is logged" "grep -q 'reboot suppressed by cooldown' '$S/diag/watchdog.log'"
ck "G1 watchdog continues to stage 1 reload" "grep -q 'recovery stage 1: wifi reload' '$S/diag/watchdog.log'"
ck "G1 cooldown refusal does not reboot" "! grep -Eq '^(sync|reboot)$' '$T/recovery-actions'"
ck "G1 cooldown refusal does not create permanent disable marker" "[ ! -e '$S/disabled' ]"
ck "G1 cooldown log is rate limited" "[ \$(grep -c 'reboot suppressed by cooldown' '$S/diag/watchdog.log') -eq 1 ]"

setup G2 recover
: > "$S/disabled"
run_watchdog "$S" 0 "$T/watchdog" 0 0 "$T/iw-dev-empty.txt" "$T/iw-info-ap.txt" 1 3 || true
ck "G2 existing disable marker does not stop startup" "grep -q 'recovery stage 1: wifi reload' '$S/diag/watchdog.log'"

setup G3 recover
now=$(date +%s)
printf '%s\n' "$((now - 3601))" > "$S/reboot-stamp"
run_watchdog "$S" 0 "$T/watchdog-stage2" 0 0 "$T/iw-dev-empty.txt" "$T/iw-info-ap.txt" 1 3 || true
ck "G3 reboot is allowed after cooldown expires" "grep -q 'recovery stage 3: reboot' '$S/diag/watchdog.log' && grep -Eq '^(sync|reboot)$' '$T/recovery-actions'"

if [ "$fail" -eq 0 ]; then
	echo ALL PASS
	rm -rf "$T"
else
	echo "FAILED -- artifacts kept in $T"
fi
exit "$fail"
