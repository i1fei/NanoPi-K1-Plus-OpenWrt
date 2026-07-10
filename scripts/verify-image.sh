#!/bin/sh
set -eu

ARTIFACT_DIR=${1:?artifact directory is required}

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

gzip -t "$ARTIFACT_DIR/NanoPi-K1-Plus-sunxi-cortexa53.img.gz"
(cd "$ARTIFACT_DIR" && sha256sum -c sha256sums)
echo 'IMAGE_VERIFY=PASS'
