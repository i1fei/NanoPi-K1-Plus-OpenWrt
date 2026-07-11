# FriendlyWrt Reference Audit

This document records how modern FriendlyWrt can be used as a software and user
experience reference for NanoPi K1 Plus, and where it must not be treated as a
direct hardware implementation source.

## Sources

| Source | Location | Result |
| --- | --- | --- |
| Actions-FriendlyWrt repository | `F:\K1Plus\reference\Actions-FriendlyWrt` | PASS |
| Repository HEAD | `5cef95f98871324f5a3cbccb17a18345104c5e25` | PASS |
| HEAD date | `2026-07-09 16:08:04 +0800` | PASS |
| Workflow | `.github/workflows/build.yml` | PASS |
| README | `README.md` | PASS |

## Maintenance Status

Status: `PASS`.

The repository is current in the local audit clone. The latest checked commit is
from 2026-07-09 and the README changelog references OpenWrt/FriendlyWrt 25.12
and 24.10 series updates.

## Current Versions And Build Shape

The workflow builds FriendlyWrt rootfs and images for:

- `25.12`
- `24.10`

The workflow initializes FriendlyELEC manifests from:

- `friendlyarm/friendlywrt_manifests`
- branches `master-v25.12` and `master-v24.10`
- manifest `rk3399.xml`

The workflow builds rootfs artifacts and then image artifacts. It includes
docker and non-docker rootfs variants, host package-manager artifacts, and
Rockchip board image packaging.

## Supported Platform Matrix

The workflow image matrix includes:

- `rk3328`
- `rk3528`
- `rk3399`
- `rk3566`
- `rk3568`
- `rk3576`
- `rk3588`

Status for NanoPi K1 Plus direct support: `NOT IMPLEMENTED`.

No H5 target and no NanoPi K1 Plus target are present in the modern
Actions-FriendlyWrt workflow matrix. Therefore this repository is useful as a
software profile reference only. It must not be used as the source for K1 Plus
H5 DTS, kernel config, U-Boot, or low-level board support.

## Software Experience Reference

These categories are worth using as reference inputs for later NanoPi K1 Plus
profiles:

| Category | Modern FriendlyWrt reference value | K1 Plus recommendation |
| --- | --- | --- |
| LuCI | Core web UI | Base profile |
| HTTPS | Common router UI hardening target | Full profile after cert decision |
| Chinese UI | Useful for local operation | Add only if package exists in final image |
| Themes | Optional polish | Full profile only |
| Package Manager | Useful for field package changes | Base profile if storage budget allows |
| ttyd | Web terminal | Full profile only |
| Samba / ksmbd | File sharing | Full profile only |
| MiniDLNA | Media sharing | Optional multimedia profile |
| DDNS | Router feature | Optional router profile |
| UPnP | Router feature | Optional router profile |
| SQM | Router feature | Optional router profile |
| Statistics | Monitoring | Full profile only |
| Watchcat | Reliability helper | Full profile only |
| WireGuard | VPN | Optional router profile |
| OpenSSH | Rich SSH/SFTP stack | Full profile only; Dropbear is enough for base |
| SFTP | File transfer | Full profile only |
| USB | Storage and peripheral support | Base for storage/HID; other classes optional |
| Storage | block/fstools/filesystems | Base profile |
| Filesystem | ext4/vfat/exfat/ntfs3 style support | Base or Full depending size |
| Disk tools | Disk manager style UX | Full profile only |
| Network tools | Diagnostics and throughput tools | Base subset |
| Editors | Nano/Vim style field editing | Base subset |
| Shell tools | Admin convenience | Full profile only |
| Monitoring | htop/status/collectd style | Base subset, Full for LuCI statistics |

## Rockchip Configuration That Must Not Be Copied

Do not copy these into the K1 Plus H5 baseline:

- Rockchip DTS, board profiles, boot image logic, or SoC-specific drivers.
- RK3399, RK356x, RK3576, RK3588 kernel options as hardware evidence for H5.
- `ALL_KMODS` style broad kernel-module inclusion.
- `ALL_NONSHARED` style broad package inclusion.
- Toolchain, SDK, or DEVEL selections for a normal device image.
- Docker rootfs assumptions unless a separate storage and memory profile is
  designed.

## Mapping Rule For K1 Plus

Modern FriendlyWrt can answer "what software experience should a friendly router
image have?" It cannot answer "which H5 kernel, DTS, HDMI, Wi-Fi, audio, or
bootloader changes are correct for NanoPi K1 Plus?"
