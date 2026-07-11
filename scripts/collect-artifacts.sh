#!/bin/sh
set -eu

IMAGE_DIR=${1:?image directory is required}
ARTIFACT_DIR=${2:?artifact directory is required}
SOURCE_DIR=${3:?source directory is required}

mkdir -p "$ARTIFACT_DIR"

image=$(
	find "$IMAGE_DIR" -maxdepth 2 -type f -name '*nanopi-k1-plus*squashfs*sdcard.img.gz' -print |
		sort |
		head -n 1
)
if [ -z "$image" ]; then
	image=$(
		find "$IMAGE_DIR" -maxdepth 2 -type f -name '*nanopi-k1-plus*sdcard.img.gz' -print |
			sort |
			head -n 1
	)
fi
if [ -z "$image" ]; then
	image=$(
		find "$IMAGE_DIR" -maxdepth 2 -type f \( -name '*.img' -o -name '*.img.gz' \) -print |
			sort |
			head -n 1
	)
fi
[ -n "$image" ] || { echo 'K1 Plus sdcard image not found' >&2; exit 1; }
cp "$image" "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
find "$IMAGE_DIR" -maxdepth 2 -type f \( -name '*nanopi-k1-plus*.img' -o -name '*nanopi-k1-plus*.img.gz' \) -print |
	sort |
	while IFS= read -r file; do
		cp "$file" "$ARTIFACT_DIR/$(basename "$file")"
	done

dtb=$(find "$SOURCE_DIR" -type f -name 'sun50i-h5-nanopi-k1-plus.dtb' -print -quit)
[ -n "$dtb" ] || { echo 'K1 Plus DTB not found' >&2; exit 1; }
cp "$dtb" "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb"

for file in config.buildinfo feeds.buildinfo version.buildinfo profiles.json sha256sums; do
	[ -f "$IMAGE_DIR/$file" ] && cp "$IMAGE_DIR/$file" "$ARTIFACT_DIR/$file"
done

[ -f "$SOURCE_DIR/package/boot/uboot-sunxi/uEnv-a64.txt" ] &&
	cp "$SOURCE_DIR/package/boot/uboot-sunxi/uEnv-a64.txt" "$ARTIFACT_DIR/uEnv-a64.txt"
[ -f "$SOURCE_DIR/target/linux/sunxi/base-files/etc/inittab" ] &&
	cp "$SOURCE_DIR/target/linux/sunxi/base-files/etc/inittab" "$ARTIFACT_DIR/sunxi-inittab"

manifest=$(
	find "$IMAGE_DIR" -maxdepth 2 -type f -name 'packages.manifest' -print |
		sort |
		head -n 1
)
if [ -z "$manifest" ]; then
	manifest=$(
		find "$IMAGE_DIR" -maxdepth 2 -type f -name '*nanopi-k1-plus*.manifest' -print |
			sort |
			head -n 1
	)
fi
if [ -z "$manifest" ]; then
	manifest=$(
		find "$IMAGE_DIR" -maxdepth 2 -type f -name '*.manifest' -print |
			sort |
			head -n 1
	)
fi
if [ -n "$manifest" ]; then
	cp "$manifest" "$ARTIFACT_DIR/$(basename "$manifest")"
else
	echo 'WARNING: no manifest file found in target output' >&2
fi

cp "$SOURCE_DIR/.config" "$ARTIFACT_DIR/config.full"
cp "$SOURCE_DIR/.config" "$ARTIFACT_DIR/.config"

ko=$(find "$SOURCE_DIR" -type f -name 'rtl8189es.ko' -print -quit)
[ -n "$ko" ] || { echo 'rtl8189es.ko was not generated' >&2; exit 1; }
printf 'rtl8189es.ko=%s\n' "$ko" > "$ARTIFACT_DIR/rtl8189es.build-check.txt"

(cd "$ARTIFACT_DIR" && sha256sum *.img.gz *.dtb > sha256sums)
