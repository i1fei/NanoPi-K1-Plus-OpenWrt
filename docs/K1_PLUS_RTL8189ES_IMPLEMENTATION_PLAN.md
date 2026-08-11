# NanoPi K1 Plus RTL8189ES Implementation Plan

Date: 2026-07-23

## Goal

Produce a modern 6.x NanoPi K1 Plus Wi-Fi compatibility image that restores the
onboard RTL8189ES as a usable AP without breaking the already validated
LAN-first recovery image.

This document is implementation-facing. It turns the earlier audits into a
minimal sequence of changes that can be built and tested deliberately.

## What The Evidence Now Proves

### 1. Official 4.14 works through a board-owned runtime model

The official FriendlyWrt `4.14` image is not a clean stock OpenWrt wireless
closure.

The extracted image proves all of the following:

- `etc/board.d/02_network` sets:
  - `lan = wlan0`
  - `wan = eth0`
- `root/setup.sh`:
  - enables wireless sections on first boot
  - generates `FriendlyWrt-<mac>` style SSIDs
  - sets WPA2 PSK
  - restarts `network` and `dnsmasq`
- `usr/bin/fix_wifi_ap.sh`:
  - detects `ESSID: unknown`
  - kills and recreates `hostapd`

So the official image succeeds through:

1. board DTS and SDIO power path
2. vendor RTL8189ES driver bind
3. first-boot UCI mutation
4. AP runtime repair

It is not just "driver present = Wi-Fi works".

### 2. Official 4.14 also patched the old mac80211 runtime behavior

The extracted official `lib/netifd/wireless/mac80211.sh` is not neutral.

It contains two critical compatibility behaviors:

1. if `ifname` is empty, it reuses the already existing netdev under:
   - `/sys/class/ieee80211/$phy/device/net/`
2. when interface recreation fails, it accepts a matching pre-existing
   interface instead of treating the setup as fatal

That confirms the official stack was already compensating for RTL8189ES runtime
behavior at the shared wireless-script level.

### 3. The modern 6.x stack is structurally different

The current modern `wifi-scripts` implementation in the source tree no longer
follows that old shell-only lifecycle.

Important differences:

- it uses `wdev.uc`
- it pushes state through `wdev_tool ... set_config`
- it expects clean interface ownership and recreation
- it coordinates `hostapd` and `wpa_supplicant` through newer runtime flows

This means a blind port of the old 4.14 script edits would be high risk.

### 4. The current recovery line intentionally changed the product topology

The current validated recovery line is intentionally not equivalent to official
4.14:

- `eth0 = LAN`
- `192.168.1.1`
- wired management first
- onboard Wi-Fi excluded

This line is correct and must stay frozen as the safety baseline.

### 5. The failed Wi-Fi attempts mixed two incompatible goals

The previous `wifi_compat` experiments combined:

- the recovery topology (`eth0 = LAN`)
- modern `rtl8189es` package and AP stack
- a desire for official-style onboard AP behavior

That mixed two different product models:

1. recovery image
2. Wi-Fi-led appliance image

This is why the work kept oscillating between:

- "wired becomes unreachable"
- "radio appears but AP is unusable"
- "runtime scripts wedge the control path"

## Design Decision

Keep two lines permanently separate.

### Line A: Recovery / Buddha

Keep this line stable:

- `eth0 = LAN`
- `192.168.1.1`
- no onboard Wi-Fi by default
- software stack expansion is allowed

This line exists so the board is always recoverable.

### Line B: RTL8189ES Compatibility

Build Wi-Fi restoration only in a separate compatibility profile.

This line is allowed to differ in runtime behavior from the recovery line, but
it should still keep one hard requirement:

- wired access must remain recoverable during first boot

## Minimal 6.x Compatibility Target

The first real success target for the Wi-Fi line is:

1. one real `phy0`
2. one real `radio0`
3. one real AP netdev
4. WPA2 AP visible to clients
5. Wi-Fi clients can authenticate
6. Wi-Fi clients can get DHCP
7. `eth0` remains locally manageable during first boot

Stop there first.

Do not combine the first restored AP build with:

- Buddha package expansion
- Bluetooth
- WAN conversion
- watchcat WAN assumptions
- extra routing applications

## Recommended Implementation Order

### Phase 1: New Profile, No Shared Script Patch Yet

Create a new profile, conceptually `wifi_compat_v2`, that:

- starts from the known-good recovery baseline
- adds only the minimum Wi-Fi packages:
  - `kmod-rtl8189es`
  - `wpad-openssl`
  - `wireless-regdb`
  - `iwinfo`
  - `rpcd-mod-iwinfo`
- does not add unrelated apps

Purpose:

- isolate Wi-Fi runtime from software noise

### Phase 2: Board-Owned First-Boot Wireless Generator

Add a K1 Plus-specific first-boot helper under base-files that:

- runs only on `friendlyelec,nanopi-k1-plus`
- runs only if `rtl8189es` and `hostapd` are present
- generates exactly one `radio0`
- generates exactly one `wifi-iface`
- enables AP mode explicitly
- uses a deterministic SSID
- keeps WPA2 PSK explicit

Important:

- do not depend on generic detection to create multiple `radio*`
- do not mutate unrelated boards

This should be the modern replacement for the vendor `/root/setup.sh` idea.

### Phase 3: Keep LAN Static And Recovery-Safe During First Boot

During the compatibility profile first boot:

- keep `lan.proto='static'`
- keep `lan.ipaddr='192.168.1.1'`
- keep `br-lan`
- keep `eth0` in `br-lan`
- attach Wi-Fi AP into the same bridge only after wireless setup is coherent

Reason:

- official `wlan0 = LAN / eth0 = WAN` proves the AP path can work
- but copying that WAN model directly would throw away the current recovery
  advantage

So the first modern compatibility build should remain LAN-first, but must avoid
asking the AP path to re-own the whole network model during early boot.

### Phase 4: Add A Controlled AP Repair Helper

If first boot still shows:

- `ESSID: unknown`
- `hostapd` up but AP invisible
- AP interface churn without a stable BSS

then add a board-specific repair helper, modeled on the official
`fix_wifi_ap.sh`, but narrower and safer:

- K1 Plus only
- compatibility profile only
- bounded retry window
- no global `killall hostapd` unless absolutely necessary
- explicit logging

Preferred behavior:

1. detect missing visible AP state
2. restart only the K1 Plus radio instance
3. stop retrying after a short bounded window

This helper should be a last mile repair layer, not the primary configuration
mechanism.

### Phase 5: Only If Necessary, Add A Guarded Modern Runtime Patch

If Phases 1-4 still fail because the modern runtime insists on recreating
interfaces the RTL8189ES path cannot recreate cleanly, then add one small,
board-guarded runtime compatibility patch.

That patch should:

- apply only to K1 Plus
- only affect `rtl8189es`
- prefer reusing one pre-existing AP netdev
- avoid broad edits to shared `wifi-scripts`

This is the modern equivalent of what the official 4.14 script already did, but
it must be much narrower than a general patch to all `mac80211` devices.

## What Not To Do

Do not:

1. merge Wi-Fi restoration into the recovery/Buddha line
2. copy official `eth0 = WAN` wholesale into 6.x
3. restore package-local `50_rtl-wifi` shell mutations globally
4. patch shared `mac80211.sh` broadly before proving Phases 1-4 are
   insufficient
5. debug Wi-Fi while also changing package stacks, DHCP semantics, or WAN logic

## Validation Checklist For The First Compatibility Build

The first post-implementation board test should capture:

1. `ubus call network.wireless status`
2. `/etc/config/wireless`
3. `/etc/config/network`
4. `logread | grep -i 'hostapd\\|netifd\\|rtl\\|wlan\\|phy'`
5. `iw dev` and `iw phy` if available
6. whether a phone can see the SSID
7. whether WPA2 authentication succeeds
8. whether DHCP succeeds
9. whether `192.168.1.1` remains reachable over Ethernet throughout first boot

Success is not "driver loaded".

Success is:

- one stable AP
- one stable LAN bridge
- wired recovery still reachable

## Immediate Next Step

The next implementation step should be:

1. finish the current Buddha build line separately
2. create `wifi_compat_v2` as a minimal package profile
3. implement the board-owned first-boot wireless generator
4. test before touching modern shared runtime scripts

That is the lowest-risk path that matches what the evidence now proves.

## Exact Repository Touch Set For Implementation

When implementation begins, the first pass should stay inside this narrow file
set.

### 1. New profile config

Create a new config file derived from:

- `configs/NanoPi_K1_Plus_wifi_compat.config`

Expected new file:

- `configs/NanoPi_K1_Plus_wifi_compat_v2.config`

Purpose:

- keep Wi-Fi package selection separate from the recovery and Buddha profiles

### 2. Board first-boot policy

Add one K1 Plus-only base-files helper under the sunxi target, conceptually
beside the current:

- `patches/nanopi-k1-plus/009-add-k1-plus-wifi-compat-policy.patch`

But the new helper should no longer mean "Wi-Fi packages exist, therefore force
LAN to eth0 only". Instead it should:

- create one explicit AP policy for K1 Plus
- preserve `192.168.1.1`
- preserve local recoverability
- prepare the bridge and wireless UCI intentionally

### 3. Radio ownership layer

Re-use and likely keep the ideas already explored in:

- `patches/nanopi-k1-plus/008-fix-k1-plus-runtime-radio-generation.patch`
- `patches/nanopi-k1-plus/010-fix-k1-plus-single-phy-fallback.patch`

These two patches already target the right problem class:

- one real PHY
- one real radio
- avoid stale path mismatch

They should be treated as candidate building blocks, not as proven final
closure.

### 4. Package-local rtl8189es behavior

Revisit but do not immediately revert:

- `patches/nanopi-k1-plus/007-stabilize-k1-plus-rtl8189es-radio.patch`

Current state:

- it neutralizes package-local mutation in `50_rtl-wifi`

Implementation rule:

- keep this inert by default
- only reintroduce a tiny K1-only runtime nudge if the first-boot generator and
  AP repair helper are proven insufficient

### 5. Shared runtime scripts

Do not touch these in the first implementation pass unless required by board
testing:

- `package/network/config/wifi-scripts/files/lib/netifd/wireless/mac80211.sh`
- `package/network/config/wifi-scripts/files/usr/share/ucode/wifi/utils.uc`

Reason:

- these files are shared across many devices
- the modern stack is much more invasive than the old 4.14 shell path

Only if unavoidable, the first shared-script adjustment should be:

- K1 Plus only
- single-phy fallback only
- pre-existing AP netdev reuse only

## Concrete Patch Order

When implementation begins, use this order:

1. add `wifi_compat_v2` profile config
2. add K1 Plus first-boot wireless generator
3. build and test without shared runtime patch changes
4. if radio duplication persists, re-enable the single-radio ownership patch
5. if PHY resolution still flakes, re-enable the single-phy fallback patch
6. if AP still comes up as `ESSID: unknown`, add a bounded board-specific AP
   repair helper
7. only then consider a narrow shared-script compatibility patch

## Exit Criteria Before Calling The Wi-Fi Line "Fixed"

Do not call the compatibility line fixed until all of these are true on one
clean SD flash:

1. first boot does not require a second reboot
2. Ethernet remains reachable during first boot
3. the board exposes one visible SSID
4. WPA2 authentication succeeds
5. DHCP succeeds for a Wi-Fi client
6. no ghost `radio1` / `wlan1` churn appears
7. `hostapd` does not require endless restart loops
