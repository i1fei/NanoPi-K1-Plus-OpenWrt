#!/bin/sh
set -eu

profile=${1:?profile is required}
requested_config=${2:?requested config is required}
resolved_config=${3:?resolved config is required}
out_dir=${4:?output directory is required}

mkdir -p "$out_dir"

requested="$out_dir/requested.txt"
resolution="$out_dir/resolution.txt"

awk '
	/^CONFIG_PACKAGE_.*=y$/ ||
	/^CONFIG_LUCI_LANG_.*=y$/ ||
	/^CONFIG_TARGET_ROOTFS_PARTSIZE=/ { print }
' "$requested_config" | sort > "$requested"

cp "$resolved_config" "$out_dir/resolved.config"
awk -F= '/^CONFIG_PACKAGE_.*=y$/ { sub(/^CONFIG_PACKAGE_/, "", $1); print $1 }' \
	"$resolved_config" | sort > "$out_dir/enabled-packages.txt"

: > "$resolution"

fail=0
note_fail() {
	echo "ERROR: $*" >> "$resolution"
	fail=1
}

is_enabled() {
	grep -q "^$1=y$" "$resolved_config"
}

is_value() {
	grep -q "^$1=$2$" "$resolved_config"
}

is_not_enabled() {
	! grep -q "^$1=y$" "$resolved_config"
}

classify_requested() {
	while IFS= read -r line; do
		symbol=${line%%=*}
		if grep -qxF "$line" "$resolved_config"; then
			printf '%s %s\n' "REQUESTED_AND_ENABLED" "$line" >> "$resolution"
		elif grep -q "^# $symbol is not set$" "$resolved_config"; then
			printf '%s %s\n' "DEPENDENCY_NOT_MET" "$line" >> "$resolution"
			fail=1
		elif grep -q "^$symbol=" "$resolved_config"; then
			printf '%s %s\n' "CONFLICT" "$line" >> "$resolution"
			fail=1
		else
			printf '%s %s\n' "PACKAGE_NOT_FOUND" "$line" >> "$resolution"
			fail=1
		fi
	done < "$requested"
}

require_enabled() {
	is_enabled "$1" || note_fail "$1 is not enabled"
}

require_not_enabled() {
	is_not_enabled "$1" || note_fail "$1 must not be enabled"
}

require_value() {
	is_value "$1" "$2" || note_fail "$1 is not $2"
}

check_common() {
	require_enabled CONFIG_TARGET_sunxi
	require_enabled CONFIG_TARGET_sunxi_cortexa53
	require_enabled CONFIG_TARGET_sunxi_cortexa53_DEVICE_friendlyarm_nanopi-k1-plus
	require_enabled CONFIG_LUCI_LANG_zh_Hans

	for forbidden in \
		CONFIG_ALL_KMODS \
		CONFIG_ALL_NONSHARED \
		CONFIG_DEVEL \
		CONFIG_SDK \
		CONFIG_MAKE_TOOLCHAIN; do
		require_not_enabled "$forbidden"
	done
}

check_base() {
	require_value CONFIG_TARGET_ROOTFS_PARTSIZE 512
	for symbol in \
		CONFIG_PACKAGE_luci \
		CONFIG_PACKAGE_luci-app-package-manager \
		CONFIG_PACKAGE_luci-i18n-base-zh-cn \
		CONFIG_PACKAGE_dropbear \
		CONFIG_PACKAGE_kmod-rtl8189es \
		CONFIG_PACKAGE_kmod-mmc \
		CONFIG_PACKAGE_kmod-usb-hid \
		CONFIG_PACKAGE_kmod-usb-storage \
		CONFIG_PACKAGE_kmod-fs-ext4 \
		CONFIG_PACKAGE_kmod-fs-vfat \
		CONFIG_PACKAGE_kmod-fs-exfat \
		CONFIG_PACKAGE_kmod-fs-ntfs3 \
		CONFIG_PACKAGE_block-mount \
		CONFIG_PACKAGE_e2fsprogs \
		CONFIG_PACKAGE_nano \
		CONFIG_PACKAGE_curl \
		CONFIG_PACKAGE_wget-ssl \
		CONFIG_PACKAGE_htop \
		CONFIG_PACKAGE_ethtool \
		CONFIG_PACKAGE_iperf3 \
		CONFIG_PACKAGE_usbutils \
		CONFIG_PACKAGE_ca-bundle \
		CONFIG_PACKAGE_evtest \
		CONFIG_PACKAGE_libdrm-tests; do
		require_enabled "$symbol"
	done

	for symbol in \
		CONFIG_PACKAGE_wpad-openssl \
		CONFIG_PACKAGE_hostapd-utils \
		CONFIG_PACKAGE_samba4-server \
		CONFIG_PACKAGE_ttyd \
		CONFIG_PACKAGE_luci-app-ttyd \
		CONFIG_PACKAGE_kmod-bluetooth \
		CONFIG_PACKAGE_kmod-btusb \
		CONFIG_PACKAGE_bluez-daemon \
		CONFIG_PACKAGE_openssh-server \
		CONFIG_PACKAGE_luci-app-statistics \
		CONFIG_PACKAGE_wireguard-tools; do
		require_not_enabled "$symbol"
	done

	echo "RTL8189ES_DRIVER=ENABLED" >> "$resolution"
	echo "WIFI_AP_STACK=NOT_SELECTED" >> "$resolution"
	echo "BLUETOOTH=NOT_SELECTED" >> "$resolution"
}

check_full() {
	require_value CONFIG_TARGET_ROOTFS_PARTSIZE 4096
	for symbol in \
		CONFIG_PACKAGE_luci-ssl-openssl \
		CONFIG_PACKAGE_luci-i18n-base-zh-cn \
		CONFIG_PACKAGE_ttyd \
		CONFIG_PACKAGE_luci-app-ttyd \
		CONFIG_PACKAGE_samba4-server \
		CONFIG_PACKAGE_luci-app-samba4 \
		CONFIG_PACKAGE_wpad-openssl \
		CONFIG_PACKAGE_hostapd-utils \
		CONFIG_PACKAGE_iw-full \
		CONFIG_PACKAGE_kmod-bluetooth \
		CONFIG_PACKAGE_kmod-btusb; do
		require_enabled "$symbol"
	done

	providers="
CONFIG_PACKAGE_wpad-openssl
CONFIG_PACKAGE_wpad-mbedtls
CONFIG_PACKAGE_wpad-wolfssl
CONFIG_PACKAGE_wpad-basic
CONFIG_PACKAGE_wpad-basic-mbedtls
CONFIG_PACKAGE_wpad-basic-openssl
CONFIG_PACKAGE_wpad-basic-wolfssl
"
	count=0
	for provider in $providers; do
		if is_enabled "$provider"; then
			count=$((count + 1))
			selected_provider=$provider
		fi
	done

	if [ "$count" -eq 1 ] && [ "${selected_provider:-}" = CONFIG_PACKAGE_wpad-openssl ]; then
		echo "WIFI_PROVIDER_CHECK=PASS" >> "$resolution"
	else
		note_fail "Wi-Fi provider check failed"
	fi

	echo "EXTERNAL_USB_BLUETOOTH=PREPARED" >> "$resolution"
	echo "ONBOARD_BLUETOOTH_HARDWARE=UNKNOWN" >> "$resolution"
	echo "ONBOARD_BLUETOOTH_DTS=NOT_IMPLEMENTED" >> "$resolution"
	echo "BLUETOOTH_HARDWARE_TEST=UNTESTED" >> "$resolution"
}

classify_requested
check_common

case "$profile" in
	base) check_base ;;
	full) check_full ;;
	*) note_fail "unknown profile: $profile" ;;
esac

if [ "$fail" -ne 0 ]; then
	exit 1
fi
