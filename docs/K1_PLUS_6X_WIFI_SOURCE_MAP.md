# NanoPi K1 Plus 6.x Wi-Fi Source Map

Date: 2026-07-21

## Purpose

Locate the exact upstream source files that matter for the first 6.x NanoPi K1
Plus Wi-Fi compatibility experiment.

This document is intentionally file-oriented. It does not decide policy by
itself. It records where the policy would actually be implemented.

## Confirmed Source Files In The Local OpenWrt Tree

Local source root:

- `F:\K1Plus\NanoPi-K1-Plus-OpenWrt\.work\openwrt`

## 1. Board Default Network Policy

File:

- `.work/openwrt/target/linux/sunxi/base-files/etc/board.d/02_network`

Current K1 Plus logic:

- `friendlyelec,nanopi-k1-plus)`
- `ucidef_set_interface_lan "eth0"`

Why it matters:

- this file defines the current LAN-first recovery baseline
- it is the board-level source of the `eth0 -> LAN` model

Future role:

- keep as-is for the recovery track
- do not mutate this blindly to copy official `4.14`
- if a separate Wi-Fi compatibility policy is introduced, it should be done in
  a deliberate K1 Plus-specific path rather than by confusing the recovery
  baseline

## 2. Wireless Runtime Config Generator

File:

- `.work/openwrt/package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc`

Why it matters:

- this is where modern Wi-Fi UCI sections are generated
- current repository patch `008-fix-k1-plus-runtime-radio-generation.patch`
  already targets this file

Current upstream behavior:

- creates `wifi-device`
- creates `wifi-iface`
- assigns `network='lan'`
- assigns `mode='ap'`
- defaults SSID to `ImmortalWrt`
- enables the interface by default

Future role:

- primary place to keep K1 Plus on one real radio
- valid place to apply a deterministic K1 Plus SSID policy
- valid place to keep ghost-radio cleanup

Not the right place for:

- full DHCP policy
- WAN policy
- old `rc.local` first-boot mutation logic

## 3. Modern mac80211 / hostapd Runtime Orchestration

File:

- `.work/openwrt/package/network/config/wifi-scripts/files/lib/netifd/wireless/mac80211.sh`

Relevant confirmed locations:

- `mac80211_prepare_vif()` around line `672`
- `hostapd_set_config()` around line `985`
- `wireless_add_vif` call around line `1072`
- `wdev_tool "$phy$phy_suffix" set_config` around lines `1119` and `1230`

Why it matters:

- this is where the modern stack actually creates AP interfaces and applies
  runtime config to the wireless device
- earlier K1 Plus failures happened in this runtime zone, not just in UCI text

Future role:

- investigate only if the first compatibility attempt still shows:
  - AP interface creation failure
  - missing `wlan0`
  - bad bridge attachment
- do not patch this file early unless hardware evidence shows the modern stack
  still needs a K1 Plus-specific runtime helper

## 4. RTL8189ES Package Default Script

File:

- `.work/openwrt/package/kernel/rtl8189es/files/50_rtl-wifi`

Current upstream content:

```sh
#!/bin/sh

sed -i '/iw dev "$wdev" del/d' /lib/netifd/wireless/mac80211.sh
ip link set dev wlan0 up

exit 0
```

Why it matters:

- this is the old package-local mutation we neutralized with patch `007`
- it proves the RTL8189ES package historically carried side effects outside its
  own driver boundary

Future role:

- do not restore this script wholesale
- if 6.x Wi-Fi hardware tests prove that a keepalive step is still necessary,
  replace it with a minimal K1 Plus-guarded helper instead of reviving the
  global `sed` mutation

## 5. Device Package Defaults Evidence

Evidence files:

- `build/github-actions/run-29140690454/openwrt.config`
- `build/github-actions/run-29140690454/profiles.json`
- `build/github-actions/run-29140690454/*.manifest`

What they prove:

- the current target can build `kmod-rtl8189es`
- the current target can build `wireless-regdb`
- the current target can build `rpcd-mod-iwinfo`
- the current target can build `libiwinfo`
- the project already uses `dnsmasq-full`

What they do not prove:

- that the AP stack is currently selected in the active recovery config
- that DHCP on Wi-Fi clients works

## 6. Current Repository Patch Mapping

Patch `003`:

- controls board default recovery networking

Patch `007`:

- neutralizes package-local RTL8189ES side effects

Patch `008`:

- protects the one-real-radio model in `mac80211.uc`

These three items are the main source-level junction for the first Wi-Fi
compatibility branch.

## First 6.x Compatibility Experiment: File Priority

The first implementation should likely touch files in this order:

1. profile/config selection for the compatibility branch
2. K1 Plus board network policy
3. `mac80211.uc` single-radio and AP defaults
4. only then, if hardware still fails, a minimal guarded RTL8189ES helper
5. `mac80211.sh` only as a last resort

That order reflects the current evidence:

- policy and generated config are the first-order problem
- old package mutations are risky
- deep runtime surgery should come only after a narrow hardware failure is
  reproduced
