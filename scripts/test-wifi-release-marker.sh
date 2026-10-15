#!/bin/sh
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

policy="$tmp/policy"
marker="printf '%s\n' done > /etc/wifi-release-done"

assert_marker_present() {
	grep -Fq -- "$marker" "$policy"
}

printf '%s\n' "$marker" > "$policy"
assert_marker_present
printf '%s\n' 'MARKER_NONEMPTY_POSITIVE=PASS'

printf '%s\n' ': > /etc/wifi-release-done' > "$policy"
if assert_marker_present; then
	printf '%s\n' 'MARKER_ZERO_BYTE_WRITE=FAIL' >&2
	exit 1
fi
printf '%s\n' 'MARKER_ZERO_BYTE_WRITE=PASS'

: > "$policy"
if assert_marker_present; then
	printf '%s\n' 'MARKER_MISSING=FAIL' >&2
	exit 1
fi
printf '%s\n' 'MARKER_MISSING=PASS'
