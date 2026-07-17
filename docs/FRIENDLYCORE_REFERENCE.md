# FriendlyCore Reference Audit

This document records what can be confirmed from the FriendlyELEC NanoPi K1 Plus
Wiki, the official FriendlyCore image, and the `sd-fuse_h5` repository. It is a
reference baseline only. It does not change the current ImmortalWrt config.

## Sources

| Source | Location | Result |
| --- | --- | --- |
| FriendlyELEC Wiki | https://wiki.friendlyelec.com/wiki/index.php/NanoPi_K1_Plus/zh, local copy `F:\K1Plus\reference\friendlyelec-nanopi-k1-plus-wiki.html` | PASS |
| Official image | `F:\K1Plus\reference\official-images\friendlycore-xenial_4.14_arm64.tgz` | PASS |
| Official image MD5 | `friendlycore-xenial_4.14_arm64.tgz.hash.md5` | PASS |
| Extracted image directory | `F:\K1Plus\reference\official-images\friendlycore-xenial_4.14_arm64` | PASS |
| sd-fuse_h5 | `F:\K1Plus\reference\sd-fuse_h5`, commit `2824f80f506875a891164b6e701abd92e0809fd9` | PASS |
| Current ImmortalWrt artifact | `build\github-actions\run-29140690454` | PASS |

## Official Image

| Item | Value |
| --- | --- |
| Image name | `friendlycore-xenial_4.14_arm64.tgz` |
| Image version | `2019-12-19` |
| Required board family | `h5` |
| Kernel family | FriendlyELEC Linux `sunxi-4.14.y` |
| RootFS family | FriendlyCore Xenial, Ubuntu Core based |
| Archive size | 452,559,214 bytes |
| MD5 expected | `5404818a3afd8ac9eff2a1df5cedd28f` |
| MD5 actual | `5404818a3afd8ac9eff2a1df5cedd28f` |

Extracted files:

| File | Size | Purpose |
| --- | ---: | --- |
| `sunxi-spl.bin` | 32,768 | SPL boot stage |
| `u-boot.itb` | 523,824 | U-Boot image |
| `boot.img` | 104,857,600 | FAT boot partition image |
| `rootfs.img` | 1,403,201,680 | Android sparse ext4 rootfs image |
| `userdata.img` | 6,103,188 | User data image |
| `info.conf` | 73 | Image metadata |
| `partmap.txt` | 452 | Flash layout |

Partition layout from `partmap.txt`:

| Partition | Type | Start | Length | Image |
| --- | --- | --- | --- | --- |
| `boot0` | raw | `0x2000` | `0x8000` | `sunxi-spl.bin` |
| `uboot` | raw | `0xA000` | `0x17F6000` | `u-boot.itb` |
| `boot` | fat | `0x1800000` | `0x6400000` | `boot.img` |
| `rootfs` | ext4 | `0x7C00000` | `0x97500000` | `rootfs.img` |
| `userdata` | ext4 | `0x9F100000` | `0x0` | `userdata.img` |

## FriendlyCore Package Inventory

Status: `UNAVAILABLE`.

The official `rootfs.img` was identified as an Android sparse image. The local
Windows environment can identify it but cannot extract the dpkg database with
the available read-only tools:

- `tar` rejects it as a non-archive.
- WSL is not available.
- `7z`, `debugfs`, and `simg2img` are not available.

No package list, service list, module list, or config-file dump is fabricated in
this audit. The package and service baseline below is therefore sourced from the
Wiki and repository statements only, not from `/var/lib/dpkg/status`.

## Wiki Hardware Baseline

FriendlyELEC explicitly documents the NanoPi K1 Plus with:

| Area | FriendlyCore / Wiki statement | Current ImmortalWrt relation |
| --- | --- | --- |
| CPU | Allwinner H5, 64-bit quad Cortex-A53 | Same SoC family |
| RAM | 2 GB DDR3 | Same hardware |
| MicroSD | TF card boot supported | PASS on current hardware test |
| eMMC | eMMC module interface and eMMC boot support | DTS/kernel prepared, read-only test pending |
| Ethernet | Gigabit Ethernet with RTL8211E | PASS on current hardware test |
| Wi-Fi | On-board RTL8189 module | `kmod-rtl8189es` present, hardware test pending |
| HDMI video | HDMI 1.4, 4K@30 output | Stage A prepared; hardware output currently FAIL |
| HDMI audio | HDMI audio output documented | Not implemented in current baseline |
| 3.5 mm audio | Headphone jack documented | Not implemented in current baseline |
| USB host | USB interfaces documented | USB core/storage/HID prepared, hardware test pending |
| GPIO | 40-pin header with GPIO functions | GPIO support prepared, user-space tooling not final |
| UART | UART0/1/2/3 documented | TTL console preserved; extra UARTs untested |
| I2C | I2C0/1/2 documented | Kernel/DTS prepared, untested |
| SPI | SPI0/1 documented | Controller support prepared, user-space access not final |
| PWM | PWM0 documented | Kernel/DTS prepared, untested |
| I2S | I2S0 documented with PCM5102A use | Not implemented in current baseline |
| Infrared | IR receiver documented, can be enabled by `npi-config` | Not implemented in current baseline |
| Watchdog | `/dev/watchX` documented | Kernel prepared, untested |
| Camera | DVP CAM500B and USB camera references | Not implemented in current baseline |
| CPU frequency | DVFS documented | Kernel prepared, untested |
| Temperature | CPU temperature reading documented | Kernel prepared, untested |

## FriendlyCore Software Baseline

FriendlyELEC documents these FriendlyCore user-space capabilities:

| Category | FriendlyCore statement | Direct ImmortalWrt mapping |
| --- | --- | --- |
| Base system | Ubuntu Core based, no X Windows | Not directly portable |
| Local UI | Qt Embedded 4.8 | Not part of OpenWrt base profile |
| Network | NetworkManager and `nmcli` | OpenWrt uses netifd/UCI instead |
| SSH | SSH server included | Current image includes Dropbear |
| Editors | Vim/Nano mentioned | Current image includes Nano |
| Board config | `npi-config` | Not directly portable |
| GPIO | WiringNP and RPi.GPIO documented | Possible optional package/workflow, not base |
| Filesystem growth | First boot auto expansion documented | Current image status UNKNOWN |
| eMMC writing | eFlasher documented | Must not be automated in this project baseline |
| Audio config | ALSA `/etc/asound.conf` examples | Requires kernel/audio work first |
| Wi-Fi | NetworkManager workflow for SDIO/USB Wi-Fi | OpenWrt AP/client profile must be separate |

## sd-fuse_h5 Findings

The `sd-fuse_h5` repository is an official H5 image tooling reference. It
supports these target names:

- `friendlycore-focal_4.14_arm64`
- `friendlycore-xenial_4.14_arm64`
- `friendlywrt_4.14_arm64`
- `eflasher`

Important confirmed behavior:

- Kernel source is FriendlyELEC Linux branch `sunxi-4.14.y`.
- U-Boot source is FriendlyELEC U-Boot branch `sunxi-v2017.x`.
- Prebuilt partition images are downloaded from the FriendlyELEC H5 image area.
- `tools/get_rom.sh` downloads `.hash.md5`, verifies MD5, downloads the archive,
  verifies it again, then extracts it.
- `prebuilt/partmap.template` matches the official FriendlyCore `partmap.txt`
  layout family.
- `mk-emmc-image.sh` and eFlasher flows exist, but this audit does not enable or
  recommend automatic eMMC writing.

## Can Be Mapped To ImmortalWrt

These areas are suitable for future Base/Profile decisions:

- MicroSD boot and basic board identity.
- Ethernet LAN and LuCI access.
- Dropbear SSH.
- RTL8189ES driver inclusion, with separate hardware verification.
- USB storage, USB HID, and common filesystem support.
- CPU frequency and thermal visibility.
- Optional GPIO/I2C/SPI/PWM tooling after hardware-safe tests.
- Optional full-profile applications inspired by FriendlyWrt, not FriendlyCore.

## Cannot Be Directly Ported

These areas should not be copied directly into the current ImmortalWrt baseline:

- Linux 4.14 kernel configuration as-is.
- U-Boot `sunxi-v2017.x` behavior as-is.
- eFlasher automatic eMMC write logic.
- `npi-config` as a direct replacement for OpenWrt UCI.
- NetworkManager as a direct replacement for OpenWrt netifd.
- Qt Embedded as a base image requirement.
- WiringNP/RPi.GPIO until GPIO userspace goals are scoped separately.
