#!/bin/sh
set -eu

ARTIFACT_DIR=${1:?artifact directory is required}
PROFILE=${2:-${BUILD_PROFILE:-default}}
VALIDATION_FILE="$ARTIFACT_DIR/stage-a-display-validation.txt"

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
	exit 1
}

fail_full() {
	record_full "$1=FAIL"
	echo "$1 missing or invalid" >&2
	exit 1
}

require_file() {
	[ -f "$1" ] || fail "$2"
	record "$2=PASS"
}

require_grep() {
	grep -Eq "$2" "$1" || fail "$3"
	record "$3=PASS"
}

require_silent_grep() {
	grep -Eq "$2" "$1" || fail "$3"
}

require_config() {
	config_line=$(grep -E "^$1=(y|m)$" "$ARTIFACT_DIR/kernel.config" || true)
	[ -n "$config_line" ] || fail "$1"
	record "$config_line"
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
		iwinfo \
		rpcd-mod-iwinfo; do
		require_manifest_pkg "$pkg" "WIFI_STACK"
	done
	record_full "WIFI_STACK=PASS"

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
		tailscale \
		luci-app-tailscale \
		zerotier \
		luci-app-zerotier \
		luci-app-ddns \
		ddns-scripts \
		ddns-scripts-services \
		ddns-scripts-utils \
		luci-app-homeproxy \
		luci-app-mosdns \
		luci-app-nikki \
		luci-app-openclash \
		luci-app-passwall \
		luci-app-passwall2 \
		luci-app-ssr-plus \
		luci-app-vlmcsd \
		luci-app-momo \
		netdata \
		netperf \
		bind-ddns-confgen \
		fdisk \
		cfdisk \
		htop \
		usbutils; do
		require_manifest_pkg "$pkg" "BUDDHA_SOFTWARE"
	done
	record_full "BUDDHA_SOFTWARE=PASS"

	for pkg in \
		luci-theme-bootstrap \
		luci-theme-edge \
		luci-theme-lightblue; do
		require_manifest_pkg "$pkg" "BUDDHA_THEMES"
	done
	record_full "BUDDHA_THEMES=PASS"

	for pkg in \
		ddns-scripts_aliyun \
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
		ddns-scripts-route53 \
		ddns-scripts-transip; do
		require_manifest_pkg "$pkg" "DDNS_PROVIDERS"
	done
	record_full "DDNS_PROVIDERS=PASS"

	require_no_manifest_pkg kmod-rtl8189es "WIFI"
	record_full "WIFI=INTENTIONALLY_EXCLUDED"
	record_full "BUDDHA_PROFILE_VERIFY=PASS"
}

test -f "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
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

case "$PROFILE_KEY" in
	base) verify_base_profile ;;
	full) verify_full_profile ;;
	wifi_compat) verify_wifi_compat_profile ;;
	buddha) verify_buddha_profile ;;
esac

gzip -t "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
(cd "$ARTIFACT_DIR" && sha256sum -c sha256sums)
record "STAGE_A_DISPLAY_VERIFY=PASS"
echo 'IMAGE_VERIFY=PASS'
