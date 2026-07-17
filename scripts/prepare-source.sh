#!/bin/sh
set -eu

SOURCE_DIR=${1:?source directory is required}
SOURCE_REF=${2:-4cafb73e88b6cf61cfeca2ee6cf8ecabb60f7a07}
SOURCE_URL=https://github.com/immortalwrt/immortalwrt.git

prepare_git_dir() {
	if [ -e "$SOURCE_DIR" ] && [ ! -d "$SOURCE_DIR" ]; then
		echo "source path exists but is not a directory: $SOURCE_DIR" >&2
		exit 1
	fi

	mkdir -p "$SOURCE_DIR"

	if [ ! -d "$SOURCE_DIR/.git" ]; then
		git -C "$SOURCE_DIR" init
	fi

	git -C "$SOURCE_DIR" remote set-url origin "$SOURCE_URL" 2>/dev/null ||
		git -C "$SOURCE_DIR" remote add origin "$SOURCE_URL"
}

fetch_source() {
	prepare_git_dir
	git -C "$SOURCE_DIR" fetch --depth=1 --filter=blob:none origin "$SOURCE_REF"
	git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
	git -C "$SOURCE_DIR" submodule update --init --depth=1
}

for attempt in 1 2 3; do
	if fetch_source; then
		break
	fi

	if [ "$attempt" -eq 3 ]; then
		echo "Source clone failed after 3 attempts" >&2
		exit 1
	fi

	sleep $((attempt * 10))
done

printf 'SOURCE_REF=%s\nSOURCE_SHA=%s\n' "$SOURCE_REF" "$(git -C "$SOURCE_DIR" rev-parse HEAD)"
