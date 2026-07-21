# NanoPi K1 Plus Profile Design

This document defines two candidate profiles. The current active config remains
`configs/NanoPi_K1_Plus.config` and is not modified by this profile work.

## Current Active Candidate

The boot-tested minimal configuration is preserved as:

- `configs/NanoPi_K1_Plus_minimal.config`

Configuration profile validation result:

| Profile | make defconfig | Profile validation |
| --- | --- | --- |
| Base | PASS | PASS |
| Full | PASS | PASS |

The active build candidate is now:

- `configs/NanoPi_K1_Plus.config`
- Source profile: `configs/NanoPi_K1_Plus_full.config`

The active candidate validates software inclusion through the build artifact
manifest. This proves the software entered the image; it does not prove the
hardware works.

Current hardware recovery state:

- Full Profile software package set: FROZEN.
- Active Full Profile rootfs: 4096 MB.
- MicroSD and eMMC remain independent boot media.
- Anonymous cross mounting of the other MMC medium is disabled by default.
- HDMI CMA is prepared, but HDMI runtime output is still untested.

## Base Profile Goal

`configs/NanoPi_K1_Plus_base.config` is the stable daily baseline:

- NanoPi K1 Plus sunxi/cortexa53 target.
- 512 MB rootfs.
- LuCI with package manager.
- Simplified Chinese LuCI.
- Dropbear SSH.
- RTL8189ES driver only; no Wi-Fi AP stack.
- MMC, USB HID, USB storage.
- ext4, vfat, exfat, ntfs3.
- block-mount and e2fsprogs.
- Basic field tools: nano, curl, wget-ssl, htop, ethtool, iperf3, usbutils.
- HDMI/input diagnostics: libdrm tests and evtest.

Base excludes Samba, ttyd, file browser, Bluetooth, OpenSSH server, statistics,
DDNS, UPnP, SQM, WireGuard, MiniDLNA, containers, eFlasher, audio, camera, and
infrared.

## Full Profile Goal

`configs/NanoPi_K1_Plus_full.config` is a richer candidate image and must remain
a functional superset of Base, except for mutually exclusive providers and the
larger rootfs size:

- 4096 MB rootfs.
- HTTPS LuCI with OpenSSL backend.
- Argon theme and Argon config.
- ttyd and LuCI commands.
- File browser and disk manager.
- Samba4, LuCI Samba4, WSD discovery, and OpenSSH SFTP server.
- USB Storage UAS and disk utilities.
- Common USB serial adapters.
- Common USB Ethernet adapters.
- External USB Bluetooth preparation.
- Hardware tools: mmc-utils, i2c-tools, gpiod-tools, evtest, libdrm tests,
  tcpdump, ip-full, lsof, strace.
- Lightweight monitoring: LuCI statistics, collectd modules, watchcat.

## RootFS Size

| Profile | RootFS |
| --- | ---: |
| Base | 512 MB |
| Full | 4096 MB |

Full uses a fixed 4096 MB rootfs. It does not auto-expand to the full MicroSD
card and does not migrate or write to eMMC.

## Wi-Fi Strategy

Base keeps the RTL8189ES driver but intentionally does not include Wi-Fi AP
services.

Full currently follows the same recovery principle:

- onboard Wi-Fi is intentionally excluded from the active Base/Full profiles

This is not because RTL8189ES hardware is fake. It is because the current
stable line is the LAN-first recovery image.

The next Wi-Fi step is now explicitly separate:

- keep `192.168.1.1` recovery intact
- reintroduce onboard Wi-Fi only on a dedicated 6.x compatibility branch/profile
- require AP authentication plus DHCP on the shared LAN bridge before merging
  any Wi-Fi stack back into the main recovery profiles

Modern AP-provider selection such as `wpad-openssl` belongs to that future
compatibility profile, not to the current recovery Base/Full profiles.

## Bluetooth Strategy

Full prepares external USB Bluetooth only:

- `kmod-bluetooth`
- `kmod-btusb`
- BlueZ daemon and utilities

Onboard Bluetooth remains:

- Hardware: `UNKNOWN`
- DTS: `NOT IMPLEMENTED`
- Hardware test: `UNTESTED`

No UART Bluetooth DTS or board-level Bluetooth assumption is added.

## HDMI Status

HDMI remains `FAIL / NO OUTPUT` on hardware. These profiles only include
diagnostic tools. They do not claim HDMI is fixed and do not add HDMI audio,
3.5 mm audio, I2S, camera, or infrared support.

The hardware recovery candidate adds a 64 MiB Kernel CMA allocation for DRM
fbdev allocation. This is a build-time preparation only; it does not make an
HDMI PASS claim before hardware retesting.

## Explicitly Excluded

Both profiles exclude:

- Qt, X11, Wayland, browser stacks.
- NetworkManager.
- Docker, Podman, LXC.
- `ALL_KMODS`, `ALL_NONSHARED`, `DEVEL`, `SDK`, toolchain image options.
- eFlasher and automatic eMMC writing.
- HDMI audio, 3.5 mm audio, I2S.
- Camera and infrared.
- MiniDLNA.
- Proxy plugins and large downloaders.

## Validation

Local Windows validation does not run `make`, `gcc`, `feeds`, or OpenWrt build
steps. `Validate NanoPi K1 Plus Profiles` runs on GitHub Actions Ubuntu 24.04
and performs:

- fixed ImmortalWrt source checkout,
- feeds update/install,
- K1 Plus patch application,
- per-profile `make defconfig`,
- resolved config checks,
- compact validation artifact upload.
