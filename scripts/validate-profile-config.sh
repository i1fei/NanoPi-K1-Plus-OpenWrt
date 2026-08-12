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

	echo "RTL8189ES_DRIVER=INTENTIONALLY_EXCLUDED" >> "$resolution"
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
		CONFIG_PACKAGE_kmod-bluetooth \
		CONFIG_PACKAGE_kmod-btusb; do
		require_enabled "$symbol"
	done

	echo "EXTERNAL_USB_BLUETOOTH=PREPARED" >> "$resolution"
	echo "ONBOARD_BLUETOOTH_HARDWARE=UNKNOWN" >> "$resolution"
	echo "ONBOARD_BLUETOOTH_DTS=NOT_IMPLEMENTED" >> "$resolution"
	echo "BLUETOOTH_HARDWARE_TEST=UNTESTED" >> "$resolution"
	echo "WIFI=INTENTIONALLY_EXCLUDED" >> "$resolution"
}

check_wifi_compat() {
	require_value CONFIG_TARGET_ROOTFS_PARTSIZE 1024
	for symbol in \
		CONFIG_PACKAGE_luci \
		CONFIG_PACKAGE_luci-app-package-manager \
		CONFIG_PACKAGE_luci-i18n-base-zh-cn \
		CONFIG_PACKAGE_dropbear \
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
		CONFIG_PACKAGE_libdrm-tests \
		CONFIG_PACKAGE_kmod-rtl8189es \
		CONFIG_PACKAGE_wpad-openssl \
		CONFIG_PACKAGE_wireless-regdb \
		CONFIG_PACKAGE_iwinfo \
		CONFIG_PACKAGE_rpcd-mod-iwinfo; do
		require_enabled "$symbol"
	done

	for symbol in \
		CONFIG_PACKAGE_luci-app-watchcat \
		CONFIG_PACKAGE_watchcat \
		CONFIG_PACKAGE_kmod-bluetooth \
		CONFIG_PACKAGE_kmod-btusb \
		CONFIG_PACKAGE_bluez-daemon \
		CONFIG_PACKAGE_openssh-server \
		CONFIG_PACKAGE_samba4-server; do
		require_not_enabled "$symbol"
	done

	echo "RTL8189ES_DRIVER=SELECTED" >> "$resolution"
	echo "WIFI_AP_STACK=SELECTED" >> "$resolution"
	echo "LAN_POLICY=COMPAT_ETH0_192.168.1.1" >> "$resolution"
	echo "WATCHCAT=EXCLUDED" >> "$resolution"
}

check_rtl8189es_inert() {
	require_value CONFIG_TARGET_ROOTFS_PARTSIZE 4096
	for symbol in \
		CONFIG_PACKAGE_luci-ssl-openssl \
		CONFIG_PACKAGE_luci-i18n-base-zh-cn \
		CONFIG_PACKAGE_ttyd \
		CONFIG_PACKAGE_luci-app-ttyd \
		CONFIG_PACKAGE_samba4-server \
		CONFIG_PACKAGE_luci-app-samba4 \
		CONFIG_PACKAGE_kmod-bluetooth \
		CONFIG_PACKAGE_kmod-btusb; do
		require_enabled "$symbol"
	done
	require_enabled CONFIG_PACKAGE_kmod-rtl8189es

	for symbol in \
		CONFIG_PACKAGE_wpad-openssl \
		CONFIG_PACKAGE_hostapd \
		CONFIG_PACKAGE_hostapd-utils \
		CONFIG_PACKAGE_iwinfo \
		CONFIG_PACKAGE_rpcd-mod-iwinfo; do
		require_not_enabled "$symbol"
	done

	echo "RTL8189ES_DRIVER=SELECTED" >> "$resolution"
	echo "RTL8189ES_PACKAGE_DEFAULT=PATCHED_INERT" >> "$resolution"
	echo "WIFI_AP_STACK=NOT_SELECTED" >> "$resolution"
	echo "LAN_POLICY=BOARD_D_ETH0_CONFIG_GENERATE" >> "$resolution"
	echo "CFG80211_DEPS=EXPECTED_WITH_RTL8189ES" >> "$resolution"
}

check_buddha() {
	require_value CONFIG_TARGET_ROOTFS_PARTSIZE 8192

	# Keep this list aligned with configs/NanoPi_K1_Plus_buddha.config.  Earlier
	# validation required proxy/remote packages that are intentionally excluded
	# because they are not present in the pinned upstream snapshot.
	for symbol in \
		CONFIG_PACKAGE_luci \
		CONFIG_PACKAGE_luci-app-package-manager \
		CONFIG_PACKAGE_luci-i18n-base-zh-cn \
		CONFIG_PACKAGE_dropbear \
		CONFIG_PACKAGE_luci-ssl-openssl \
		CONFIG_PACKAGE_openssl-util \
		CONFIG_PACKAGE_luci-theme-argon \
		CONFIG_PACKAGE_luci-app-argon-config \
		CONFIG_PACKAGE_luci-theme-bootstrap \
		CONFIG_PACKAGE_ttyd \
		CONFIG_PACKAGE_luci-app-ttyd \
		CONFIG_PACKAGE_luci-app-commands \
		CONFIG_PACKAGE_luci-app-filebrowser \
		CONFIG_PACKAGE_luci-app-diskman \
		CONFIG_PACKAGE_luci-app-firewall \
		CONFIG_PACKAGE_samba4-server \
		CONFIG_PACKAGE_luci-app-samba4 \
		CONFIG_PACKAGE_wsdd2 \
		CONFIG_PACKAGE_openssh-sftp-server \
		CONFIG_PACKAGE_openssh-sftp-client \
		CONFIG_PACKAGE_luci-app-ddns \
		CONFIG_PACKAGE_ddns-scripts \
		CONFIG_PACKAGE_ddns-scripts-services \
		CONFIG_PACKAGE_ddns-scripts-utils \
		CONFIG_PACKAGE_luci-app-statistics \
		CONFIG_PACKAGE_luci-app-watchcat \
		CONFIG_PACKAGE_watchcat \
		CONFIG_PACKAGE_kmod-usb-storage \
		CONFIG_PACKAGE_kmod-usb-storage-uas \
		CONFIG_PACKAGE_kmod-usb-hid \
		CONFIG_PACKAGE_kmod-usb-net \
		CONFIG_PACKAGE_kmod-usb-net-rtl8152 \
		CONFIG_PACKAGE_kmod-usb-net-asix \
		CONFIG_PACKAGE_kmod-usb-net-asix-ax88179 \
		CONFIG_PACKAGE_kmod-usbip \
		CONFIG_PACKAGE_kmod-usbip-client \
		CONFIG_PACKAGE_kmod-usbip-server \
		CONFIG_PACKAGE_kmod-usb-serial \
		CONFIG_PACKAGE_kmod-usb-serial-ch341 \
		CONFIG_PACKAGE_kmod-usb-serial-cp210x \
		CONFIG_PACKAGE_kmod-usb-serial-ftdi \
		CONFIG_PACKAGE_kmod-usb-serial-pl2303 \
		CONFIG_PACKAGE_kmod-bluetooth \
		CONFIG_PACKAGE_kmod-btusb \
		CONFIG_PACKAGE_bluez-daemon \
		CONFIG_PACKAGE_bluez-utils \
		CONFIG_PACKAGE_bluez-utils-extra \
		CONFIG_PACKAGE_fdisk \
		CONFIG_PACKAGE_cfdisk \
		CONFIG_PACKAGE_parted \
		CONFIG_PACKAGE_lsblk \
		CONFIG_PACKAGE_htop \
		CONFIG_PACKAGE_usbutils \
		CONFIG_PACKAGE_mmc-utils \
		CONFIG_PACKAGE_i2c-tools \
		CONFIG_PACKAGE_gpiod-tools \
		CONFIG_PACKAGE_tcpdump \
		CONFIG_PACKAGE_ip-full \
		CONFIG_PACKAGE_lsof \
		CONFIG_PACKAGE_strace; do
		require_enabled "$symbol"
	done

	require_not_enabled CONFIG_PACKAGE_kmod-rtl8189es

	echo "RTL8189ES_DRIVER=INTENTIONALLY_EXCLUDED" >> "$resolution"
	echo "LAN_POLICY=LAN_FIRST_STATIC_192.168.1.1" >> "$resolution"
	echo "BUDDHA_SAMPLE_SOFTWARE=SELECTED" >> "$resolution"
}

classify_requested
check_common

case "$profile" in
	base) check_base ;;
	full) check_full ;;
	wifi_compat|wifi_compat_v2) check_wifi_compat ;;
	rtl8189es_inert) check_rtl8189es_inert ;;
	buddha) check_buddha ;;
	*) note_fail "unknown profile: $profile" ;;
esac

if [ "$fail" -ne 0 ]; then
	exit 1
fi
