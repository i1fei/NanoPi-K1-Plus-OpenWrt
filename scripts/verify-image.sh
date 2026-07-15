#!/bin/sh
set -eu

ARTIFACT_DIR=${1:?artifact directory is required}
VALIDATION_FILE="$ARTIFACT_DIR/stage-a-display-validation.txt"
FULL_VALIDATION_FILE="$ARTIFACT_DIR/full-profile-manifest-validation.txt"

: > "$VALIDATION_FILE"
: > "$FULL_VALIDATION_FILE"

record() {
	printf '%s\n' "$*" >> "$VALIDATION_FILE"
}

record_full() {
	printf '%s\n' "$*" >> "$FULL_VALIDATION_FILE"
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

test -f "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
test -f "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb"
test -f "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts"
test -f "$ARTIFACT_DIR/sha256sums"
test -f "$ARTIFACT_DIR/kernel.config"
test -f "$ARTIFACT_DIR/openwrt.config"
test -f "$ARTIFACT_DIR/rtl8189es.build-check.txt"

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
if [ -n "$manifest" ]; then
	grep -Eq '^kmod-rtl8189es([[:space:]]|$)' "$manifest"
else
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
	'mmc@1c10000' \
	'mmc-pwrseq' \
	'non-removable' \
	'keep-power-in-suspend' \
	'cap-sdio-irq' \
	'sdio_wifi@1'; do
	require_silent_grep "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.compiled.dts" "$pattern" "WIFI_SDIO_DTS"
done
record "WIFI_SDIO_DTS_VERIFY=PASS"

require_file "$ARTIFACT_DIR/k1-plus-rtl8189es-radio-policy" "RTL8189ES_RADIO_POLICY"
for pattern in \
	'friendlyelec,nanopi-k1-plus' \
	'/sys/class/ieee80211' \
	'1c10000\.mmc' \
	'wireless\.radio0\.path' \
	"wireless\.radio0\.disabled='1'" \
	"wireless\.default_radio0\.disabled='1'"; do
	require_silent_grep "$ARTIFACT_DIR/k1-plus-rtl8189es-radio-policy" "$pattern" "RTL8189ES_RADIO_POLICY"
done
record "RTL8189ES_RADIO_POLICY_VERIFY=PASS"

require_file "$ARTIFACT_DIR/rtl8189es-uci-defaults-50_rtl-wifi" "RTL8189ES_DEFAULT_SCRIPT"
if grep -Eq 'sed -i|ip link set dev wlan0 up' "$ARTIFACT_DIR/rtl8189es-uci-defaults-50_rtl-wifi"; then
	fail "RTL8189ES_DEFAULT_SCRIPT"
fi
record "RTL8189ES_DEFAULT_SCRIPT_VERIFY=PASS"

require_file "$ARTIFACT_DIR/k1-plus-mac80211-config-generator.uc" "K1_MAC80211_GENERATOR"
for pattern in \
	'friendlyelec,nanopi-k1-plus' \
	'reset_k1_wireless_config' \
	'delete wireless\.' \
	'k1_radio_seen = true' \
	'NanoPi-K1-Plus' \
	"disabled='\\$\\{is_k1_plus \\? \"1\" : \"0\"\\}'"; do
	require_silent_grep "$ARTIFACT_DIR/k1-plus-mac80211-config-generator.uc" "$pattern" "K1_MAC80211_GENERATOR"
done
record "K1_MAC80211_GENERATOR_VERIFY=PASS"

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

record_full "PROFILE=FULL"
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

require_manifest_pkg kmod-rtl8189es "RTL8189ES"
record_full "RTL8189ES=PASS"

for pkg in wpad-openssl hostapd-utils iw-full; do
	require_manifest_pkg "$pkg" "WIFI_AP_PROVIDER"
done
for pkg in \
	wpad-basic \
	wpad-basic-mbedtls \
	wpad-basic-openssl \
	wpad-basic-wolfssl \
	wpad-mbedtls \
	wpad-wolfssl; do
	require_no_manifest_pkg "$pkg" "WIFI_AP_PROVIDER"
done
record_full "WIFI_AP_PROVIDER=PASS"

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
record_full "FULL_PROFILE_VERIFY=PASS"

gzip -t "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
(cd "$ARTIFACT_DIR" && sha256sum -c sha256sums)
record "STAGE_A_DISPLAY_VERIFY=PASS"
echo 'IMAGE_VERIFY=PASS'
