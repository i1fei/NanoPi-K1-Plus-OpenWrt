#!/bin/sh
set -eu

ARTIFACT_DIR=${1:?artifact directory is required}
VALIDATION_FILE="$ARTIFACT_DIR/stage-a-display-validation.txt"

: > "$VALIDATION_FILE"

record() {
	printf '%s\n' "$*" >> "$VALIDATION_FILE"
}

fail() {
	record "$1=FAIL"
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

require_config() {
	require_grep "$ARTIFACT_DIR/config.full" "^$1=(y|m)$" "$1"
}

test -f "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
test -f "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb"
test -f "$ARTIFACT_DIR/sha256sums"
test -f "$ARTIFACT_DIR/config.full"
test -f "$ARTIFACT_DIR/.config"
test -f "$ARTIFACT_DIR/rtl8189es.build-check.txt"

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
	echo 'WARNING: manifest file missing; skipping package manifest check' >&2
fi

require_file "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb" "K1_PLUS_DTB"
tmp_dts=$(mktemp)
trap 'rm -f "$tmp_dts"' EXIT INT HUP TERM
dtc -I dtb -O dts -o "$tmp_dts" "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb" >/dev/null 2>&1 ||
	fail "DTB_DECOMPILE"
record "DTB_DECOMPILE=PASS"
require_grep "$tmp_dts" 'hdmi-connector' "HDMI_CONNECTOR_NODE"
require_grep "$tmp_dts" 'allwinner,sun8i-h3-dw-hdmi' "HDMI_DW_NODE"

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

if [ -n "$manifest" ]; then
	require_grep "$manifest" '^kmod-usb-hid([[:space:]]|$)' "MANIFEST_KMOD_USB_HID"
fi

gzip -t "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
(cd "$ARTIFACT_DIR" && sha256sum -c sha256sums)
record "STAGE_A_DISPLAY_VERIFY=PASS"
echo 'IMAGE_VERIFY=PASS'
