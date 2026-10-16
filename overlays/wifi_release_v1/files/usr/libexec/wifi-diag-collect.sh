#!/bin/sh
# wifi-diag-collect.sh
# Read-only wireless diagnostics collector (BusyBox ash). Changes NO system state.
#
# Usage: wifi-diag-collect.sh <tag> [reason]
#   tag = pre-reload | observe | baseline : collected at most once per boot
#   tag = post-reload                      : repeatable (appends)
# Exit:  0 collected, 3 skipped (this tag already collected during this boot), 1 error
# Output: $BASE/bundle-<bootid>-up<sec>s/<tag>/*.txt  (persistent overlay, secrets redacted)
#
# Notes:
#  - Wall clock may be wrong early in boot (no RTC / NTP not synced). Trust uptime and
#    logread ordering; every record carries up=<seconds>.
#  - logread is a ring buffer; very early messages can already be gone. Capture the
#    serial console (COM9) from power-on for the full boot log.
#  - hostapd config files under /var/run contain passphrases: they are only listed, never copied.

BASE="${WIFI_DIAG_BASE:-/root/wifi-diag}"
CFGDIR="${WD_CFGDIR:-/etc/config}"
MODEFILE="${WD_MODEFILE:-/etc/wifi-watchdog.mode}"
RADIO="${WD_RADIO:-radio0}"
IFACE="${WD_IFACE:-phy0-ap0}"
MAX_BUNDLES=20
TAG="${1:-pre-reload}"
REASON="${2:-unspecified}"

BOOT_ID="$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null)"
[ -n "$BOOT_ID" ] || BOOT_ID=unknown
up() { cut -d. -f1 /proc/uptime 2>/dev/null; }

mkdir -p "$BASE" || exit 1

case "$TAG" in
  post-reload) ;;
  *) [ -e "$BASE/.done-$BOOT_ID-$TAG" ] && exit 3
     : > "$BASE/.done-$BOOT_ID-$TAG" ;;
esac

# drop per-boot markers left by earlier boots
for m in "$BASE"/.done-* "$BASE"/.dir-*; do
  [ -e "$m" ] || continue
  case "$m" in
    *-"$BOOT_ID"|*-"$BOOT_ID"-*) ;;
    *) rm -f "$m" ;;
  esac
done

D=""
[ -f "$BASE/.dir-$BOOT_ID" ] && D="$(cat "$BASE/.dir-$BOOT_ID")"
if [ -z "$D" ] || [ ! -d "$D" ]; then
  D="$BASE/bundle-$BOOT_ID-up$(up)s"
  mkdir -p "$D" || exit 1
  echo "$D" > "$BASE/.dir-$BOOT_ID"
fi
O="$D/$TAG"
mkdir -p "$O" || exit 1

redact() {
  sed -E \
    -e "s/^([[:space:]]*option[[:space:]]+(key|sae_password|wpa_psk|auth_secret|password|key1|key2|key3|key4)[[:space:]]+).*/\1'<redacted>'/" \
    -e "s/(\.(key|sae_password|wpa_psk|auth_secret|password|key1|key2|key3|key4)=).*/\1'<redacted>'/" \
    -e 's/("(key|sae_password|wpa_psk|auth_secret|password|key1|key2|key3|key4)"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"<redacted>"/'
}

TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout 15"

run() { # run <name> <shell snippet>
  f="$O/$1.txt"; shift
  { echo "### $(date '+%F %T') up=$(up)s :: $*"; $TO sh -c "$*" 2>&1; echo; } | redact >> "$f"
}

{
  echo "tag=$TAG"
  echo "reason=$REASON"
  echo "boot_id=$BOOT_ID"
  echo "uptime_s=$(up)"
  echo "date=$(date '+%F %T %Z')  (may be unsynced early in boot)"
  echo "radio=$RADIO iface=$IFACE"
  echo "watchdog_mode=$(cat "$MODEFILE" 2>/dev/null || echo default)"
  uname -a
  cat /etc/openwrt_release 2>/dev/null
  echo "wifi-release-done bytes=$(wc -c < /etc/wifi-release-done 2>/dev/null)"
  ls -l /FIRSTBOOT-FAILED* /root/FIRSTBOOT-FAILED* /etc/FIRSTBOOT-FAILED* 2>&1
} 2>&1 | redact > "$O/00-meta.txt"

run 10-dmesg        'dmesg'
run 11-dmesg-wifi   "dmesg | grep -Ei 'wlan|wifi|80211|cfg80211|regulatory|phy0|firmware|mt76|rtl|brcm|ath'"
run 20-logread      'logread'
run 21-logread-wifi "logread | grep -Ei 'netifd|hostapd|wpa|wifi|mac80211|radio|phy0|procd|wireless'"
run 30-sys-class    'ls -l /sys/class/ieee80211/ /sys/class/net/; ls -l /sys/class/net/br-lan/brif/'
run 31-iw           'iw phy; echo ---; iw dev'
run 32-ip           'ip -d link; echo ---; bridge link'
run 40-ubus-wifi    'ubus call network.wireless status'
run 41-ubus-iface   'ubus call network.interface dump'
run 42-ubus-list    "ubus list | grep -Ei 'network|hostapd|wpa'"
run 43-wifi-status  'wifi status'
run 50-ps           'ps w'
run 51-run-files    'ls -le /var/run/ | grep -Ei "hostapd|wpa|wifi|netifd"; ls -le /tmp/run'
run 60-uci-wireless 'uci show wireless'
run 61-cfg-wireless "cat '$CFGDIR/wireless'"
run 62-cfg-network  "cat '$CFGDIR/network'"
run 63-mtimes       "ls -le '$CFGDIR/wireless' '$CFGDIR/network' /etc/board.json /etc/wifi-release-done /etc/rc.local; ls -le /etc/rc.d | grep -Ei 'network|wifi|boot|release|watchdog'; ls -le /etc/init.d | grep -Ei 'wifi|release|watchdog'"
run 70-watchdog-log "cat '$BASE/watchdog.log'"

# keep only the newest MAX_BUNDLES bundles (never touches the current one)
n="$(ls -1d "$BASE"/bundle-* 2>/dev/null | wc -l)"
if [ "$n" -gt "$MAX_BUNDLES" ]; then
  ls -1dt "$BASE"/bundle-* | tail -n +"$((MAX_BUNDLES + 1))" | while read -r old; do
    echo "$(date '+%F %T') pruned $old" >> "$BASE/prune.log"
    rm -rf "$old"
  done
fi

sync
echo "$O"
exit 0

