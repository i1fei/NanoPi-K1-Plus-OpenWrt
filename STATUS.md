# Status

最后更新：2026-07-13

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| Source selection | PASS | ImmortalWrt 固定 SHA，见 `docs/SOURCE_DECISION.md` |
| DTS/Profile/U-Boot patch | PREPARED | 等待 GitHub Actions 实际编译 |
| Build | PASS | GitHub Actions Run 29099502996 已完成，镜像完整性校验通过 |
| Boot | UNTESTED | 需要用户使用新的备用 MicroSD 启动 |
| Ethernet | UNTESTED | 需要真实网线测试 |
| RTL8189ES | UNTESTED | 需要真实 SDIO 枚举和驱动日志 |
| USB | UNTESTED | 需要真实 USB 设备测试 |
| eMMC | READ-ONLY TEST PENDING | 只允许识别和只读检查 |
| CPU frequency | UNTESTED | 需要真实设备检查 |
| Thermal | UNTESTED | 需要真实设备检查 |

本文件不把源码可编译性写成硬件可用性；在没有实机测试前，不使用 Fully Working、Stable、Production Ready 或 All Hardware Supported 等表述。

## Artifact collection fix

Previous run:

29090710387

Firmware build:

PASS

Failure stage:

Collect and verify image

Observed error:

packages.manifest missing

Root cause:

Run 29090710387 generated `immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus.manifest`, but the old artifact verification required the fixed filename `packages.manifest`.

Fix:

Artifact collection now discovers K1 Plus `*.img` / `*.img.gz` files and accepts either `packages.manifest` or the generated `*.manifest` file. Verification still requires the image, DTB, config, build metadata, checksum validation, and `rtl8189es.ko`; it verifies `kmod-rtl8189es` when a manifest is present.

Next validation:

Rerun GitHub Actions on `feat/nanopi-k1-plus` and inspect the new `target-output-files.txt` artifact entry.

## GitHub Actions Run 29099502996

Status:

COMPLETED

Conclusion:

SUCCESS

Firmware images:

- immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus-ext4-sdcard.img.gz
- immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus-squashfs-sdcard.img.gz
- NanoPi-K1-Plus-sunxi-cortexa53.img.gz

Manifest:

immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus.manifest

RTL8189ES package:

FOUND

SHA256:

PASS

Gzip validation:

PASS

Hardware boot:

UNTESTED

Next:

使用备用 MicroSD 和 115200 串口进行首次启动测试。不得写入 eMMC。

## Stage A

TTL console:

PREPARED

HDMI Linux console:

PREPARED

tty1:

PREPARED

USB keyboard:

PREPARED

Build:

PENDING

Hardware test:

UNTESTED

## Run 29135800000

Status:

COMPLETED

Conclusion:

FAILURE

Failed step:

Clone fixed source

First actionable error:

`source path exists but is not a Git checkout: /home/runner/work/NanoPi-K1-Plus-OpenWrt/NanoPi-K1-Plus-OpenWrt/.work/openwrt`

Root cause:

The GitHub Actions cache restored `.work/openwrt/dl`, which created `.work/openwrt` without a `.git` directory. `scripts/prepare-source.sh` treated that cache-restored directory as fatal before fetching the fixed ImmortalWrt commit.

Fix:

`scripts/prepare-source.sh` now initializes an existing non-Git source directory, fetches the fixed `SOURCE_REF` with bounded retries, and checks out `FETCH_HEAD`. The workflow now captures clone stderr in `.work/source.log`.

Stage A code:

UNCHANGED

Next:

Rerun the existing workflow and inspect the new Run result.

## Stage A kernel config fix

Failed run:

29136283191

Failure:

DRM_SUN6I_DSI appeared as an unresolved NEW option.

Resolution:

MIPI-DSI is not used by NanoPi K1 Plus HDMI.

`CONFIG_DRM_SUN6I_DSI` is explicitly disabled.

Stage A HDMI implementation:

UNCHANGED

Next:

Rebuild Stage A firmware.

## Stage A artifact validation fix

Failed run:

29138021490

Failure:

`HDMI_CONNECTOR_NODE missing or invalid`

Root cause:

Artifact validation could select a same-name U-Boot DTB and checked the OpenWrt top-level `.config` instead of the compiled Linux DTB and Linux kernel `.config`.

Resolution:

Collect the DTB from the Linux kernel build tree, save its compiled DTS, collect the Linux kernel config as `kernel.config`, and keep the top-level OpenWrt config as `openwrt.config`.

Stage A implementation:

UNCHANGED

Next:

Rebuild Stage A firmware and inspect the new Run result.

## Reference audit

FriendlyCore Wiki:

PASS

Official image download:

PASS

Official image extraction:

PASS

FriendlyCore software inventory:

UNAVAILABLE

Reason:

The official rootfs is an Android sparse image and the local read-only tooling
cannot extract the dpkg database.

sd-fuse_h5:

PASS

Actions-FriendlyWrt:

PASS

Current ImmortalWrt audit:

PASS

Feature matrix:

docs/K1_PLUS_FEATURE_MATRIX.md

Hardware gap:

docs/HARDWARE_GAP.md

Current config:

UNCHANGED

DTS:

UNCHANGED

Workflow:

NOT TRIGGERED

Next:

Generate Base Profile and Full Profile from the feature matrix.

## Configuration Profiles

Base Profile:

PREPARED

Full Profile:

PREPARED

Local make defconfig:

NOT USED

GitHub Actions validation:

PENDING

Current active config:

UNCHANGED

Firmware build:

NOT STARTED

HDMI:

FAIL / NO OUTPUT

Onboard Bluetooth:

UNKNOWN

## Full Profile Candidate

Profile validation:

PASS

Active build config:

Full Profile

Minimal boot-tested config:

PRESERVED

Firmware build:

PENDING

HDMI:

FAIL / NO OUTPUT

Wi-Fi AP:

NOT HARDWARE TESTED

External USB Bluetooth:

PREPARED

Onboard Bluetooth:

UNKNOWN

## Integrated Hardware Recovery

Full Profile:

SOFTWARE FROZEN

Full RootFS:

4096 MiB

MicroSD / eMMC:

DUAL BOOT MEDIA

NO AUTOMATIC CROSS MOUNT

Boot order:

UNCHANGED

MicroSD priority:

PRESERVED

eMMC fallback:

PRESERVED

R_PIO:

FIX PREPARED / RUNTIME UNTESTED

Wi-Fi SDIO:

FIX PREPARED / RUNTIME UNTESTED

USB VBUS / PHY / Host:

FIX PREPARED / RUNTIME UNTESTED

Power LED:

FIX PREPARED / RUNTIME UNTESTED

GPIO Button:

FIX PREPARED / RUNTIME UNTESTED

R_I2C / SY8106A / CPUFreq:

FIX PREPARED / RUNTIME UNTESTED

HDMI:

CMA FIX PREPARED / RUNTIME UNTESTED

Selected CMA:

64 MiB

Selected CMA reason:

Official FriendlyCore and local H5 references did not expose an explicit CMA
value. The current runtime has CmaTotal 0 KiB, so the task rule selects 64 MiB
for the 2 GiB board.

eMMC:

NOT WRITTEN

Workflow:

PENDING

## Integrated Hardware Recovery CI fix

Failed run:

29221599978

Failure:

K1 Plus DTS failed to compile at `reg_vdd_cpux` under `&r_i2c`.

Resolution:

`&r_i2c` now explicitly declares one address cell and zero size cells before
the SY8106A child regulator node.

## Integrated Hardware Recovery DTS patch fix

Failed run:

29224841061

Failure:

The K1 Plus DTS patch hunk still declared `+1,262` even though the DTS file had
grown beyond that size. The generated DTS was truncated during kernel patching.

Resolution:

The new-file hunk now declares the actual K1 Plus DTS line count. No hardware
nodes were changed by this fix.

## Integrated Hardware Recovery build success

Successful run:

29227939683

Commit:

b864eb9410b20efb29999949e979767ce3225a69

Conclusion:

SUCCESS

Artifact:

NanoPi-K1-Plus-OpenWrt

Local artifact path:

F:\K1Plus\artifacts\stage-hardware-recovery-29227939683

Recommended MicroSD image:

NanoPi-K1-Plus-sunxi-cortexa53.img.gz

Recommended image SHA256:

fd696d0257ce44ad7f9787c2fcb8b2da494f359b40c9ab9da85216d16ffb3ca8

Full Profile:

FROZEN

RootFS:

4096 MiB

CMA:

64 MiB

Validation:

BUILD PASS

IMAGE GZIP PASS

STAGE A DISPLAY PASS

FULL PROFILE PASS

Hardware recovery build checks:

R_PIO PASS

Wi-Fi SDIO PASS

USB VBUS / PHY PASS

Power LED PASS

SW4 Button PASS

R_I2C / SY8106A PASS

CPUFreq PASS

HDMI CMA PASS

MMC cross automount disabled PASS

eMMC:

NOT WRITTEN

## K1 Plus rtl8189es radio stabilization

Problem:

The rtl8189es package default script patched netifd's mac80211 helper and
forced `wlan0` up before K1 Plus had one stable board-owned wireless config.

Effect:

Ghost or stale radio sections could keep netifd busy, make LuCI wireless pages
stall, and flood the HDMI console with repeated txpower errors.

Resolution:

The package default script is now inert.

K1 Plus creates exactly one disabled `radio0` after the real rtl8189es PHY is
visible.

PHY mapping:

Stable SDIO device path from `/sys/class/ieee80211`.

Stage A HDMI / TTL / Framebuffer:

UNCHANGED

Next:

Build and verify the updated recovery image.

## K1 Plus runtime radio generation fix

Observed on hardware:

The real board exposed one `phy0`, but runtime wireless config still grew
multiple `radio*` sections with mismatched MMC paths.

Root cause:

`wifi config` could append another mac80211 section instead of collapsing K1
Plus back to one board-owned radio.

Resolution:

The shared `mac80211.uc` generator now resets K1 Plus wireless config to one
real radio before emitting a new section.

Live validation on July 16, 2026:

The first implementation reset stale radios too late. A leftover matching
section could still skip the cleanup path.

The cleanup point was moved before radio name allocation and path matching.

Runtime target:

One real rtl8189es radio, one stable PHY path, no ghost radios.

Next:

Rebuild the SD card image and recheck the live board.

## K1 Plus rtl8189es built-in wlan0 preservation

Observed on hardware:

The rebuilt image could collapse wireless config to one disabled `radio0`, but
the console still showed rtl8189es virtual interface churn and `eth0` remained
unusable from first boot.

Root cause:

The previous radio fix made `50_rtl-wifi` fully inert. On the modern wifi
stack, the old `sed` hack is obsolete, but raising the driver-owned `wlan0`
still matters. If `wlan0` stays down, the shared `wdev` helper can treat it as
removable state during empty-radio setup.

Resolution:

Restore only the K1 Plus compatible part of `50_rtl-wifi`: keep `wlan0` up
early, without reintroducing the legacy netifd script mutation.

Next:

Rebuild the SD card image and recheck first-boot network bring-up.

## K1 Plus rtl8189es validation sync

Failed run:

29481213396

Failure:

`Collect and verify image` rejected `rtl8189es-uci-defaults-50_rtl-wifi` as
invalid.

Root cause:

The validation script still treated any `ip link set dev wlan0 up` line as a
failure, but the current K1 Plus fix intentionally keeps that board-specific
`wlan0` preservation step while continuing to forbid the old `sed` mutation of
`mac80211.sh`.

Resolution:

`verify-image.sh` now rejects only the legacy `sed` hack and explicitly
requires the K1 Plus board guard plus the `wlan0` keepalive lines.

Next:

Rebuild and re-run artifact verification.

## K1 Plus first-boot radio reset rollback

Observed on hardware on July 17, 2026:

With the image built from run `29489690019`, the first reboot still showed
rtl8189es `wlan0`/`wlan1` churn, no usable Wi-Fi AP, and no reachable
`192.168.1.1`. After a second reboot, LAN recovered but Wi-Fi was still not in
a healthy default state.

Root cause:

The previous recovery path over-corrected in two ways:

1. `98-k1-plus-rtl8189es-radio` rewrote wireless config during first boot after
   the ieee80211 hotplug path had already generated config.
2. K1 Plus default wireless config was still emitted with the AP disabled,
   which turned first boot into a recovery dance instead of a normal router
   bring-up.

Resolution:

The rtl8189es package default is inert again.

K1 Plus radio creation returns to the shared `mac80211.uc` generator, which
still collapses to one real radio but now keeps the default AP enabled on first
boot.

Validation rules were updated to match that rollback.

Next:

Rebuild and retest first-boot LAN and Wi-Fi bring-up on hardware.
