# NanoPi K1 Plus 6.x Wi-Fi Migration Plan

Date: 2026-07-21

## Goal

Restore useful onboard Wi-Fi behavior on the modern 6.x NanoPi K1 Plus port
without breaking the already validated LAN-first recovery image.

This plan is intentionally narrow. It is based on evidence from:

- the frozen 6.x recovery line (`192.168.1.1`, LuCI, HDMI, wired access)
- the extracted official FriendlyWrt `4.14` image
- the live official `4.14` board at `192.168.10.25`

## What Official 4.14 Actually Proves

Official FriendlyWrt `4.14` proves these board-specific facts:

1. the SDIO RTL8189ES hardware path is real and can bind
2. `wlan0` can be brought up as an AP
3. WPA2 authentication works with the onboard radio
4. the old stack uses vendor first-boot mutation in `/root/setup.sh`
5. the old stack uses `fix_wifi_ap.sh` to recover from initial AP setup failure

Official FriendlyWrt `4.14` does **not** prove:

1. a clean modern netifd design
2. a stable AP/LAN/DHCP closure
3. a correct Bluetooth hardware path
4. a product topology that should be copied unchanged into 6.x

## What Must Not Be Copied Into 6.x

Do **not** blindly port these official `4.14` behaviors:

1. `network.lan.proto='dhcp'` while `lan` is the AP-side network
2. WAN-specific `8.8.8.8` rewrite from `/root/setup.sh`
3. old `rc.local` first-boot mutation model as the primary configuration layer
4. `watchcat` Internet-ping assumptions in a recovery image
5. any assumption that the official AP/DHCP behavior is already correct

## What Is Worth Migrating

These are the high-value parts to carry forward into 6.x:

1. board-specific RTL8189ES enablement
   - SDIO path awareness
   - one real radio only
   - avoid ghost `radio*` sections
2. deterministic AP creation
   - one `radio0`
   - one `wifi-iface`
   - AP mode only
3. explicit board-owned SSID policy
   - either modern project SSID, or a FriendlyWrt-like deterministic name
4. WPA2 PSK support on the onboard radio
5. only add an AP recovery helper if modern 6.x runtime proves it is still
   necessary

## Required Separation Of Tracks

### Track A: Recovery Image

Keep this line frozen as the safety baseline:

- `eth0` as LAN
- `192.168.1.1`
- LuCI and SSH
- onboard Wi-Fi excluded by default

This image is for:

- board recovery
- first-boot stability
- hardware access when Wi-Fi is broken

### Track B: Wi-Fi Compatibility Experiment

Build Wi-Fi restoration only on a separate branch/profile that starts from the
stable 6.x baseline and adds Wi-Fi deliberately.

This track should use:

- one shared LAN bridge: `br-lan`
- `eth0` added to `br-lan`
- `wlan0` AP added to `br-lan`
- `lan.proto='static'`
- `lan.ipaddr='192.168.1.1'`
- normal dnsmasq DHCP service on LAN

This is intentionally **not** the same topology as official `4.14`.

## First Implementation Target For 6.x

The first modern Wi-Fi target should be:

1. boot reliably from SD
2. keep wired `192.168.1.1`
3. keep LuCI reachable over Ethernet
4. create exactly one onboard AP
5. let Wi-Fi clients authenticate
6. let Wi-Fi clients obtain DHCP from the same LAN bridge

Stop there first.

Do **not** combine the first reintroduction with:

- WAN-on-eth0 conversion
- watchcat WAN assumptions
- Bluetooth work
- HDMI/audio changes
- extra router applications

## Minimal Package Direction

The compatibility track will likely need the modern equivalents of:

- RTL8189ES kernel package
- Wi-Fi userspace
- hostapd / WPA2 AP support
- regulatory database support
- basic Wi-Fi inspection tools

But package inclusion alone is not enough. The key is the generated runtime
configuration and the single-radio ownership model.

### Package evidence already present in the repository

Existing repository artifacts already prove some modern package names and
constraints:

- `build/github-actions/run-29140690454/openwrt.config`
- `build/github-actions/run-29140690454/*.manifest`
- `docs/PROFILE_DESIGN.md`

That evidence shows:

- `kmod-rtl8189es` exists on the 6.x target
- `wireless-regdb` exists on the 6.x target
- `rpcd-mod-iwinfo` exists on the 6.x target
- `libiwinfo` exists on the 6.x target
- `dnsmasq-full` is already the project DHCP/DNS baseline
- `wpad-openssl` is the project’s intended AP stack direction for modern
  profile design

So the first compatibility branch does not need to rediscover package naming
from scratch. It should start from the existing modern package evidence and
then focus on the runtime closure:

- one radio
- one AP
- one bridge
- one working DHCP service

## Suggested Validation Sequence

1. confirm one real `phy0`
2. confirm one real `radio0`
3. confirm one real `wlan0`
4. confirm AP SSID is visible
5. confirm WPA2 authentication succeeds
6. confirm DHCP lease on Wi-Fi client
7. confirm wired `192.168.1.1` is still usable during the same boot
8. only then consider WAN/router-mode experiments

## Collaboration Checkpoint

When the compatibility track is ready for hardware test, the most useful user
validation will be:

1. boot the test image once
2. verify Ethernet still reaches `192.168.1.1`
3. verify the AP is visible
4. verify the AP accepts the password
5. verify the client receives a DHCP lease

Those five checks are enough to decide whether the first Wi-Fi migration step
is fundamentally correct.
