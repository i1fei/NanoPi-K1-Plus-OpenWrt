#!/bin/sh
set -eu

SOURCE_DIR=${1:?source directory is required}
SOURCE_REF=${2:-4cafb73e88b6cf61cfeca2ee6cf8ecabb60f7a07}
SOURCE_URL=https://github.com/immortalwrt/immortalwrt.git

if [ -e "$SOURCE_DIR" ]; then
	if [ ! -d "$SOURCE_DIR/.git" ]; then
		echo "source path exists but is not a Git checkout: $SOURCE_DIR" >&2
		exit 1
	fi
else
	git clone --filter=blob:none --no-checkout "$SOURCE_URL" "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" fetch --depth=1 origin "$SOURCE_REF"
git -C "$SOURCE_DIR" checkout --detach "$SOURCE_REF"
git -C "$SOURCE_DIR" submodule update --init --depth=1

printf 'SOURCE_REF=%s\nSOURCE_SHA=%s\n' "$SOURCE_REF" "$(git -C "$SOURCE_DIR" rev-parse HEAD)"

