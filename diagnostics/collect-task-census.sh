#!/bin/sh
set -eu

prefix=/tmp/k1plus-task-census
if [ "$#" -ge 1 ] && [ -n "$1" ]; then
	prefix=$1
fi
timestamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || date)
out_dir="$prefix-$timestamp"
archive="$out_dir.tar.gz"

mkdir -p "$out_dir"

{
	echo "=== task census ==="
	date
	for p in /proc/[0-9]*; do
		[ -r "$p/status" ] || continue
		pid=$(basename "$p")
		comm=$(cat "$p/comm" 2>/dev/null || true)
		state=$(awk '/^State:/{print $2}' "$p/status" 2>/dev/null || true)
		wchan=$(cat "$p/wchan" 2>/dev/null || true)
		printf 'PID=%s STATE=%s COMM=%s WCHAN=%s\n' "$pid" "$state" "$comm" "$wchan"
	done

	echo "=== full task stacks ==="
	for p in /proc/[0-9]*; do
		[ -r "$p/stack" ] || continue
		pid=$(basename "$p")
		comm=$(cat "$p/comm" 2>/dev/null || true)
		echo "--- PID=$pid COMM=$comm ---"
		cat "$p/stack" 2>/dev/null || true
		echo
	done
} >"$out_dir/all-tasks.txt" 2>&1

tar -C "$(dirname "$out_dir")" -czf "$archive" "$(basename "$out_dir")"
echo "$archive"
