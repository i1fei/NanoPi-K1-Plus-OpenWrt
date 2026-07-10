#!/bin/sh
set -eu

ARTIFACT_DIR=${1:?artifact directory is required}

test -f "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
test -f "$ARTIFACT_DIR/sun50i-h5-nanopi-k1-plus.dtb"
test -f "$ARTIFACT_DIR/sha256sums"
test -f "$ARTIFACT_DIR/config.full"
test -f "$ARTIFACT_DIR/.config"
test -f "$ARTIFACT_DIR/rtl8189es.build-check.txt"

for file in config.buildinfo feeds.buildinfo version.buildinfo packages.manifest; do
	[ -f "$ARTIFACT_DIR/$file" ] || { echo "$file missing" >&2; exit 1; }
done

if [ -f "$ARTIFACT_DIR/packages.manifest" ]; then
	grep -Eq '^kmod-rtl8189es([[:space:]]|$)' "$ARTIFACT_DIR/packages.manifest"
else
	echo 'packages.manifest missing' >&2
	exit 1
fi

gzip -t "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
sha256sum -c "$ARTIFACT_DIR/sha256sums"
echo 'IMAGE_VERIFY=PASS'
