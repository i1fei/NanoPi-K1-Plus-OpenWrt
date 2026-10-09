#!/bin/sh
set -eu

ARTIFACT_DIR=${1:?artifact directory is required}
PROFILE=${2:-${BUILD_PROFILE:-default}}
SOURCE_DIR=${3:-.work/openwrt}
VALIDATION_FILE="$ARTIFACT_DIR/stage-a-display-validation.txt"
COLLECT_ALL=0
VALIDATION_FAILURES=0

: > "$VALIDATION_FILE"

case "$PROFILE" in
	default|full)
		PROFILE_KEY=full
		PROFILE_LABEL=FULL
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/full-profile-manifest-validation.txt"
		;;
	base)
		PROFILE_KEY=base
		PROFILE_LABEL=BASE
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/base-profile-manifest-validation.txt"
		;;
	wifi_compat)
		PROFILE_KEY=wifi_compat
		PROFILE_LABEL=WIFI_COMPAT
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/wifi-compat-profile-manifest-validation.txt"
		;;
	wifi_compat_v2)
		PROFILE_KEY=wifi_compat_v2
		PROFILE_LABEL=WIFI_COMPAT_V2
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/wifi-compat-v2-profile-manifest-validation.txt"
		;;
	wifi_compat_v3)
		PROFILE_KEY=wifi_compat_v3
		PROFILE_LABEL=WIFI_COMPAT_V3
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/wifi-compat-v3-profile-manifest-validation.txt"
		;;
	wifi_release_v1)
		PROFILE_KEY=wifi_release_v1
		PROFILE_LABEL=WIFI_RELEASE_V1
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/wifi-release-v1-profile-manifest-validation.txt"
		;;
	rtl8189es_inert)
		PROFILE_KEY=rtl8189es_inert
		PROFILE_LABEL=RTL8189ES_INERT
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/rtl8189es-inert-profile-manifest-validation.txt"
		;;
	buddha)
		PROFILE_KEY=buddha
		PROFILE_LABEL=BUDDHA
		PROFILE_VALIDATION_FILE="$ARTIFACT_DIR/buddha-profile-manifest-validation.txt"
		;;
	*)
		echo "unknown build profile: $PROFILE" >&2
		exit 1
		;;
esac

: > "$PROFILE_VALIDATION_FILE"

record() {
	printf '%s\n' "$*" >> "$VALIDATION_FILE"
}

record_full() {
	printf '%s\n' "$*" >> "$PROFILE_VALIDATION_FILE"
}

fail() {
	record "$1=FAIL"
	echo "$1 missing or invalid" >&2
	if [ "$COLLECT_ALL" -eq 1 ]; then
		VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
		return 0
	fi
	exit 1
}

fail_full() {
	record_full "$1=FAIL"
	echo "$1 missing or invalid" >&2
	if [ "$COLLECT_ALL" -eq 1 ]; then
		VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
		return 0
	fi
	exit 1
}

require_file() {
	if [ -f "$1" ]; then
		record "$2=PASS"
	else
		fail "$2"
	fi
}

require_grep() {
	if grep -Eq "$2" "$1"; then
		record "$3=PASS"
	else
		fail "$3"
	fi
}

require_silent_grep() {
	grep -Eq "$2" "$1" || fail "$3"
}

require_config() {
	config_line=$(grep -E "^$1=(y|m)$" "$ARTIFACT_DIR/kernel.config" || true)
	if [ -n "$config_line" ]; then
		record "$config_line"
	else
		fail "$1"
	fi
}

require_kernel_config_line() {
	grep -Eq "^$1$" "$ARTIFACT_DIR/kernel.config" || fail "$2"
}

require_manifest_pkg() {
	grep -Eq "^$1([[:space:]]|$)" "$manifest" || fail_full "$2"
}

require_openwrt_config_line() {
	grep -Eq "^$1$" "$ARTIFACT_DIR/openwrt.config" || fail_full "$2"
}

require_no_manifest_pkg() {
	if grep -Eq "^$1([[:space:]]|$)" "$manifest"; then
		fail_full "$2"
	fi
}

require_rtl8189es_artifacts() {
	before=$VALIDATION_FAILURES
	require_file "$ARTIFACT_DIR/rtl8189es.ko" "RTL8189ES_KO"
	require_file "$ARTIFACT_DIR/rtl8189es.build-check.txt" "RTL8189ES_BUILD_CHECK"
	require_grep "$ARTIFACT_DIR/rtl8189es.build-check.txt" 'rtl8189es\.ko=' "RTL8189ES_BUILD_CHECK"
	require_file "$ARTIFACT_DIR/rtl8189es.modules.d" "RTL8189ES_MODULES_D"
	require_grep "$ARTIFACT_DIR/rtl8189es.modules.d" '^rtl8189es$' "RTL8189ES_MODULES_D"
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "RTL8189ES_AUTOLOAD=PASS"
}

verify_requested_manifest_packages() {
	requested_config=$1
	before=$VALIDATION_FAILURES
	if [ ! -f "$requested_config" ]; then
		fail_full "REQUESTED_PACKAGE_CONFIG"
		return
	fi
	packages=$(awk -F= '/^CONFIG_PACKAGE_.*=y$/ { sub(/^CONFIG_PACKAGE_/, "", $1); print $1 }' "$requested_config")
	for pkg in $packages; do
		require_manifest_pkg "$pkg" "REQUESTED_PACKAGE_$pkg"
	done
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "REQUESTED_PACKAGES_FROM_PROFILE=PASS"
}

verify_rtl8189es_compile_warnings() {
	before=$VALIDATION_FAILURES
	# Runs #92 and #93 produced the same normalized legacy warning set.
	baseline_warning_count=581
	require_file "$ARTIFACT_DIR/rtl8189es-compile.status" "RTL8189ES_COMPILE_STATUS"
	require_file "$ARTIFACT_DIR/rtl8189es-compile-warnings.txt" "RTL8189ES_COMPILE_WARNINGS"
	if [ -f "$ARTIFACT_DIR/rtl8189es-compile.status" ] &&
		grep -qx 'clean=0' "$ARTIFACT_DIR/rtl8189es-compile.status" &&
		grep -qx 'compile=0' "$ARTIFACT_DIR/rtl8189es-compile.status"; then
		record_full "RTL8189ES_CLEAN_REBUILD=PASS"
	else
		fail_full "RTL8189ES_CLEAN_REBUILD"
	fi
	if [ -f "$ARTIFACT_DIR/rtl8189es-compile-warnings.txt" ]; then
		warning_count=$(wc -l < "$ARTIFACT_DIR/rtl8189es-compile-warnings.txt" | tr -d '[:space:]')
		record_full "RTL8189ES_WARNING_COUNT=$warning_count"
		if [ "$warning_count" -le "$baseline_warning_count" ]; then
			record_full "RTL8189ES_WARNING_COUNT_WITHIN_RUN92_BASELINE=PASS"
		else
			fail_full "RTL8189ES_NEW_WARNINGS"
		fi
		if grep -Eqi 'implicit declaration' "$ARTIFACT_DIR/rtl8189es-compile-warnings.txt"; then
			fail_full "RTL8189ES_IMPLICIT_DECLARATION"
		else
			record_full "RTL8189ES_IMPLICIT_DECLARATION=ABSENT"
		fi
	else
		fail_full "RTL8189ES_NEW_WARNINGS"
	fi
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "RTL8189ES_COMPILE_GATE=PASS"
}

verify_rtl8189es_image_module() {
	image="$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
	unsquashfs="$SOURCE_DIR/staging_dir/host/bin/unsquashfs4"
	image_sha=$(sha256sum "$image" | awk '{print $1}')
	record_full "FINAL_IMAGE_SHA256=$image_sha"

	if [ ! -x "$unsquashfs" ]; then
		fail_full "UNSQUASHFS4"
		return
	fi
	image_work=$(mktemp -d)
	trap 'rm -rf "$image_work"' 0 1 2 15
	if ! gzip -dc "$image" > "$image_work/sdcard.img"; then
		fail_full "FINAL_IMAGE_DECOMPRESS"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi
	if ! partition=$(
		sfdisk --json "$image_work/sdcard.img" |
			python3 -c 'import json, sys; p = json.load(sys.stdin)["partitiontable"]["partitions"]; print(p[1]["start"], p[1]["size"])'
	); then
		fail_full "ROOTFS_PARTITION"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi
	set -- $partition
	if [ "$#" -ne 2 ]; then
		fail_full "ROOTFS_PARTITION"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi
	if ! dd if="$image_work/sdcard.img" of="$image_work/rootfs.squashfs" \
		bs=512 skip="$1" count="$2" conv=sparse status=none; then
		fail_full "ROOTFS_PARTITION_EXTRACT"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi
	if [ "$PROFILE_KEY" = wifi_release_v1 ]; then
		set -- \
			'lib/modules/*/rtl8189es.ko' \
			'etc/config/wireless' \
			'etc/uci-defaults/99-k1-plus-wifi-release-v1' \
			'etc/profile.d/99-k1-plus-wifi-credentials.sh'
	else
		set -- 'lib/modules/*/rtl8189es.ko'
	fi
	if ! "$unsquashfs" -no-progress -d "$image_work/rootfs" \
		"$image_work/rootfs.squashfs" "$@" >/dev/null; then
		fail_full "ROOTFS_SQUASHFS_EXTRACT"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi

	module_list="$image_work/modules.txt"
	find "$image_work/rootfs/lib/modules" -type f -name rtl8189es.ko -print | sort > "$module_list"
	module_count=$(wc -l < "$module_list" | tr -d '[:space:]')
	if [ "$module_count" -ne 1 ]; then
		fail_full "FINAL_IMAGE_RTL8189ES_COUNT"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi
	module=$(sed -n '1p' "$module_list")
	cp "$module" "$ARTIFACT_DIR/rtl8189es.image.ko"
	sha256sum "$ARTIFACT_DIR/rtl8189es.image.ko" > "$ARTIFACT_DIR/rtl8189es.image.sha256"
	if ! readelf -Ws "$ARTIFACT_DIR/rtl8189es.image.ko" > "$ARTIFACT_DIR/rtl8189es.image.symbols.txt"; then
		fail_full "FINAL_IMAGE_RTL8189ES_READELF"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi
	if ! readelf -rW "$ARTIFACT_DIR/rtl8189es.image.ko" > "$ARTIFACT_DIR/rtl8189es.image.relocations.txt"; then
		fail_full "FINAL_IMAGE_RTL8189ES_RELOCATIONS"
		rm -rf "$image_work"
		trap - 0 1 2 15
		return
	fi

	symbols="$ARTIFACT_DIR/rtl8189es.image.symbols.txt"
	relocations="$ARTIFACT_DIR/rtl8189es.image.relocations.txt"
	if awk '$8 == "rtw_os_ndev_register_ex" && $7 != "UND" { found = 1 } END { exit !found }' "$symbols"; then
		record_full "FINAL_IMAGE_REGISTER_EX=PASS"
	else
		fail_full "FINAL_IMAGE_REGISTER_EX"
	fi
	if awk '$8 == "rtw_os_ndev_unregister_ex" && $7 != "UND" { found = 1 } END { exit !found }' "$symbols"; then
		record_full "FINAL_IMAGE_UNREGISTER_EX=PASS"
	else
		fail_full "FINAL_IMAGE_UNREGISTER_EX"
	fi
	if awk '$8 == "cfg80211_register_netdevice" && $7 == "UND" { found = 1 } END { exit !found }' "$symbols"; then
		record_full "FINAL_IMAGE_CFG80211_REGISTER_NETDEVICE=PASS"
	else
		fail_full "FINAL_IMAGE_CFG80211_REGISTER_NETDEVICE"
	fi
	if awk '$8 == "_rtw_mutex_init" || $8 == "rtw_mutex_init" { found = 1 } END { exit !found }' "$symbols"; then
		fail_full "FINAL_IMAGE_RTW_MUTEX_INIT_WRAPPER_ABSENT"
	else
		record_full "FINAL_IMAGE_RTW_MUTEX_INIT_WRAPPER_ABSENT=PASS"
	fi
	mutex_init_relocations=$(awk '$0 ~ /[[:space:]]__mutex_init([[:space:]]|$)/ { count++ } END { print count + 0 }' "$relocations")
	record_full "FINAL_IMAGE_MUTEX_INIT_RELOCATIONS=$mutex_init_relocations"
	if [ "$mutex_init_relocations" -gt 1 ]; then
		record_full "FINAL_IMAGE_MUTEX_INIT_CALL_SITES=PASS"
	else
		fail_full "FINAL_IMAGE_MUTEX_INIT_CALL_SITES"
	fi
	if awk '$8 == "_rtw_spinlock_init" || $8 == "_rtw_init_queue" || $8 == "rtw_init_timer" || $8 == "_rtw_init_sema" || $8 == "odm_initialize_timer" { found = 1 } END { exit !found }' "$symbols"; then
		fail_full "FINAL_IMAGE_RTW_LOCK_INIT_WRAPPERS_ABSENT"
	else
		record_full "FINAL_IMAGE_RTW_LOCK_INIT_WRAPPERS_ABSENT=PASS"
	fi
	spin_init_relocations=$(awk '$0 ~ /[[:space:]]__raw_spin_lock_init([[:space:]]|$)/ { count++ } END { print count + 0 }' "$relocations")
	record_full "FINAL_IMAGE_SPIN_INIT_RELOCATIONS=$spin_init_relocations"
	if [ "$spin_init_relocations" -gt 1 ]; then
		record_full "FINAL_IMAGE_SPIN_INIT_CALL_SITES=PASS"
	else
		fail_full "FINAL_IMAGE_SPIN_INIT_CALL_SITES"
	fi
	timer_init_relocations=$(awk '$0 ~ /[[:space:]]timer_init_key([[:space:]]|$)/ { count++ } END { print count + 0 }' "$relocations")
	record_full "FINAL_IMAGE_TIMER_INIT_RELOCATIONS=$timer_init_relocations"
	if [ "$timer_init_relocations" -gt 2 ]; then
		record_full "FINAL_IMAGE_TIMER_INIT_CALL_SITES=PASS"
	else
		fail_full "FINAL_IMAGE_TIMER_INIT_CALL_SITES"
	fi

	if [ "$PROFILE_KEY" = wifi_release_v1 ]; then
		release_wireless="$image_work/rootfs/etc/config/wireless"
		release_policy="$image_work/rootfs/etc/uci-defaults/99-k1-plus-wifi-release-v1"
		release_hint="$image_work/rootfs/etc/profile.d/99-k1-plus-wifi-credentials.sh"
		for file in "$release_wireless" "$release_policy" "$release_hint"; do
			[ -f "$file" ] || fail_full "FINAL_IMAGE_WIFI_RELEASE_FILES"
		done
		if [ -f "$release_wireless" ]; then
			cp "$release_wireless" "$ARTIFACT_DIR/k1-plus-wireless-config.image"
			require_grep "$release_wireless" "^[[:space:]]*option network 'lan'$" "FINAL_IMAGE_WIFI_NETWORK_LAN"
			require_grep "$release_wireless" "^[[:space:]]*option encryption 'psk2\+ccmp'$" "FINAL_IMAGE_WIFI_WPA2_CCMP"
			require_grep "$release_wireless" "^[[:space:]]*option disabled '1'$" "FINAL_IMAGE_WIFI_DISABLED_SEED"
			if grep -Eq "^[[:space:]]*option key " "$release_wireless"; then
				fail_full "FINAL_IMAGE_STATIC_WIFI_KEY"
			else
				record_full "FINAL_IMAGE_STATIC_WIFI_KEY=ABSENT"
			fi
		fi
		if [ -f "$release_policy" ]; then
			cp "$release_policy" "$ARTIFACT_DIR/k1-plus-wifi-release-v1-policy.image"
			if [ -x "$release_policy" ]; then
				record_full "FINAL_IMAGE_WIFI_RELEASE_SCRIPT_EXECUTABLE=PASS"
			else
				fail_full "FINAL_IMAGE_WIFI_RELEASE_SCRIPT_EXECUTABLE"
			fi
			require_grep "$release_policy" '/dev/urandom' "FINAL_IMAGE_RANDOM_PASSWORD"
			require_grep "$release_policy" 'passwd root' "FINAL_IMAGE_ROOT_PASSWORD"
			require_grep "$release_policy" '/root/WIFI-PASSWORD.txt' "FINAL_IMAGE_CREDENTIAL_FILE"
			require_grep "$release_policy" "config device 'br_lan'" "FINAL_IMAGE_BR_LAN_DEVICE"
			require_grep "$release_policy" "list ports 'eth0'" "FINAL_IMAGE_BR_LAN_ETH0"
			require_grep "$release_policy" "option device 'br-lan'" "FINAL_IMAGE_LAN_USES_BRIDGE"
			require_grep "$release_policy" "set wireless.default_radio0.network='lan'" "FINAL_IMAGE_WIFI_UCI_LAN"
			require_grep "$release_policy" "uhttpd.main.listen_http='192.168.1.1:80'" "FINAL_IMAGE_UHTTPD_LAN_HTTP"
			require_grep "$release_policy" '/etc/wifi-release-done' "FINAL_IMAGE_WIFI_RELEASE_MARKER"
			lan_ip_count=$(grep -Fc "option ipaddr '192.168.1.1'" "$release_policy" || true)
			bridge_port_count=$(grep -Fc "list ports 'eth0'" "$release_policy" || true)
			if [ "$lan_ip_count" -eq 1 ] && [ "$bridge_port_count" -eq 1 ] &&
				! grep -Fq "option device 'eth0'" "$release_policy"; then
				record_full "FINAL_IMAGE_NETWORK_TOPOLOGY_UNIQUE=PASS"
			else
				fail_full "FINAL_IMAGE_NETWORK_TOPOLOGY_UNIQUE"
			fi
		fi
		if [ -f "$release_hint" ]; then
			cp "$release_hint" "$ARTIFACT_DIR/k1-plus-wifi-credentials-hint.image"
		fi
		if grep -REq "nanopi-k1plus|wpa_passphrase=|^[[:space:]]*option key '" \
			"$image_work/rootfs/etc/config" "$image_work/rootfs/etc/uci-defaults" "$image_work/rootfs/etc/profile.d"; then
			fail_full "FINAL_IMAGE_HARDCODED_PASSWORD"
		else
			record_full "FINAL_IMAGE_HARDCODED_PASSWORD=ABSENT"
		fi
	fi

	rm -rf "$image_work"
	trap - 0 1 2 15
}

resolve_image_files() {
	image_candidates=$(
		find "$ARTIFACT_DIR" -maxdepth 1 -type f \
			\( \
				-name 'NanoPi-K1-Plus-sunxi-cortexa53.img.gz' -o \
				-name '*friendlyarm_nanopi-k1-plus*sdcard.img.gz' -o \
				-name '*nanopi-k1-plus*sdcard.img.gz' \
			\) \
			-print |
			sort
	)
	[ -n "$image_candidates" ] || fail "K1_PLUS_IMAGE"
	printf '%s\n' "$image_candidates"
}

record_profile_header() {
	record_full "PROFILE=$PROFILE_LABEL"
}

verify_base_profile() {
	record_profile_header
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=512' "ROOTFS_PARTSIZE"
	record "ROOTFS_PARTSIZE=512"
	record_full "ROOTFS_PARTSIZE=512"

	for pkg in luci luci-app-package-manager; do
		require_manifest_pkg "$pkg" "LUCI"
	done
	record_full "LUCI=PASS"

	require_manifest_pkg luci-i18n-base-zh-cn "LUCI_ZH_CN"
	record_full "LUCI_ZH_CN=PASS"

	require_manifest_pkg kmod-usb-hid "USB_HID"
	record_full "USB_HID=PASS"

	require_manifest_pkg kmod-usb-storage "USB_STORAGE"
	record_full "USB_STORAGE=PASS"

	for pkg in kmod-fs-ext4 kmod-fs-vfat kmod-fs-exfat kmod-fs-ntfs3; do
		require_manifest_pkg "$pkg" "FILESYSTEMS"
	done
	record_full "FILESYSTEMS=PASS"

	for pkg in nano curl wget-ssl htop ethtool iperf3 usbutils evtest libdrm-tests; do
		require_manifest_pkg "$pkg" "HARDWARE_TOOLS"
	done
	record_full "HARDWARE_TOOLS=PASS"

	for pkg in kmod-rtl8189es wpad-openssl wireless-regdb kmod-bluetooth kmod-btusb bluez-daemon; do
		require_no_manifest_pkg "$pkg" "EXCLUDED_COMPONENTS"
	done
	record_full "EXCLUDED_COMPONENTS=PASS"
	record_full "BASE_PROFILE_VERIFY=PASS"
}

verify_full_profile() {
	record_profile_header
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=4096' "ROOTFS_PARTSIZE"
	record "ROOTFS_PARTSIZE=4096"
	record_full "ROOTFS_PARTSIZE=4096"

	# Package names are from the Full validation artifact 29146205553
	# `enabled-packages.txt`.
	for pkg in luci luci-app-package-manager; do
		require_manifest_pkg "$pkg" "LUCI"
	done
	record_full "LUCI=PASS"

	require_manifest_pkg luci-ssl-openssl "LUCI_HTTPS"
	record_full "LUCI_HTTPS=PASS"

	for pkg in \
		luci-i18n-base-zh-cn \
		luci-i18n-package-manager-zh-cn \
		luci-i18n-argon-config-zh-cn \
		luci-i18n-ttyd-zh-cn \
		luci-i18n-commands-zh-cn \
		luci-i18n-filebrowser-zh-cn \
		luci-i18n-diskman-zh-cn \
		luci-i18n-samba4-zh-cn \
		luci-i18n-statistics-zh-cn \
		luci-i18n-watchcat-zh-cn; do
		require_manifest_pkg "$pkg" "LUCI_ZH_CN"
	done
	record_full "LUCI_ZH_CN=PASS"

	for pkg in ttyd luci-app-ttyd; do
		require_manifest_pkg "$pkg" "TTYD"
	done
	record_full "TTYD=PASS"

	require_manifest_pkg kmod-usb-hid "USB_HID"
	record_full "USB_HID=PASS"

	require_manifest_pkg kmod-usb-storage "USB_STORAGE"
	record_full "USB_STORAGE=PASS"

	require_manifest_pkg kmod-usb-storage-uas "USB_UAS"
	record_full "USB_UAS=PASS"

	require_manifest_pkg kmod-fs-ext4 "FILESYSTEM_EXT4"
	record_full "FILESYSTEM_EXT4=PASS"

	require_manifest_pkg kmod-fs-vfat "FILESYSTEM_VFAT"
	record_full "FILESYSTEM_VFAT=PASS"

	require_manifest_pkg kmod-fs-exfat "FILESYSTEM_EXFAT"
	record_full "FILESYSTEM_EXFAT=PASS"

	require_manifest_pkg kmod-fs-ntfs3 "FILESYSTEM_NTFS3"
	record_full "FILESYSTEM_NTFS3=PASS"

	for pkg in samba4-server luci-app-samba4 wsdd2; do
		require_manifest_pkg "$pkg" "SAMBA4"
	done
	record_full "SAMBA4=PASS"

	require_manifest_pkg openssh-sftp-server "SFTP"
	record_full "SFTP=PASS"

	for pkg in kmod-bluetooth kmod-btusb; do
		require_manifest_pkg "$pkg" "USB_BLUETOOTH"
	done
	record_full "USB_BLUETOOTH=PASS"

	for pkg in bluez-daemon bluez-utils bluez-utils-extra; do
		require_manifest_pkg "$pkg" "BLUEZ"
	done
	record_full "BLUEZ=PASS"

	for pkg in \
		kmod-usb-serial-ch341 \
		kmod-usb-serial-cp210x \
		kmod-usb-serial-ftdi \
		kmod-usb-serial-pl2303; do
		require_manifest_pkg "$pkg" "USB_SERIAL"
	done
	record_full "USB_SERIAL=PASS"

	for pkg in kmod-usb-net-rtl8152 kmod-usb-net-asix kmod-usb-net-asix-ax88179; do
		require_manifest_pkg "$pkg" "USB_ETHERNET"
	done
	record_full "USB_ETHERNET=PASS"

	require_manifest_pkg libdrm-tests "DRM_TESTS"
	record_full "DRM_TESTS=PASS"

	require_manifest_pkg evtest "EVTEST"
	record_full "EVTEST=PASS"

	for pkg in \
		mmc-utils \
		i2c-tools \
		gpiod-tools \
		usbutils \
		ethtool \
		iperf3 \
		tcpdump \
		ip-full \
		lsof \
		strace; do
		require_manifest_pkg "$pkg" "HARDWARE_TOOLS"
	done
	record_full "HARDWARE_TOOLS=PASS"

	for pkg in \
		luci-app-statistics \
		collectd-mod-cpu \
		collectd-mod-cpufreq \
		collectd-mod-thermal \
		collectd-mod-memory \
		collectd-mod-load \
		collectd-mod-interface \
		collectd-mod-uptime; do
		require_manifest_pkg "$pkg" "STATISTICS"
	done
	record_full "STATISTICS=PASS"

	for pkg in luci-app-watchcat watchcat; do
		require_manifest_pkg "$pkg" "WATCHCAT"
	done
	record_full "WATCHCAT=PASS"

	for pkg in kmod-rtl8189es wpad-openssl wireless-regdb; do
		require_no_manifest_pkg "$pkg" "WIFI"
	done
	record_full "WIFI=INTENTIONALLY_EXCLUDED"
	record_full "FULL_PROFILE_VERIFY=PASS"
}

verify_wifi_compat_profile() {
	record_profile_header
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=1024' "ROOTFS_PARTSIZE"
	record "ROOTFS_PARTSIZE=1024"
	record_full "ROOTFS_PARTSIZE=1024"

	for pkg in luci luci-app-package-manager; do
		require_manifest_pkg "$pkg" "LUCI"
	done
	record_full "LUCI=PASS"

	require_manifest_pkg luci-i18n-base-zh-cn "LUCI_ZH_CN"
	record_full "LUCI_ZH_CN=PASS"

	for pkg in \
		kmod-rtl8189es \
		wpad-openssl \
		wireless-regdb \
		iwinfo; do
		require_manifest_pkg "$pkg" "WIFI_STACK"
	done
	record_full "WIFI_STACK=PASS"
	require_rtl8189es_artifacts

	for pkg in kmod-usb-hid kmod-usb-storage; do
		require_manifest_pkg "$pkg" "USB_BASE"
	done
	record_full "USB_BASE=PASS"

	for pkg in kmod-fs-ext4 kmod-fs-vfat kmod-fs-exfat kmod-fs-ntfs3; do
		require_manifest_pkg "$pkg" "FILESYSTEMS"
	done
	record_full "FILESYSTEMS=PASS"

	for pkg in nano curl wget-ssl htop ethtool iperf3 usbutils evtest libdrm-tests; do
		require_manifest_pkg "$pkg" "HARDWARE_TOOLS"
	done
	record_full "HARDWARE_TOOLS=PASS"

	require_file "$ARTIFACT_DIR/k1-plus-wifi-compat-lan-policy" "WIFI_COMPAT_LAN_POLICY"
	require_grep "$ARTIFACT_DIR/k1-plus-wifi-compat-lan-policy" '^cat > /etc/config/network <<EOF$' "WIFI_COMPAT_LAN_POLICY"
	require_grep "$ARTIFACT_DIR/k1-plus-wifi-compat-lan-policy" "^[[:space:]]*option device 'eth0'$" "WIFI_COMPAT_LAN_POLICY"
	require_grep "$ARTIFACT_DIR/k1-plus-wifi-compat-lan-policy" "^[[:space:]]*option ipaddr '192\\.168\\.1\\.1'$" "WIFI_COMPAT_LAN_POLICY"
	record_full "LAN_POLICY=COMPAT_ETH0_192.168.1.1"

	for pkg in \
		luci-app-watchcat \
		watchcat \
		kmod-bluetooth \
		kmod-btusb \
		bluez-daemon \
		openssh-server \
		samba4-server; do
		require_no_manifest_pkg "$pkg" "EXCLUDED_COMPONENTS"
	done
	record_full "EXCLUDED_COMPONENTS=PASS"
	record_full "WIFI_COMPAT_PROFILE_VERIFY=PASS"
}

verify_wifi_compat_v2_profile() {
	profile_before=$VALIDATION_FAILURES
	record_profile_header
	before=$VALIDATION_FAILURES
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=1024' "ROOTFS_PARTSIZE"
	if [ "$VALIDATION_FAILURES" -eq "$before" ]; then
		record "ROOTFS_PARTSIZE=1024"
		record_full "ROOTFS_PARTSIZE=1024"
	fi

	before=$VALIDATION_FAILURES
	for pkg in \
		kmod-rtl8189es \
		wpad-openssl \
		wireless-regdb \
		iwinfo; do
		require_manifest_pkg "$pkg" "WIFI_STACK_$pkg"
	done
	if [ "$PROFILE_KEY" = wifi_compat_v3 ]; then
		require_no_manifest_pkg rpcd-mod-iwinfo "RPCD_MOD_IWINFO"
		record_full "RPCD_MOD_IWINFO=INTENTIONALLY_EXCLUDED_NO_LUCI"
	else
		require_manifest_pkg rpcd-mod-iwinfo "WIFI_STACK_rpcd-mod-iwinfo"
	fi
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "WIFI_STACK=PASS"
	require_rtl8189es_artifacts

	before=$VALIDATION_FAILURES
	for pkg in kmod-usb-hid kmod-usb-storage; do
		require_manifest_pkg "$pkg" "USB_BASE_$pkg"
	done
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "USB_BASE=PASS"

	before=$VALIDATION_FAILURES
	for pkg in kmod-fs-ext4 kmod-fs-vfat kmod-fs-exfat kmod-fs-ntfs3; do
		require_manifest_pkg "$pkg" "FILESYSTEMS_$pkg"
	done
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "FILESYSTEMS=PASS"

	before=$VALIDATION_FAILURES
	tool_packages='nano curl wget-ssl htop ethtool iperf3 evtest'
	[ "$PROFILE_KEY" = wifi_compat_v3 ] || tool_packages="$tool_packages usbutils libdrm-tests"
	for pkg in $tool_packages; do
		require_manifest_pkg "$pkg" "HARDWARE_TOOLS_$pkg"
	done
	if [ "$PROFILE_KEY" = wifi_compat_v3 ]; then
		record_full "UNAVAILABLE_TOOL_PACKAGES=usbutils,libdrm-tests"
	fi
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "HARDWARE_TOOLS=PASS"

	if [ "$PROFILE_KEY" = wifi_compat_v3 ]; then
		policy_file="$ARTIFACT_DIR/k1-plus-wifi-compat-v3-policy"
		policy_check=WIFI_COMPAT_V3_POLICY
	else
		policy_file="$ARTIFACT_DIR/k1-plus-wifi-compat-v2-policy"
		policy_check=WIFI_COMPAT_V2_POLICY
	fi
	before=$VALIDATION_FAILURES
	require_file "$policy_file" "$policy_check"
	require_grep "$policy_file" "^[[:space:]]*option device 'eth0'$" "$policy_check"
	require_grep "$policy_file" "^[[:space:]]*option ipaddr '192\\.168\\.1\\.1'$" "$policy_check"
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "LAN_POLICY=DIRECT_ETH0_STATIC_192.168.1.1"

	before=$VALIDATION_FAILURES
	require_file "$ARTIFACT_DIR/k1-plus-wireless-config" "WIRELESS_CONFIG"
	require_grep "$ARTIFACT_DIR/k1-plus-wireless-config" "^config wifi-device 'radio0'$" "WIRELESS_CONFIG"
	require_grep "$ARTIFACT_DIR/k1-plus-wireless-config" "^[[:space:]]*option phy 'phy0'$" "WIRELESS_CONFIG"
	require_grep "$ARTIFACT_DIR/k1-plus-wireless-config" "^[[:space:]]*option ssid 'NanoPi-K1-Plus'$" "WIRELESS_CONFIG"
	require_grep "$ARTIFACT_DIR/k1-plus-wireless-config" "^[[:space:]]*option encryption 'psk2'$" "WIRELESS_CONFIG"
	if [ "$PROFILE_KEY" = wifi_compat_v3 ]; then
		disabled_count=$(grep -Ec "^[[:space:]]*option disabled '1'$" "$ARTIFACT_DIR/k1-plus-wireless-config" || true)
		[ "$disabled_count" -eq 2 ] || fail_full "WIRELESS_CONFIG_DISABLED"
		if grep -Eq "^[[:space:]]*option disabled '0'$" "$ARTIFACT_DIR/k1-plus-wireless-config"; then
			fail_full "WIRELESS_CONFIG_DISABLED"
		fi
		if [ "$VALIDATION_FAILURES" -eq "$before" ]; then
			record_full "WIRELESS_CONFIG=PHY0_SINGLE_RADIO_DISABLED_WPA2_AP"
			record_full "WIFI_AP_RUNTIME_PATCH=CREATE_AND_DELETE_VIRTUAL_INTERFACE"
		fi
	else
		require_grep "$ARTIFACT_DIR/k1-plus-wireless-config" "^[[:space:]]*option disabled '0'$" "WIRELESS_CONFIG_AP_ENABLED"
		if [ "$VALIDATION_FAILURES" -eq "$before" ]; then
			record_full "WIRELESS_CONFIG=PHY0_SINGLE_RADIO_ENABLED_WPA2_AP"
			record_full "WIFI_AP_RUNTIME_PATCH=REUSE_EXISTING_WLAN0"
		fi
	fi
	if grep -Eq "^[[:space:]]*option path " "$ARTIFACT_DIR/k1-plus-wireless-config"; then
		fail_full "WIRELESS_CONFIG_PATH"
	fi
	before=$VALIDATION_FAILURES
	for pkg in \
		luci-app-watchcat \
		watchcat \
		kmod-bluetooth \
		kmod-btusb \
		bluez-daemon \
		openssh-server \
		samba4-server; do
		require_no_manifest_pkg "$pkg" "EXCLUDED_COMPONENTS_$pkg"
	done
	[ "$VALIDATION_FAILURES" -ne "$before" ] || record_full "EXCLUDED_COMPONENTS=PASS"
	if [ "$PROFILE_KEY" = wifi_compat_v3 ]; then
		verify_rtl8189es_image_module
		if [ "$VALIDATION_FAILURES" -eq "$profile_before" ]; then
			record_full "WIFI_COMPAT_V3_PROFILE_VERIFY=PASS"
		else
			record_full "WIFI_COMPAT_V3_PROFILE_VERIFY=FAIL"
		fi
	else
		record_full "WIFI_COMPAT_V2_PROFILE_VERIFY=PASS"
	fi
}

verify_wifi_release_v1_profile() {
	profile_before=$VALIDATION_FAILURES
	record_profile_header
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=1024' "ROOTFS_PARTSIZE"
	verify_requested_manifest_packages "configs/NanoPi_K1_Plus_wifi_release_v1.config"
	require_rtl8189es_artifacts
	verify_rtl8189es_compile_warnings

	for symbol in PROVE_LOCKING LOCKDEP DEBUG_LOCK_ALLOC DEBUG_MUTEXES DEBUG_SPINLOCK; do
		require_kernel_config_line "# CONFIG_${symbol} is not set" "KERNEL_CONFIG_${symbol}_DISABLED"
	done
	require_openwrt_config_line '# CONFIG_KERNEL_PROVE_LOCKING is not set' "OPENWRT_CONFIG_KERNEL_PROVE_LOCKING_DISABLED"

	require_file "$ARTIFACT_DIR/k1-plus-wifi-release-v1-policy" "WIFI_RELEASE_POLICY"
	require_file "$ARTIFACT_DIR/k1-plus-wifi-credentials-hint" "WIFI_CREDENTIAL_HINT"
	require_file "$ARTIFACT_DIR/k1-plus-wireless-config" "WIRELESS_CONFIG"
	require_grep "$ARTIFACT_DIR/k1-plus-wireless-config" "^[[:space:]]*option network 'lan'$" "WIRELESS_CONFIG_NETWORK_LAN"
	require_grep "$ARTIFACT_DIR/k1-plus-wifi-release-v1-policy" "option device 'br-lan'" "WIFI_RELEASE_BR_LAN"
	require_grep "$ARTIFACT_DIR/k1-plus-wifi-release-v1-policy" "uhttpd.main.listen_http='192.168.1.1:80'" "WIFI_RELEASE_UHTTPD_LAN_HTTP"

	verify_rtl8189es_image_module
	if [ "$VALIDATION_FAILURES" -eq "$profile_before" ]; then
		record_full "WIFI_RELEASE_V1_PROFILE_VERIFY=PASS"
	else
		record_full "WIFI_RELEASE_V1_PROFILE_VERIFY=FAIL"
	fi
}

verify_rtl8189es_inert_profile() {
	record_profile_header
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=4096' "ROOTFS_PARTSIZE"
	record "ROOTFS_PARTSIZE=4096"
	record_full "ROOTFS_PARTSIZE=4096"

	for pkg in luci luci-app-package-manager luci-i18n-base-zh-cn; do
		require_manifest_pkg "$pkg" "LUCI"
	done
	record_full "LUCI=PASS"

	for pkg in ttyd luci-app-ttyd samba4-server luci-app-samba4 ethtool iperf3 tcpdump ip-full; do
		require_manifest_pkg "$pkg" "FULL_BASELINE_PAYLOAD"
	done
	record_full "FULL_BASELINE_PAYLOAD=PASS"

	require_manifest_pkg kmod-rtl8189es "RTL8189ES"
	record_full "RTL8189ES=PASS"
	require_rtl8189es_artifacts

	require_file "$ARTIFACT_DIR/rtl8189es-uci-defaults-50_rtl-wifi" "RTL8189ES_DEFAULT_SCRIPT"
	if grep -Eq 'sed -i|ip link set dev wlan0 up|ip link show dev wlan0|wifi up|hostapd' \
		"$ARTIFACT_DIR/rtl8189es-uci-defaults-50_rtl-wifi"; then
		fail_full "RTL8189ES_DEFAULT_SCRIPT_INERT"
	fi
	require_grep "$ARTIFACT_DIR/rtl8189es-uci-defaults-50_rtl-wifi" '^exit 0$' "RTL8189ES_DEFAULT_SCRIPT_INERT"
	record_full "RTL8189ES_DEFAULT_SCRIPT=INERT"

	for pkg in wpad-openssl hostapd hostapd-utils iwinfo; do
		require_no_manifest_pkg "$pkg" "AP_USERSPACE_EXCLUDED"
	done
	record_full "AP_USERSPACE_EXCLUDED=PASS"

	if [ -f "$ARTIFACT_DIR/k1-plus-wireless-config" ] || \
		[ -f "$ARTIFACT_DIR/k1-plus-wifi-compat-lan-policy" ] || \
		[ -f "$ARTIFACT_DIR/k1-plus-wifi-compat-v2-policy" ]; then
		fail_full "NO_WIFI_OVERLAY_OR_NETWORK_REWRITE"
	fi
	record_full "NO_WIFI_OVERLAY_OR_NETWORK_REWRITE=PASS"
	record_full "LAN_POLICY=BOARD_D_ETH0_CONFIG_GENERATE"
	record_full "CFG80211_DEPS=EXPECTED_WITH_RTL8189ES"
	record_full "RTL8189ES_INERT_PROFILE_VERIFY=PASS"
}

verify_buddha_profile() {
	record_profile_header
	require_openwrt_config_line 'CONFIG_TARGET_ROOTFS_PARTSIZE=8192' "ROOTFS_PARTSIZE"
	record "ROOTFS_PARTSIZE=8192"
	record_full "ROOTFS_PARTSIZE=8192"

	for pkg in \
		luci \
		luci-app-package-manager \
		luci-i18n-base-zh-cn \
		luci-ssl-openssl \
		ttyd \
		luci-app-ttyd \
		luci-app-commands \
		luci-app-filebrowser \
		luci-app-diskman \
		luci-app-firewall \
		samba4-server \
		luci-app-samba4 \
		openssh-sftp-server \
		openssh-sftp-client \
		luci-app-ddns \
		ddns-scripts \
		ddns-scripts-services \
		ddns-scripts-utils \
		fdisk \
		cfdisk \
		htop \
		usbutils; do
		require_manifest_pkg "$pkg" "BUDDHA_SOFTWARE"
	done
	record_full "BUDDHA_SOFTWARE=PASS"

	for pkg in \
		luci-theme-bootstrap \
		luci-theme-argon; do
		require_manifest_pkg "$pkg" "BUDDHA_THEMES"
	done
	record_full "BUDDHA_THEMES=PASS"

	for pkg in \
		ddns-scripts-cloudflare \
		ddns-scripts-cnkuai \
		ddns-scripts-digitalocean \
		ddns-scripts-dnspod \
		ddns-scripts-dnspod-v3 \
		ddns-scripts-freedns \
		ddns-scripts-gandi \
		ddns-scripts-gcp \
		ddns-scripts-godaddy \
		ddns-scripts-huaweicloud \
		ddns-scripts-luadns \
		ddns-scripts-noip \
		ddns-scripts-ns1 \
		ddns-scripts-nsupdate \
		ddns-scripts-one \
		ddns-scripts-pdns \
		ddns-scripts-porkbun \
		ddns-scripts-route53; do
		require_manifest_pkg "$pkg" "DDNS_PROVIDERS"
	done
	record_full "DDNS_PROVIDERS=PASS"

	require_no_manifest_pkg kmod-rtl8189es "WIFI"
	record_full "WIFI=INTENTIONALLY_EXCLUDED"
	record_full "BUDDHA_PROFILE_VERIFY=PASS"
}

IMAGE_FILES=$(resolve_image_files)
record "K1_PLUS_IMAGE=PASS"
printf '%s\n' "$IMAGE_FILES" | while IFS= read -r image_file; do
	[ -n "$image_file" ] || continue
	record "K1_PLUS_IMAGE_FILE=$(basename "$image_file")"
done

test -f "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb"
test -f "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts"
test -f "$ARTIFACT_DIR/sha256sums"
test -f "$ARTIFACT_DIR/kernel.config"
test -f "$ARTIFACT_DIR/openwrt.config"

[ -f "$ARTIFACT_DIR/dtb-source.txt" ] || fail "LINUX_DTB_SOURCE"
dtb_source=$(sed -n '1p' "$ARTIFACT_DIR/dtb-source.txt")
case "$dtb_source" in
	*/linux-sunxi_cortexa53/linux-*/arch/arm64/boot/dts/allwinner/sun50i-h5-nanopi-k1-plus.dtb) ;;
	*) fail "LINUX_DTB_SOURCE" ;;
esac
record "LINUX_DTB_SOURCE=$dtb_source"

[ -f "$ARTIFACT_DIR/kernel-config-source.txt" ] || fail "KERNEL_CONFIG_SOURCE"
kernel_config_source=$(sed -n '1p' "$ARTIFACT_DIR/kernel-config-source.txt")
case "$kernel_config_source" in
	*/linux-sunxi_cortexa53/linux-*/.config) ;;
	*) fail "KERNEL_CONFIG_SOURCE" ;;
esac
record "KERNEL_CONFIG_SOURCE=$kernel_config_source"

for file in config.buildinfo feeds.buildinfo version.buildinfo; do
	[ -f "$ARTIFACT_DIR/$file" ] || { echo "$file missing" >&2; exit 1; }
done

manifest=$(
	find "$ARTIFACT_DIR" -maxdepth 1 -type f \( -name 'packages.manifest' -o -name '*.manifest' \) -print |
		sort |
		head -n 1
)
if [ -z "$manifest" ]; then
	fail "PACKAGE_MANIFEST"
fi

require_file "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb" "K1_PLUS_DTB"
require_file "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" "COMPILED_DTS"
require_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" 'compatible = "hdmi-connector"' "HDMI_CONNECTOR_NODE"
require_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" 'allwinner,sun8i-h3-dw-hdmi' "HDMI_DW_NODE"

require_file "$ARTIFACT_DIR/uEnv-a64.txt" "UENV_A64"
require_grep "$ARTIFACT_DIR/uEnv-a64.txt" 'console=ttyS0,115200' "CONSOLE_TTYS0"
require_grep "$ARTIFACT_DIR/uEnv-a64.txt" 'console=tty1' "CONSOLE_TTY1"

require_file "$ARTIFACT_DIR/sunxi-inittab" "SUNXI_INITTAB"
require_grep "$ARTIFACT_DIR/sunxi-inittab" '^ttyS0::askfirst:' "LOGIN_TTYS0"
require_grep "$ARTIFACT_DIR/sunxi-inittab" '^tty1::askfirst:' "LOGIN_TTY1"

require_config CONFIG_DRM_SUN4I
require_config CONFIG_FRAMEBUFFER_CONSOLE
require_config CONFIG_VT_CONSOLE
require_config CONFIG_USB_HID
require_config CONFIG_HID_GENERIC
require_config CONFIG_INPUT_EVDEV
require_config CONFIG_PINCTRL_SUN8I_H3_R
require_config CONFIG_CMA
require_config CONFIG_DMA_CMA
require_config CONFIG_CPUFREQ_DT
require_config CONFIG_REGULATOR_SY8106A
require_kernel_config_line 'CONFIG_CMA_SIZE_MBYTES=64' "CMA_SIZE"

require_silent_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" 'pinctrl@1f02c00' "R_PIO_DTS"
require_silent_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" 'allwinner,sun8i-h3-r-pinctrl' "R_PIO_DTS"
record "R_PIO_VERIFY=PASS"

for pin in PL2 PL3 PL7 PL10; do
	require_silent_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" "pins = \"$pin\"" "PL_GPIO_$pin"
done
record "PL_GPIO_VERIFY=PASS"

for pattern in \
	'usb0-vbus' \
	'usb0_vbus-supply' \
	'phy@1c19400' \
	'allwinner,sun8i-h3-usb-phy'; do
	require_silent_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" "$pattern" "USB_VBUS_DTS"
done
record "USB_VBUS_DTS_VERIFY=PASS"

for pattern in \
	'i2c@1f02400' \
	'pins = "PL0\\0PL1"' \
	'silergy,sy8106a' \
	'regulator@65'; do
	require_silent_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" "$pattern" "R_I2C_DTS"
done
record "R_I2C_DTS_VERIFY=PASS"
record "CPUFREQ_CONFIG_VERIFY=PASS"
record "CMA_VERIFY=PASS"

require_file "$ARTIFACT_DIR/k1-plus-mmc-cross-mount-policy" "MMC_CROSS_MOUNT_POLICY"
require_silent_grep "$ARTIFACT_DIR/k1-plus-mmc-cross-mount-policy" "anon_mount='0'" "MMC_CROSS_MOUNT_POLICY"
require_silent_grep "$ARTIFACT_DIR/k1-plus-mmc-cross-mount-policy" "auto_mount='0'" "MMC_CROSS_MOUNT_POLICY"
record "MMC_CROSS_MOUNT_POLICY_VERIFY=PASS"

if [ -n "$manifest" ]; then
	require_grep "$manifest" '^kmod-usb-hid([[:space:]]|$)' "MANIFEST_KMOD_USB_HID"
fi

if [ "$PROFILE_KEY" = wifi_compat_v3 ] || [ "$PROFILE_KEY" = wifi_release_v1 ]; then
	COLLECT_ALL=1
fi
case "$PROFILE_KEY" in
	base) verify_base_profile ;;
	full) verify_full_profile ;;
	wifi_compat) verify_wifi_compat_profile ;;
	wifi_compat_v2|wifi_compat_v3) verify_wifi_compat_v2_profile ;;
	wifi_release_v1) verify_wifi_release_v1_profile ;;
	rtl8189es_inert) verify_rtl8189es_inert_profile ;;
	buddha) verify_buddha_profile ;;
esac

printf '%s\n' "$IMAGE_FILES" | while IFS= read -r image_file; do
	[ -n "$image_file" ] || continue
	gzip -t "$image_file"
done
(cd "$ARTIFACT_DIR" && sha256sum -c sha256sums)
if [ "$VALIDATION_FAILURES" -ne 0 ]; then
	record "STAGE_A_DISPLAY_VERIFY=FAIL"
	echo "IMAGE_VERIFY=FAIL ($VALIDATION_FAILURES checks failed)" >&2
	exit 1
fi
record "STAGE_A_DISPLAY_VERIFY=PASS"
echo 'IMAGE_VERIFY=PASS'
