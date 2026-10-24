# COM9 Segmentation Audit

Date: 2026-10-24

The segmentation tool is `scripts/segment-com9.ps1`. It uses each `U-Boot SPL` or
`U-Boot 20xx` banner as a boot boundary and extracts the first `phy0` and
`phy0-ap0` kernel events in each segment. The generated segment files were kept
outside the repository working tree; source logs remain at the paths below.

## B1 ordinary reboots

The ten COM9 logs are under
`evidence/device-v2-Reboot-20261023-090532/reboot-01-com9.log` through
`reboot-10-com9.log`.

| Round | phy0 uptime | phy0-ap0 creation uptime | Per-boot first HEALTH | Per-boot later HEALTH |
|---:|---:|---:|---:|---:|
| 01 | 18.611981 | 24.413122 | 54, healthy_rc=0 | 326, healthy_rc=0 |
| 02 | 17.863567 | 23.618405 | 53, healthy_rc=0 | 326, healthy_rc=0 |
| 03 | 18.504025 | 24.144316 | 54, healthy_rc=0 | 326, healthy_rc=0 |
| 04 | 18.505133 | 24.394655 | 54, healthy_rc=0 | 327, healthy_rc=0 |
| 05 | 18.305030 | 23.766828 | 54, healthy_rc=0 | 326, healthy_rc=0 |
| 06 | 18.426604 | 24.170329 | 54, healthy_rc=0 | 326, healthy_rc=0 |
| 07 | 17.961913 | 23.810097 | 53, healthy_rc=0 | 326, healthy_rc=0 |
| 08 | 17.702703 | 23.577573 | 53, healthy_rc=0 | 326, healthy_rc=0 |
| 09 | 17.687557 | 23.278655 | 53, healthy_rc=0 | 325, healthy_rc=0 |
| 10 | 18.186879 | 23.854088 | 54, healthy_rc=0 | 326, healthy_rc=0 |

The B1 COM9 segments show AP creation between 23.278655 and 24.413122
seconds. The B1 `23-24s` result is therefore supported by the independent
serial boot segments.

The B1 watchdog files contain the same historical `up=56s healthy_rc=1` line
at their beginning and grow from 214 to 241 lines across rounds. This shows
that those files were cumulative snapshots, not ten independently reset logs.
The per-round lines listed above are the new boot's lines at the end of each
snapshot. The source files are
`evidence/device-v2-Reboot-20261023-090532/reboot-01-watchdog.log` through
`reboot-10-watchdog.log`.

## Clean-card correction

The clean-card evidence is `evidence/clean-card-20261024-111524/`. Its
pre-reload capture at uptime 177 seconds has no `phy0-ap0` in `iw dev` or
sysfs. Stage 1 creates it at `179.350525` seconds, followed by
`rtw_ndev_init(phy0-ap0)` at `179.368899` and the bridge-port enter at
`180.300243`.

The earlier `23.965695` and `23.983443` timestamps belong to another COM9
segment and are not clean-card timestamps.

## Other segmentation facts

The 2026-10-19 long COM9 log was segmented into six boot sections. Its actual
boot sections include AP creation at `23.124695`, `179.052320`, and
`23.726163` seconds, with reboot markers at `331.354569` and `610.484555` in
the relevant sections. This source is
`../nanopi-release-bridge/evidence/com9-20261019-121854.log`.

Watchdog HEALTH/stage lines are not consistently emitted into the COM9 serial
stream; where the serial segment has no such line, the corresponding
per-round `watchdog.log` is the source of those fields. No inference from a
missing serial HEALTH line is made.
