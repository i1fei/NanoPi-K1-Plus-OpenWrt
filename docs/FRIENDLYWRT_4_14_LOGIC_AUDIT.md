# FriendlyWrt 4.14 Logic Audit

Date: 2026-07-20

## Goal

Explain why the official NanoPi K1 Plus FriendlyWrt 4.14 image can expose more
board functionality than the current 6.x-based OpenWrt port, and identify the
real migration risks before reintroducing features into the modern kernel build.

This document is evidence-first. It records only what is supported by local
official references or captured runtime data.

## Primary Evidence

- `F:\K1Plus\reference\nanopi-k1-plus-info.txt`
- `F:\K1Plus\reference\nanopi-k1-plus-running.dts`
- `F:\K1Plus\reference\friendlyelec-nanopi-k1-plus-wiki.html`
- `F:\K1Plus\reference\official-images\friendlycore-xenial_4.14_arm64\boot-extracted\boot.cmd`
- `F:\K1Plus\reference\official-images\friendlycore-xenial_4.14_arm64\boot-extracted\uEnv.txt`
- Current 6.x project patches under `patches/nanopi-k1-plus/`
- Known-good recovery artifact from run `29562985114`

## Confirmed Facts About the Official 4.14 System

### 1. Official FriendlyWrt is not a generic modern OpenWrt build

Captured runtime data shows:

- kernel: `4.14.111`
- OpenWrt base: `SNAPSHOT r11626-16e87514f5`
- target: `allwinner-h5/generic`
- hostname: `FriendlyWrt`

This matters because the software stack is old in three important ways:

- old Allwinner `allwinner-h5/generic` target layout
- old netifd / wireless integration behavior
- vendor `rtl8189es` out-of-tree driver assumptions

The 6.x project is therefore not a minor patch update over the same software
model. It is a platform migration.

### 2. Official network topology is fundamentally different from the 5114 recovery image

The official Wiki explicitly says that in FriendlyWrt:

- `eth0` is configured as WAN
- the board should be connected to an upstream router
- management access is done through the DHCP address obtained by `eth0`

Captured runtime information also shows:

- board network metadata:
  - `lan -> wlan0`
  - `wan -> eth0`
- active UCI network config:
  - `network.lan.ifname='wlan0'`
  - `network.wan.ifname='eth0'`

The exact `lan` protocol capture is internally inconsistent between board
metadata and UCI dump (`static` vs `dhcp`), but both sources agree on the
important part:

- official FriendlyWrt is not built around `eth0 = LAN = 192.168.1.1`
- official FriendlyWrt is built around `wlan0` participating in LAN behavior
- `eth0` is the upstream-facing port

This is the single most important logic difference from the later recovery
work. The 5114 image intentionally changed the product topology to become a
stable rescue image.

The official `4.14` rootfs extracted from:

- `F:\K1Plus\h5_sd_friendlywrt_4.14_arm64_20191230.img`

directly confirms the same topology in:

- `etc/board.d/02_network`

with:

- `ucidef_set_interfaces_lan_wan "wlan0" "eth0"`

So this is not only a wiki statement or a later runtime observation. It is the
board default actually shipped inside the official image.

### 3. Official Wi-Fi is a complete hardware + driver + userspace chain

The official runtime evidence shows all of these at once:

- DTS node: `/soc/mmc@01c10000/sdio_wifi@1`
- SDIO ID: `024C:8179`
- bound driver: `rtl8189es`
- loaded module: `8189es`
- generated wireless section:
  - `wireless.radio0.type='mac80211'`
  - `wireless.radio0.path='platform/soc/1c10000.mmc/mmc_host/mmc2/mmc2:0001/mmc2:0001:1'`
  - `wireless.default_radio0.mode='ap'`
  - `wireless.default_radio0.network='lan'`
- kernel log:
  - `mmc2: new high speed SDIO card at address 0001`
  - `device wlan0 entered promiscuous mode`
  - `br-lan: port 1(wlan0) entered forwarding state`

This proves the official image does not merely "ship a driver". It ships a
working chain:

1. DTS exposes the SDIO device and power sequence.
2. The vendor `rtl8189es` driver binds by SDIO ID.
3. Wireless config is generated in a format accepted by that stack.
4. `wlan0` is attached into the LAN bridge model used by FriendlyWrt.

Just as importantly, the official image does not rely on the generic OpenWrt
wireless defaults alone. The extracted rootfs shows:

- no prebuilt `/etc/config/network`
- no prebuilt `/etc/config/wireless`
- first-boot generation through `/bin/config_generate`
- later vendor mutation through `/root/setup.sh`

The generic wireless detection path in `lib/wifi/mac80211.sh` still creates a
conservative default shape:

- `disabled=1`
- `mode=ap`
- `network=lan`
- `ssid=OpenWrt`
- `encryption=none`

That is not what the official FriendlyWrt runtime finally exposes. So the
working official behavior depends on an extra vendor layer after generic config
generation.

### 3.1 Official first-boot vendor logic rewrites Wi-Fi and LAN behavior

The extracted `root/setup.sh` is the most important missing piece. It runs once
after first boot and does all of these:

1. copies vendor board files from `/root/board/${SUNXI_BOARD}/`
2. adds `network.wan.dns=8.8.8.8` when `wan.ifname=eth0`
3. counts detected `wlan*` interfaces
4. ensures `network.lan` exists as:
   - `type=bridge`
   - `proto=static`
   - `ipaddr=192.168.2.1`
5. walks every `radioN` section and rewrites:
   - `wireless.${r}.disabled=0`
   - `wireless.default_${r}.ssid=FriendlyWrt-<mac>`
   - `wireless.default_${r}.encryption=psk2`
   - `wireless.default_${r}.key=password`
6. restarts `led`, `network`, and `dnsmasq`

This means the official working AP state is not the stock output of old
OpenWrt. It is a FriendlyElec product script layered on top of old OpenWrt.

That gap explains a large part of the earlier 6.x confusion:

- we copied hardware facts
- we partly copied package choices
- but we did not yet replicate the official first-boot product logic

### 3.2 Official 4.14 already needed a Wi-Fi AP repair workaround

The extracted image also contains:

- `usr/bin/fix_wifi_ap.sh`

This script loops while `iwinfo` reports `ESSID: unknown`, forcibly kills
`hostapd`, and relaunches the AP on `phy0`.

That is strong evidence that even the official `4.14` image did not simply boot
into a perfectly generic stable AP state. FriendlyElec carried an explicit
runtime workaround for AP-loss behavior.

So the real lesson from official `4.14` is not "old kernel magically works".
The real lesson is:

- vendor driver
- vendor first-boot scripts
- vendor AP recovery scripts
- vendor topology assumptions

all participated together.

The captured package list also shows a notably older and simpler wireless
userspace than the current 6.x ImmortalWrt stack:

- `wpad-mini`
- `wireless-regdb`
- `collectd-mod-wireless`

This matters because the official image was not validated against modern
`ucode`-based wireless generation, modern package defaults, or the newer
ImmortalWrt package manager/runtime assumptions.

### 4. Official HDMI boot path is also a complete chain

The official 4.14 system provides:

- `boot.cmd` loading `uEnv.txt`
- `uEnv.txt` sets `fbcon=map:0`
- kernel command line includes:
  - `console=ttyS0,115200`
  - `earlyprintk`
  - `panic=10`
  - `fbcon=map:0`
- optional HDMI resolution override exists but is commented out
- runtime DTS contains:
  - `hdmi@1ee0000`
  - `compatible = "allwinner,sun8i-h3-dw-hdmi"`
  - HDMI connector node
  - TCON to HDMI graph
  - simple framebuffer entries in `chosen`

So the official HDMI result is not explained by one DTS node alone. It depends
on bootloader arguments, framebuffer routing, and the older 4.14 display stack
working together.

### 5. Official USB host support is broad and already enabled at DTS level

The official runtime logs show all EHCI/OHCI controllers being probed and
started across the expected H5 USB blocks. The current 6.x port already copied
most of this structural enablement into the board DTS patch.

This means USB host support is much closer to a DTS/kernel parity problem than
Wi-Fi is.

### 6. Board-level Bluetooth is not yet proven by the current evidence set

The official Wiki has a Bluetooth usage section and mentions BlueZ-related
software, but the currently captured board runtime data does not prove an
onboard Bluetooth transport:

- no confirmed Bluetooth chip identity in the runtime capture
- no confirmed UART HCI path in the runtime capture
- no `hci*` runtime evidence in `nanopi-k1-plus-info.txt`
- `rtl8189es` itself is Wi-Fi, not a Bluetooth combo solution

Conclusion:

- Bluetooth software capability is mentioned by the official docs
- onboard Bluetooth hardware path is not yet proven by the currently collected
  K1 Plus evidence

Bluetooth must not be used as a gating assumption for the 6.x migration until a
real transport path is confirmed.

## Why the Early 6.x Attempts Failed

### 1. We changed the network product model before the Wi-Fi migration was understood

The project intentionally changed NanoPi K1 Plus into a rescue-style image:

- `eth0` forced into LAN
- `192.168.1.1` expected on first boot

That is useful for recovery, but it is not how official FriendlyWrt is
designed. Once that topology changed, the original FriendlyWrt Wi-Fi behavior
could no longer be treated as directly portable.

### 2. The main mismatch is software behavior, not only DTS structure

The current 6.x project already carries many hardware facts from the official
tree:

- HDMI connector graph
- `mmc-pwrseq-simple`
- `sdio_wifi@1`
- EHCI/OHCI enables
- external RGMII PHY

But the failures happened in the software behavior layer:

- newer netifd behavior
- newer `mac80211.uc` config generation
- newer first-boot ordering
- vendor `rtl8189es` package defaults inherited from a much older stack

This is why adding "more DTS correctness" alone did not fix first-boot Wi-Fi.

### 2.1 We missed the vendor first-boot orchestration layer

The official image proves that "working Wi-Fi" was never just:

- DTS
- `8189es.ko`
- generic `mac80211.sh`

It also required:

- board default topology generation in `etc/board.d/02_network`
- first-boot mutation in `root/setup.sh`
- AP recovery workaround in `usr/bin/fix_wifi_ap.sh`

Without reproducing or consciously replacing that orchestration layer, later 6.x
experiments were bound to behave differently even when the SDIO device and the
kernel module both appeared present.

### 3. The Wi-Fi path name changed across generations

Official 4.14 runtime used a wireless path under:

- `.../mmc_host/mmc2/mmc2:0001/...`

The later 6.x board experiments exposed runtime paths under `mmc1` in practice.

That means any board logic that assumes the old runtime path string is fragile.
This is one of the reasons stale or duplicated wireless config could survive in
6.x even when the underlying hardware node looked correct.

### 4. Recovery success in run 29562985114 does not mean feature migration success

Run `29562985114` proved that the current 6.x port can now do all of these:

- boot reliably
- expose HDMI output
- provide working Web UI
- provide stable `192.168.1.1`

But that image achieved stability by intentionally excluding onboard Wi-Fi.

So it is a successful recovery baseline, not a successful feature-complete
FriendlyWrt replacement.

## What This Means for the 6.x Migration

### Safe assumptions

- HDMI can work on 6.x and is no longer the primary blocker.
- The board DTS already contains most of the structural hardware enablement that
  the official 4.14 runtime relied on.
- The next major migration problem is Wi-Fi behavior, not basic boot.

### Unsafe assumptions

- "Official Wi-Fi works, so adding `kmod-rtl8189es` should be enough."
- "Official FriendlyWrt behavior can be preserved while also forcing
  `eth0 -> LAN -> 192.168.1.1`."
- "Bluetooth loss is definitely a K1 Plus regression."
- "Old vendor wireless helper scripts can be dropped into a modern netifd stack
  unchanged."

## Recommended 6.x Work Order

### Baseline 0: keep 5114 frozen

Keep run `29562985114` as the known-good recovery baseline:

- stable boot
- HDMI output
- Web UI
- `192.168.1.1`

Do not sacrifice this image while restoring optional features.

### Phase 1: decide the intended topology before restoring Wi-Fi

Choose one of these models explicitly:

1. FriendlyWrt-compatible model
   - `eth0 = WAN`
   - `wlan0 = AP/LAN`
   - management primarily through upstream-assigned address or Wi-Fi AP

2. Recovery-router model
   - `eth0 = LAN`
   - `192.168.1.1`
   - Wi-Fi optional and subordinate

Trying to preserve both at first boot is what previously caused repeated logic
conflicts.

### Phase 2: reintroduce Wi-Fi without reusing old assumptions blindly

Port only the durable hardware facts:

- SDIO node
- power sequence
- reset GPIO
- `keep-power-in-suspend`
- `cap-sdio-irq`

Do not assume these old software behaviors are still valid:

- hard-coded old MMC path names
- shell-era wireless helper mutations
- old first-boot ordering assumptions

### Phase 3: make Wi-Fi generation board-aware in modern terms

The modern 6.x fix should be built around:

- one physical radio
- one deterministic generated config
- tolerance for MMC host renumbering
- no ghost radios
- no vendor script hacks that mutate unrelated global Wi-Fi logic

### Phase 4: treat Bluetooth as a separate research item

Do not block Wi-Fi restoration on Bluetooth. First prove whether K1 Plus
actually has a board-level Bluetooth transport in the official design.

## Practical Conclusion

The official 4.14 image achieves "more board functionality" because it is not
just older kernel code. It is a consistent product stack:

- older OpenWrt base
- older Allwinner target
- vendor `rtl8189es` driver
- original FriendlyWrt network topology
- matching first-boot wireless assumptions
- matching bootloader / framebuffer display path

The main lesson for 6.x is this:

The next feature restoration step must migrate product logic, not only enable
devices.

That means the Wi-Fi restoration plan must start from topology and first-boot
behavior, not from package inclusion alone.

## 5114 Live-State Caveat

The currently reachable `5114` board at `192.168.10.85` is useful for runtime
inspection, but it is not a pristine first-boot reference anymore.

### Evidence that the live board was reconfigured after first boot

Captured `logread` from the live board shows this sequence on `2026-07-09`:

1. At first boot (`02:34`), netifd reported `Wireless module not found`, yet
   the board still brought up:
   - `br-lan`
   - address `192.168.1.1`
   - `dnsmasq-dhcp` range `192.168.1.100 -- 192.168.1.249`
2. At `11:16:03`, LuCI accepted a login from `192.168.1.2`.
3. Seconds later, the board dropped `192.168.1.1` and `udhcpc` obtained
   `192.168.10.85` from `192.168.10.11`.
4. At `11:17:55`, the board was switched back to `192.168.1.1`.
5. At `11:22:48`, the network stack was restarted again, and `udhcpc`
   reacquired `192.168.10.85`.

The extracted file timestamps align with this:

- `config.dhcp` last write: `2026-07-09 11:17`
- `config.network` last write: `2026-07-09 11:22`

This means the current runtime overlay was modified after the original recovery
boot. So any conclusions drawn from the current `/etc/config/network` alone
would be unsafe unless they are checked against the boot log.

### What remains valid from 5114

Even with onboard Wi-Fi intentionally excluded, the fresh recovery image still
proved these things:

- `Wireless module not found` did not prevent LAN-first recovery boot
- `eth0` could still become `br-lan`
- `192.168.1.1` came up on first boot
- `dnsmasq` could serve the expected recovery DHCP range
- HDMI and LuCI both worked

So run `29562985114` remains a valid recovery baseline.

### What 5114 can no longer prove by itself

The currently running board can no longer be used as authoritative evidence for
the original default network config, because:

- `board.json` still says `lan -> eth0 -> static`
- current `/etc/config/network` says `lan -> br-lan -> dhcp`

That mismatch is a runtime drift artifact, not a board-definition fact.

### What the live board does prove about boot media

The currently reachable board is booted from the SD image, not from eMMC:

- kernel command line: `root=PARTUUID=5452574f-02`
- `blkid` maps `PARTUUID=5452574f-02` to `/dev/mmcblk1p2`
- mounted rootfs is squashfs from `/dev/root`
- writable overlay is `rootfs_data` on `/dev/loop0`
- eMMC partitions are visible separately as `/dev/mmcblk2p*`
- auto-mount remains disabled in `/etc/config/fstab`

So the current runtime evidence does not support "the board is secretly running
from eMMC" as the explanation for the observed config drift.

### Additional recovery-image mismatch: watchcat assumes Internet reachability

The current live board still carries:

- `watchcat.mode='ping_reboot'`
- `watchcat.period='6h'`
- `watchcat.pinghosts='8.8.8.8'`

That setting is reasonable for an online router, but it is a mismatch for an
offline LAN-first recovery image. It did not cause the immediate first-boot LAN
failure, but it can still produce later reboot pressure in a valid recovery
scenario where `192.168.1.1` works but upstream Internet is intentionally
absent.

### The currently running 5114 board matches the Full Profile package shape

Package inspection on the live board shows all of these together:

- `luci-app-argon-config`
- `luci-app-diskman`
- `luci-app-samba4`
- `luci-app-watchcat`
- `collectd-mod-cpu`
- `bluez-daemon`
- `openssh-sftp-server`
- `smartmontools`
- `hdparm`
- `gpiod-tools`
- `i2c-tools`
- `libdrm-tests`
- `mmc-utils`

That package set matches the current `NanoPi_K1_Plus.config` /
`NanoPi_K1_Plus_full.config` shape, not the minimal/base recovery profile.

So when analyzing the current live board, we must separate:

- the *recovery LAN-first behavior* that was proven at first boot
- the *full-profile package payload* that later introduced additional runtime
  services such as `watchcat`

This explains why a board can still be a valid LAN recovery baseline for boot
analysis while simultaneously being a poor source of truth for "what the
minimal recovery image ought to include long-term."

## 2026-07-21 Live 6.x Board Reality Check

On 2026-07-21, the currently reachable K1 Plus at:

- `ssh root@192.168.10.85`

was sampled again with the local collector script and the resulting bundle was
saved at:

- `F:\K1Plus\artifacts\live-state-20260721\k1plus-live-state-20260721-022707.tar.gz`

This snapshot is useful because it confirms what the current branch is
actually running on hardware after the recovery work.

### Confirmed current runtime state

- kernel: `6.18.38`
- model: `FriendlyElec NanoPi K1 Plus`
- rootfs: `squashfs`
- active address: `192.168.10.85/24`
- active LAN device: `br-lan`
- bridge member: `eth0`

The extracted `config.network` shows:

- `config device`
  - `name='br-lan'`
  - `type='bridge'`
  - `ports='eth0'`
- `config interface 'lan'`
  - `device='br-lan'`
  - `proto='dhcp'`
  - commented old value: `# list ipaddr '192.168.1.1/24'`

At the same time, `board.json` still advertises the board default as:

- `lan -> eth0 -> static`

So the board is again confirmed to be in a runtime-drifted state rather than a
pristine first-boot state.

### Current live board is not carrying a usable onboard Wi-Fi userspace stack

The fresh live-state bundle also shows:

- `ubus call network.wireless status` -> `Command failed: Not found`
- `iw` is missing entirely (`iw: not found`)
- no useful `wireless` UCI state was reported in the quick SSH probe
- current module autoload entries include Bluetooth and storage/network helpers,
  but no visible `rtl8189es` autoload entry in the collected `modules.d`

This matters because it means the currently running image is no longer a useful
reference for "how onboard Wi-Fi should behave when restored". It is only a
reference for:

- the stable LAN-first recovery runtime
- the current package payload shape
- the current divergence from the official `4.14` Wi-Fi product model

### Current branch profile intent matches this live board shape

The current repository profiles:

- `configs/NanoPi_K1_Plus.config`
- `configs/NanoPi_K1_Plus_full.config`

still intentionally exclude onboard Wi-Fi, while they do include:

- `watchcat`
- `luci-app-watchcat`
- USB Bluetooth support packages

That matches the live-board observation far better than it matches official
FriendlyWrt `4.14`.

So the evidence is now consistent:

1. official `4.14` full-function behavior depends on vendor Wi-Fi product logic
2. current `5114` descendants are a LAN-first recovery line
3. the current live board should not be used as a proxy for official Wi-Fi
   behavior

## Missing Evidence And Lowest-Cost Next Collection

The official `4.14` image and the current `5114` live board together already
explain the major logic gap:

- official `4.14` used `wlan0 = LAN`, `eth0 = WAN`
- official `4.14` relied on vendor first-boot rewrites
- official `4.14` carried an AP recovery helper
- `5114` is a valid LAN-first recovery baseline, but not a pristine official
  feature reference

What is still missing is not "more random runtime logs". The highest-value
missing evidence is much narrower:

1. one pristine boot capture from the official `4.14` image on real hardware
2. one post-boot live-state bundle from that same untouched official runtime
3. confirmation of whether the official board actually exposes Bluetooth
   transport nodes or services in practice

If those are collected, the remaining migration work can be based on:

- official product behavior
- current 6.x board support
- exact first-boot deltas

instead of further trial-and-error.

### Lowest-cost user collaboration

If hardware time is available later, the cheapest useful user action is:

1. boot the untouched official `4.14` SD image
2. do not edit `/etc/config/network` or `/etc/config/wireless`
3. run the local collector script:
   - `diagnostics/collect-live-state.sh`
4. copy the resulting `tar.gz` bundle back to the workspace

That single bundle is more valuable than many partial screenshots because it
captures:

- boot log
- network and wireless UCI state
- board metadata
- loaded modules
- SDIO enumeration
- netifd and ubus state
- current package set

Until that official live bundle exists, we already have enough evidence to make
one safe strategic decision:

- keep `5114` and its LAN-first descendants as the recovery track
- treat official-feature restoration as a separate compatibility track

Those two goals must not be forced into one image until the Wi-Fi behavior is
reintroduced deliberately on top of the stable 6.x baseline.

## 2026-07-21 Official 4.14 Live Boot Confirmation

On 2026-07-21, a freshly flashed official system was brought online at:

- `ssh root@192.168.10.25`

This board is running the real official stack, not the later 6.x recovery
track:

- kernel: `4.14.111`
- hostname: `FriendlyWrt`
- release: `OpenWrt SNAPSHOT r11626-16e87514f5`
- target: `allwinner-h5/generic`

### Live official runtime confirms the intended product model

The current official live board exposes:

- `eth0` with DHCP address `192.168.10.25/24`
- `wlan0` present and UP
- `wireless.default_radio0.ssid='FriendlyWrt-7c:c7:09:a5:47:ed'`
- `wireless.default_radio0.encryption='psk2'`
- `wireless.default_radio0.key='password'`
- `wireless.default_radio0.network='lan'`

Installed userspace also matches the older product stack:

- `iwinfo`
- `wpad-mini`
- `wireless-regdb`
- `hostapd-common`
- `watchcat`

### Official boot log proves Wi-Fi AP recovery is part of the normal path

The live `logread` shows this exact sequence during boot:

1. `/root/setup.sh` runs and rewrites the SSID for `radio0`
2. netifd attempts normal radio setup
3. `radio0` initially fails with:
   - `Device setup failed: INTERFACE_CREATION_FAILED`
   - `command failed: No such device (-19)`
4. `fix_wifi_ap.sh` notices the bad state
5. it force-kills and restarts `hostapd`
6. only then does the AP become usable:
   - `Using interface wlan0 ... ssid "FriendlyWrt-..."`
   - `hostapd: wlan0: AP-ENABLED`
   - `br-lan: port 1(wlan0) entered forwarding state`

This is a critical confirmation:

- official `4.14` does not reach its AP state through one clean netifd pass
- the AP recovery helper is not optional polish
- it is part of the normal boot closure for this product behavior

### Important inconsistency still present in official runtime

The live official board also shows a familiar inconsistency:

- `board.json` style logic says `lan` is the board-side network
- current UCI state shows `network.lan.ifname='wlan0'`
- but the live board also reports `network.lan.proto='dhcp'`

That does not match a simple "static LAN AP only" interpretation.

So the evidence now supports a more careful conclusion:

- official K1 Plus behavior is not one plain stock OpenWrt model
- it is a layered product runtime with old target defaults, runtime rewrites,
  and recovery helpers
- reproducing it on 6.x requires selecting which parts to preserve and which
  parts to intentionally replace

### What this changes for the 6.x plan

It is no longer reasonable to describe the old image as:

- "official Wi-Fi just works"

The more accurate statement is:

- official Wi-Fi works because FriendlyElec shipped a full runtime closure
  around an old stack, including an AP recovery helper after the initial radio
  setup failure

### Official trigger chain is now confirmed

The live official board also confirms how part of that closure is triggered:

- `/etc/init.d/done` runs `/etc/rc.local`
- `/etc/rc.local` checks `/etc/firstboot_${board}`
- on the first boot only, it runs `/root/setup.sh`
- `/etc/firstboot_nanopi-k1-plus` is then created

So `/root/setup.sh` is not a theoretical helper left in the image. It is part
of the real first-boot path.

This matters for 6.x planning because it means the old product behavior was
intentionally implemented as:

- generic boot
- generic OpenWrt config generation
- vendor first-boot mutation in `rc.local`
- vendor AP recovery after the first radio setup failure

not as one clean declarative board definition.

### Bluetooth is still not proven on the official live board

On the live official `4.14` board sampled on 2026-07-21:

- `hciconfig -a` returned no controller
- `rfkill list` returned nothing useful for Bluetooth
- `lsmod` showed no active Bluetooth stack
- `dmesg` contained USB host messages but no board-level Bluetooth transport
  evidence

So even with the official runtime now available, board-level Bluetooth remains
unproven. The earlier caution still stands:

- do not design the 6.x migration around an assumed onboard Bluetooth path
- treat Bluetooth as a separate follow-up item unless real hardware evidence is
  collected

## 2026-07-21 Official AP Authentication vs DHCP Failure

Further live testing on 2026-07-21 confirmed that the official AP is not fully
healthy even though it is visible and accepts the documented password.

### Confirmed behavior

- SSID `FriendlyWrt-7c:c7:09:a5:47:ed` is visible
- WPA2 password `password` is correct
- a client can authenticate to the AP
- the client does **not** receive a DHCP lease

### Live runtime evidence

The live official board shows:

- `/var/run/hostapd-phy0.conf` contains:
  - `wpa_passphrase=password`
  - `bridge=br-lan`
- `wireless.default_radio0.network='lan'`
- `network.lan.ifname='wlan0'`
- `network.lan.proto='dhcp'`

At the same time:

- `br-lan` exists but is `NO-CARRIER` / `state DOWN`
- `brctl show` does not list `wlan0` as an active bridge member
- `/tmp/dhcp.leases` is empty
- `netstat` shows no active UDP listener on port `67`

The boot log is especially revealing:

1. one earlier dnsmasq instance briefly advertised:
   - `DHCP, IP range 192.168.2.100 -- 192.168.2.249`
2. after later network restarts, dnsmasq no longer kept that active DHCP range
3. the current runtime converged to:
   - `network.lan.proto='dhcp'`
   - WAN on `eth0`
   - AP still broadcasting
   - no working LAN-side DHCP service

### What this means

The official `4.14` image proves that:

- board Wi-Fi RF bring-up works
- AP broadcasting can be recovered
- WPA2 authentication works

But it does **not** prove a clean, stable, fully closed LAN/AP/DHCP design.

This is an important correction to the migration target:

- the official image is a valuable reference for board-specific Wi-Fi enablement
- it is **not** a perfect product baseline to clone blindly

For the 6.x migration, the right target is therefore:

- preserve the working board-enablement logic from official `4.14`
- intentionally replace the broken AP/LAN/DHCP closure with a cleaner modern
  design
