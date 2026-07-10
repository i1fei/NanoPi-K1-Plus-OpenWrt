#!/bin/sh
set -eu

SOURCE_DIR=${1:?source directory is required}
ROOT_DIR=${2:?project directory is required}
PATCH_DIR="$ROOT_DIR/patches/nanopi-k1-plus"

for patch in \
	"$PATCH_DIR/001-add-k1-plus-dts.patch" \
	"$PATCH_DIR/002-add-k1-plus-device-profile.patch" \
	"$PATCH_DIR/003-add-k1-plus-network.patch"; do
	[ -f "$patch" ] || { echo "missing patch: $patch" >&2; exit 1; }
	git -C "$SOURCE_DIR" apply --check "$patch"
	git -C "$SOURCE_DIR" apply "$patch"
	echo "APPLIED $(basename "$patch")"
done

# This file is a patch for the separately downloaded U-Boot source. The
# OpenWrt package applies files in this directory after extracting U-Boot.
install -D -m 0644 \
	"$PATCH_DIR/005-add-k1-plus-uboot.patch" \
	"$SOURCE_DIR/package/boot/uboot-sunxi/patches/310-add-k1-plus-uboot.patch"
echo "STAGED 005-add-k1-plus-uboot.patch as U-Boot package patch 310"

