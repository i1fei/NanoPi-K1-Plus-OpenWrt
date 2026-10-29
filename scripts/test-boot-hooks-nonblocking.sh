#!/bin/sh
set -eu

ROOT=${1:-.}
FILES="$ROOT/overlays/wifi_release_v1/files"
T=$(mktemp -d)
trap 'for pidfile in "$T"/*.pid; do [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true; done; rm -rf "$T"' EXIT HUP INT TERM

fail() { echo "FAIL $*" >&2; exit 1; }
pass() { echo "PASS $*"; }

command -v timeout >/dev/null 2>&1 || fail 'BusyBox timeout applet required'
timeout -s KILL 1 sh -c ':' || fail 'timeout applet unusable'

cat > "$T/slow-helper" <<'EOF'
#!/bin/sh
echo "$$" > "$HOOK_TEST_PIDFILE"
exec sleep 3600
EOF
cat > "$T/slow-commands" <<'EOF'
#!/bin/sh
exec sleep 3600
EOF
chmod +x "$T/slow-helper" "$T/slow-commands"
mkdir -p "$T/bin"
for applet in sh sleep; do
	command -v busybox >/dev/null 2>&1 && ln -sf "$(command -v busybox)" "$T/bin/$applet"
done
for applet in uci ubus wifi; do ln -sf "$T/slow-commands" "$T/bin/$applet"; done

run_bounded() {
	label=$1
	shift
	pidfile="$T/$label.pid"
	rm -f "$pidfile"
	if ! HOOK_TEST_PIDFILE="$pidfile" K1PLUS_TRACE_HELPER="$T/slow-helper" \
		timeout -s KILL 5 "$@"; then
		fail "$label did not return within 5 seconds"
	fi
	i=0
	while [ ! -s "$pidfile" ] && [ "$i" -lt 10 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ -s "$pidfile" ] || fail "$label did not launch detached helper"
	pid=$(cat "$pidfile")
	kill -0 "$pid" 2>/dev/null || fail "$label helper did not survive its parent"
	kill "$pid" 2>/dev/null || true
	pass "$label detached and returned within 5 seconds"
}

run_bounded uci-defaults-00 sh "$FILES/etc/uci-defaults/00-k1plus-trace"
run_bounded uci-defaults-99zz sh "$FILES/etc/uci-defaults/99zz-k1plus-trace"
run_bounded start-19 sh -c '. "$1"; start' sh "$FILES/etc/init.d/k1plus-wifi-trace-19"
run_bounded start-21 sh -c '. "$1"; start' sh "$FILES/etc/init.d/k1plus-wifi-trace-21"
run_bounded ieee80211-hotplug sh "$FILES/etc/hotplug.d/ieee80211/00-k1plus-trace"

cat > "$T/legacy-sync-hook" <<'EOF'
#!/bin/sh
"$K1PLUS_TRACE_HELPER" legacy-test
EOF
chmod +x "$T/legacy-sync-hook"
set +e
K1PLUS_TRACE_HELPER="$T/slow-helper" HOOK_TEST_PIDFILE="$T/legacy.pid" \
	timeout -s KILL 5 sh "$T/legacy-sync-hook"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'legacy synchronous control unexpectedly returned before timeout'
[ -s "$T/legacy.pid" ] && kill "$(cat "$T/legacy.pid")" 2>/dev/null || true
pass 'legacy synchronous control is rejected by the 5-second deadline'

for applet in cut ls head awk wc tr; do
	command -v busybox >/dev/null 2>&1 && ln -sf "$(command -v busybox)" "$T/bin/$applet"
done
set +e
PATH="$T/bin:$PATH" timeout -s KILL 10 sh "$FILES/usr/libexec/k1plus-wifi-trace" bounded-test
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "trace helper exceeded bounded-command test window (rc=$rc)"
pass 'trace helper returns with sleeping uci/ubus stubs'

sh -n "$FILES/usr/libexec/k1plus-wifi-trace" || fail 'trace helper shell syntax'
sh -n "$FILES/usr/libexec/k1plus-wifi-settle" || fail 'settle worker shell syntax'
pass 'trace helper and settle worker parse'
