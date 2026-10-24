#!/bin/sh
set -eu

SETTLE_SCRIPT=${1:?settle script path required}
T=$(mktemp -d)
fail=0

ck() {
	if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fail=1; fi
}

mkdir -p "$T/bin" "$T/sys/ieee80211/phy0"
printf '40\n' > "$T/uptime"
printf 'stable\n' > "$T/cksum-mode"
printf '0\n' > "$T/cksum-count"
: > "$T/wifi-calls"
: > "$T/ap"
sed \
	-e "s#/root/wifi-diag/settle.log#$T/settle.log#g" \
	-e "s#/tmp/k1plus-wifi-settle-reload#$T/reload-marker#g" \
	-e "s#/etc/config/wireless#$T/wireless#g" \
	-e "s#/sys/class/ieee80211/phy0#$T/sys/ieee80211/phy0#g" \
	"$SETTLE_SCRIPT" > "$T/settle"
printf "config wifi-device 'radio0'\n" > "$T/wireless"

cat > "$T/bin/cut" <<'EOF'
#!/bin/sh
if [ "$*" = '-d. -f1 /proc/uptime' ]; then cat "$WD_TESTDIR/uptime"; else exec /usr/bin/cut "$@"; fi
EOF
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
n=$(cat "$WD_TESTDIR/uptime")
printf '%s\n' "$((n + $1))" > "$WD_TESTDIR/uptime"
EOF
cat > "$T/bin/cksum" <<'EOF'
#!/bin/sh
n=$(cat "$WD_TESTDIR/cksum-count")
n=$((n + 1))
printf '%s\n' "$n" > "$WD_TESTDIR/cksum-count"
mode=$(cat "$WD_TESTDIR/cksum-mode")
if [ "$mode" = changing ]; then printf '%s 1 %s\n' "$n" "$1"; else printf '99 1 %s\n' "$1"; fi
EOF
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
if [ "$(cat "$WD_TESTDIR/disabled")" = 1 ]; then echo "wireless.radio0.disabled='1'"; else echo "wireless.radio0.disabled='0'"; fi
EOF
cat > "$T/bin/iw" <<'EOF'
#!/bin/sh
if [ -f "$WD_TESTDIR/ap" ]; then
	if [ "$1" = dev ] && [ "$#" -eq 1 ]; then printf '\tInterface phy0-ap0\n\t\ttype AP\n';
	elif [ "$1" = dev ] && [ "$3" = info ]; then printf '\tInterface phy0-ap0\n\t\ttype AP\n'; fi
fi
EOF
cat > "$T/bin/wifi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WD_TESTDIR/wifi-calls"
if [ "${WD_AP_AFTER_RELOAD:-0}" = 1 ]; then : > "$WD_TESTDIR/ap"; fi
EOF
chmod +x "$T/bin/"*
export WD_TESTDIR="$T"
export PATH="$T/bin:$PATH"

run_case() {
	name=$1
	: > "$T/settle.log"; : > "$T/wifi-calls"; rm -f "$T/reload-marker" "$T/ap" "$T/disabled"
	printf '40\n' > "$T/uptime"; printf '0\n' > "$T/cksum-count"; printf 'stable\n' > "$T/cksum-mode"
	case "$name" in
		ap-present) : > "$T/ap" ;;
		config-changing) printf 'changing\n' > "$T/cksum-mode" ;;
		admin-disabled) printf '1\n' > "$T/disabled" ;;
	esac
	WD_AP_AFTER_RELOAD=${2:-0} sh "$T/settle"
}

echo '== settle decision paths =='
run_case ap-present
ck 'AP present exits without reload' "! grep -q '^reload$' '$T/wifi-calls' && grep -q 'AP present' '$T/settle.log'"
run_case admin-disabled
ck 'administrator disabled exits without reload' "! grep -q '^reload$' '$T/wifi-calls' && grep -q 'administrator disabled' '$T/settle.log'"
run_case config-changing
ck 'changing config waits and times out without reload' "! grep -q '^reload$' '$T/wifi-calls' && grep -q 'timeout waiting' '$T/settle.log'"
run_case reload-restores 1
ck 'stable missing AP triggers exactly one reload and detects AP' "[ \$(grep -c '^reload$' '$T/wifi-calls') -eq 1 ] && grep -q 'AP appeared' '$T/settle.log'"
run_case reload-misses
ck 'missing AP after reload is logged and exits' "[ \$(grep -c '^reload$' '$T/wifi-calls') -eq 1 ] && grep -q 'AP still missing' '$T/settle.log'"

if [ "$fail" -eq 0 ]; then echo 'ALL PASS'; rm -rf "$T"; else echo "FAILED; artifacts: $T"; exit 1; fi
