#!/bin/sh
set -eu

root=${1:?release root is required}
failures=0

pass() {
	printf '%s=PASS\n' "$1"
}

fail() {
	printf '%s=FAIL\n' "$1" >&2
	failures=$((failures + 1))
}

require_file() {
	[ -f "$root/$1" ] && pass "$2" || fail "$2"
}

require_exec() {
	[ -x "$root/$1" ] && pass "$2" || fail "$2"
}

require_pattern() {
	grep -Eq "$2" "$root/$1" && pass "$3" || fail "$3"
}

require_literal() {
	grep -Fq "$2" "$root/$1" && pass "$3" || fail "$3"
}

reject_pattern() {
	if grep -Eq "$2" "$root/$1"; then fail "$3"; else pass "$3"; fi
}

for path in \
	etc/config/wireless \
	etc/config/dhcp \
	etc/config/k1plus_network \
	etc/config/k1plus_watchdog \
	etc/uci-defaults/99-k1-plus-wifi-release-v1 \
	etc/uci-defaults/00-k1plus-trace \
	etc/uci-defaults/99zz-k1plus-trace \
	etc/init.d/k1plus-network \
	etc/init.d/k1plus-wifi-watchdog \
	etc/init.d/k1plus-wifi-settle \
	etc/init.d/k1plus-wifi-trace-19 \
	etc/init.d/k1plus-wifi-trace-21 \
	etc/init.d/k1plus-hw-watchdog \
	etc/hotplug.d/ieee80211/00-k1plus-trace \
	usr/libexec/wifi-diag-collect.sh \
	usr/libexec/k1plus-wifi-trace \
	usr/libexec/k1plus-wifi-settle \
	etc/profile.d/99-k1-plus-wifi.sh \
	usr/libexec/k1plus-dhcp-event \
	usr/sbin/k1plus-network-mode \
	usr/sbin/k1plus-wifi-watchdog; do
	require_file "$path" "FILE_$(printf '%s' "$path" | tr '/.-' '___')"
done

for path in \
	etc/uci-defaults/99-k1-plus-wifi-release-v1 \
	etc/uci-defaults/00-k1plus-trace \
	etc/uci-defaults/99zz-k1plus-trace \
	etc/init.d/k1plus-network \
	etc/init.d/k1plus-wifi-watchdog \
	etc/init.d/k1plus-wifi-settle \
	etc/init.d/k1plus-wifi-trace-19 \
	etc/init.d/k1plus-wifi-trace-21 \
	etc/init.d/k1plus-hw-watchdog \
	etc/hotplug.d/ieee80211/00-k1plus-trace \
	usr/libexec/wifi-diag-collect.sh \
	usr/libexec/k1plus-wifi-trace \
	usr/libexec/k1plus-wifi-settle \
	usr/libexec/k1plus-dhcp-event \
	usr/sbin/k1plus-network-mode \
	usr/sbin/k1plus-wifi-watchdog; do
	require_exec "$path" "EXEC_$(printf '%s' "$path" | tr '/.-' '___')"
	sh -n "$root/$path" && pass "SYNTAX_$(printf '%s' "$path" | tr '/.-' '___')" || fail "SYNTAX_$(printf '%s' "$path" | tr '/.-' '___')"
done

require_pattern etc/config/wireless "^[[:space:]]*option network 'lan'$" WIRELESS_NETWORK_LAN
require_pattern etc/config/wireless "^[[:space:]]*option channel '6'$" WIRELESS_CHANNEL_6
require_pattern etc/config/wireless "^[[:space:]]*option htmode 'HT20'$" WIRELESS_HT20
require_pattern etc/config/wireless "^[[:space:]]*option country 'CN'$" WIRELESS_COUNTRY_CN
require_pattern etc/config/wireless "^[[:space:]]*option encryption 'psk2\\+ccmp'$" WIRELESS_WPA2_CCMP
require_pattern etc/config/wireless "^[[:space:]]*option max_inactivity '1800'$" WIFI_IOT_INACTIVITY
require_pattern etc/config/wireless "^[[:space:]]*option disassoc_low_ack '0'$" WIFI_IOT_LOW_ACK
require_pattern etc/config/wireless "^[[:space:]]*option maxassoc '16'$" WIFI_STATION_LIMIT
reject_pattern etc/config/wireless "^[[:space:]]*option key " WIRELESS_STATIC_CREDENTIAL_ABSENT

require_pattern etc/config/dhcp "^[[:space:]]*option ignore '1'$" FALLBACK_DHCP_DEFAULT_OFF
require_pattern etc/config/dhcp "^[[:space:]]*option dhcpv4 'disabled'$" UCI_DHCPV4_DEFAULT_OFF
require_pattern etc/config/k1plus_network "^[[:space:]]*option dhcp_timeout '90'$" DHCP_TIMEOUT_CONFIGURED
require_pattern etc/config/k1plus_network "^[[:space:]]*option probe_interval '30'$" DHCP_PROBE_INTERVAL_CONFIGURED
require_pattern etc/config/k1plus_network "^[[:space:]]*option fallback_ip '192\\.168\\.1\\.1'$" FALLBACK_ADDRESS_CONFIGURED
require_pattern etc/config/k1plus_network "^[[:space:]]*option fallback_netmask '255\\.255\\.255\\.0'$" FALLBACK_NETMASK_CONFIGURED
reject_pattern etc/config/k1plus_network '169\\.254\\.' LINK_LOCAL_AUXILIARY_ABSENT

policy=etc/uci-defaults/99-k1-plus-wifi-release-v1
require_pattern "$policy" '/dev/urandom' RANDOM_CREDENTIAL_SOURCE
require_pattern "$policy" "head -c 256 /dev/urandom \\| tr -dc 'A-Za-z0-9'.* \\| cut -c 1-12" RANDOM_CREDENTIAL_EXISTING_APPLETS
reject_pattern "$policy" '(^|[[:space:]])base64([[:space:]]|$)' BASE64_DEPENDENCY_ABSENT
require_pattern "$policy" 'passwd root' ROOT_CREDENTIAL_SET
require_pattern "$policy" "option name 'br-lan'" BR_LAN_DEFINED
require_pattern "$policy" "list ports 'eth0'" BR_LAN_ETH0_PORT
require_pattern "$policy" "option proto 'none'" LAN_ADDRESS_OWNED_BY_STATE_MACHINE
require_pattern "$policy" "set system\\.@system\\[0\\]\\.hostname='nanopi-k1plus'" HOSTNAME_FIXED
require_literal "$policy" "set \$iface_section.network='lan'" WLAN_JOINS_BR_LAN
require_pattern "$policy" "set dhcp\\.lan\\.ignore='1'" DEVICE_DHCP_DEFAULT_OFF
require_pattern "$policy" 'FIRSTBOOT-FAILED\.txt' FIRSTBOOT_FAILURE_MARKER
require_pattern "$policy" 'attempt.*-lt 3' FIRSTBOOT_RETRY_LIMIT
require_pattern "$policy" 'exit 1' FIRSTBOOT_RETRY_RETAINS_SCRIPT
require_pattern "$policy" 'retry limit reached' FIRSTBOOT_RETRY_EXHAUSTED_LOG
reject_pattern "$policy" "option key '[^$]" HARDCODED_UCI_CREDENTIAL_ABSENT
reject_pattern "$policy" '(^|[[:space:]])(wifi|hostapd)([[:space:]]|$)|/etc/init\\.d/[^[:space:]]+[[:space:]]+start' FIRSTBOOT_DEFERS_RUNTIME_START
require_pattern etc/profile.d/99-k1-plus-wifi.sh '/tmp/current-ip' LOGIN_CURRENT_IP_HINT
require_pattern etc/profile.d/99-k1-plus-wifi.sh 'serial console' LOGIN_SERIAL_RECOVERY_HINT
require_pattern etc/profile.d/99-k1-plus-wifi.sh 'FIRSTBOOT-FAILED\.txt' LOGIN_FIRSTBOOT_FAILURE_WARNING

mode=usr/sbin/k1plus-network-mode
require_pattern "$mode" 'arping -D' DUPLICATE_ADDRESS_DETECTION
require_pattern "$mode" '/tmp/current-ip' CURRENT_IP_TRACKING
require_pattern "$mode" 'MODE_A' MODE_A_LOGGING
require_pattern "$mode" 'MODE_B' MODE_B_LOGGING
require_pattern "$mode" 'stop_fallback_dhcp' DHCP_DISABLED_BEFORE_PROBE
reject_pattern "$mode" '192\\.168\\.1\\.1|255\\.255\\.255\\.0' NETWORK_VALUES_NOT_HARDCODED_IN_STATE_MACHINE
reject_pattern "$mode" '(^|[[:space:]])(wifi|hostapd)([[:space:]]|$)' MODE_SWITCH_DOES_NOT_RESTART_WIFI

watchdog=usr/sbin/k1plus-wifi-watchdog
require_pattern usr/sbin/k1plus-network-mode '/etc/wifi-release-done' NETWORK_SERVICE_PROVISIONING_GATE
require_pattern "$watchdog" '/etc/wifi-release-done' WIFI_WATCHDOG_PROVISIONING_GATE
require_pattern etc/init.d/k1plus-hw-watchdog '/etc/wifi-release-done' HARDWARE_WATCHDOG_PROVISIONING_GATE
require_pattern "$watchdog" 'wifi reload' WIFI_WATCHDOG_RELOAD_STAGE
require_pattern "$watchdog" 'ubus call network\.wireless status' WIFI_WATCHDOG_NETIFD_STATUS
require_pattern "$watchdog" 'administrator_disabled' WIFI_WATCHDOG_ADMIN_DISABLED_GUARD
require_pattern "$watchdog" 'reload_grace' WIFI_WATCHDOG_RELOAD_GRACE
require_pattern "$watchdog" 'WATCHDOG-DISABLED.txt' WIFI_WATCHDOG_LOOP_GUARD
reject_pattern "$watchdog" '(^|[[:space:]])wifi[[:space:]]+(down|up)([[:space:]]|$)' WIFI_WATCHDOG_NO_DOWN_UP
reject_pattern "$watchdog" 'wlan0|wlan1' WIFI_WATCHDOG_DYNAMIC_INTERFACE
reject_pattern usr/sbin/k1plus-network-mode 'wlan0|wlan1' NETWORK_MODE_DYNAMIC_INTERFACE

require_file etc/wifi-watchdog.mode WIFI_WATCHDOG_MODE_FILE
require_pattern etc/wifi-watchdog.mode '^(recover|observe)[[:space:]]*$' WIFI_WATCHDOG_MODE_VALID
require_pattern "$watchdog" 'wifi-diag-collect\.sh' WIFI_WATCHDOG_DIAG_COLLECTOR
require_pattern "$watchdog" 'wifi-watchdog\.mode' WIFI_WATCHDOG_MODE_CONTROL
require_pattern "$watchdog" 'watchdog\.log' WIFI_WATCHDOG_PERSISTENT_LOG
require_pattern "$watchdog" 'THRESHOLD-REACHED' WIFI_WATCHDOG_THRESHOLD_LOG
require_pattern usr/libexec/wifi-diag-collect.sh 'ubus call network\.wireless status' WIFI_DIAG_UBUS_CAPTURE
require_pattern usr/libexec/wifi-diag-collect.sh 'redact' WIFI_DIAG_REDACTION

if grep -q "$(printf '\r')" "$root/usr/libexec/wifi-diag-collect.sh" "$root/usr/sbin/k1plus-wifi-watchdog"; then
	fail WIFI_DIAG_SCRIPTS_LF
else
	pass WIFI_DIAG_SCRIPTS_LF
fi

marker_bool_matches=$(grep -REn '!![[:space:]]*readfile[[:space:]]*\([^)]*/etc/wifi-release-done' \
	"$root/lib" "$root/etc" "$root/usr" 2>/dev/null || true)
if [ -n "$marker_bool_matches" ]; then
	fail WIFI_RELEASE_MARKER_NOT_READ_AS_BOOLEAN
else
	pass WIFI_RELEASE_MARKER_NOT_READ_AS_BOOLEAN
fi

require_literal "$policy" "printf '%s\n' done > /etc/wifi-release-done" WIFI_RELEASE_MARKER_NONEMPTY
runtime_interface_matches=$(grep -REn 'wlan0|wlan1' \
	"$root/etc/uci-defaults" "$root/etc/init.d" "$root/usr/libexec" "$root/usr/sbin" || true)
if [ -n "$runtime_interface_matches" ]; then
	fail WIFI_RELEASE_RUNTIME_HARDCODED_INTERFACE
else
	pass WIFI_RELEASE_RUNTIME_HARDCODED_INTERFACE
fi
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option failure_threshold '5'$" WIFI_WATCHDOG_THRESHOLD
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option reload_grace '60'$" WIFI_WATCHDOG_RELOAD_GRACE_CONFIG
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option recovery_window '3600'$" WIFI_WATCHDOG_RECOVERY_WINDOW
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option max_recoveries '3'$" WIFI_WATCHDOG_MAX_RECOVERIES
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option reboot_cooldown '3600'$" WIFI_WATCHDOG_REBOOT_COOLDOWN
require_pattern "$watchdog" '/sbin/kmodloader -r rtl8189es' WIFI_WATCHDOG_DRIVER_UNLOAD
require_pattern "$watchdog" '/sbin/kmodloader rtl8189es' WIFI_WATCHDOG_DRIVER_LOAD
require_pattern "$watchdog" 'reboot' WIFI_WATCHDOG_REBOOT_STAGE
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option timeout '30'$" HARDWARE_WATCHDOG_TIMEOUT
require_pattern etc/config/k1plus_watchdog "^[[:space:]]*option frequency '5'$" HARDWARE_WATCHDOG_FREQUENCY
require_pattern etc/init.d/k1plus-hw-watchdog 'ubus call system watchdog' HARDWARE_WATCHDOG_PROCD_API

if [ -d "$root/lib/modules" ]; then
	require_file etc/config/uhttpd UHTTPD_CONFIG
	require_exec usr/bin/arping ARPING_BINARY
	require_pattern etc/config/uhttpd "^[[:space:]]*list[[:space:]]+listen_http[[:space:]]+'?0\\.0\\.0\\.0:80'?$" UHTTPD_PORT_80
fi

hardcoded_matches=$(grep -REn "wpa_passphrase=|^[[:space:]]*option key '[^$/']" \
	"$root/etc/config" "$root/etc/uci-defaults" || true)
if [ -n "$hardcoded_matches" ]; then
	printf '%s\n' 'HARDCODED_CREDENTIAL_MATCHES:' >&2
	printf '%s\n' "$hardcoded_matches" | sed -E "s#${root}/##" >&2
	fail HARDCODED_CREDENTIAL_SCAN
else
	pass HARDCODED_CREDENTIAL_SCAN
fi

[ "$failures" -eq 0 ] || exit 1
