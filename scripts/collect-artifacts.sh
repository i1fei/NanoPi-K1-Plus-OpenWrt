#!/bin/sh
set -eu

IMAGE_DIR=${1:?image directory is required}
ARTIFACT_DIR=${2:?artifact directory is required}
SOURCE_DIR=${3:?source directory is required}

mkdir -p "$ARTIFACT_DIR"

image=$(find "$IMAGE_DIR" -maxdepth 1 -type f -name '*nanopi-k1-plus*sdcard.img.gz' -print -quit)
[ -n "$image" ] || { echo 'K1 Plus sdcard image not found' >&2; exit 1; }
cp "$image" "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"

dtb=$(find "$SOURCE_DIR" -type f -name 'sun50i-h5-nanopi-k1-plus.dtb' -print -quit)
[ -n "$dtb" ] || { echo 'K1 Plus DTB not found' >&2; exit 1; }
cp "$dtb" "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb"

for file in config.buildinfo feeds.buildinfo version.buildinfo packages.manifest; do
	[ -f "$IMAGE_DIR/$file" ] && cp "$IMAGE_DIR/$file" "$ARTIFACT_DIR/$file"
done
cp "$SOURCE_DIR/.config" "$ARTIFACT_DIR/config.full"
cp "$SOURCE_DIR/.config" "$ARTIFACT_DIR/.config"

ko=$(find "$SOURCE_DIR" -type f -name 'rtl8189es.ko' -print -quit)
[ -n "$ko" ] || { echo 'rtl8189es.ko was not generated' >&2; exit 1; }
printf 'rtl8189es.ko=%s\n' "$ko" > "$ARTIFACT_DIR/rtl8189es.build-check.txt"

(cd "$ARTIFACT_DIR" && sha256sum *.img.gz *.dtb > sha256sums)
