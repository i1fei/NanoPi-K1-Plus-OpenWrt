# NanoPi K1 Plus Hardware Gap Report

This report separates verified hardware behavior, prepared-but-untested support,
software-only package work, and items that require DTS or kernel work.

## A. Verified On Hardware

| Item | Status | Notes |
| --- | --- | --- |
| MicroSD Boot | PASS | Current hardware boot was confirmed by the user. |
| Ethernet | PASS | Wired network was confirmed by the user. |
| `192.168.1.1` | PASS | Default access was confirmed by the user. |
| LuCI | PASS | Web UI access was confirmed by the user. |
| HDMI output | FAIL | System boots, but there is no HDMI display output. |

## Integrated Hardware Recovery Candidate

The next candidate keeps the Full Profile software package set frozen and
changes only hardware foundation, rootfs size, and default mount policy.

| Item | Candidate Status | Runtime Status |
| --- | --- | --- |
| Full RootFS | 4096 MiB | UNTESTED |
| R_PIO | FIX PREPARED | UNTESTED |
| Wi-Fi SDIO / RTL8189ES hardware path | FIX PREPARED | UNTESTED |
| USB VBUS / PHY / Host | FIX PREPARED | UNTESTED |
| Power LED | FIX PREPARED | UNTESTED |
| GPIO Button | FIX PREPARED | UNTESTED |
| R_I2C / SY8106A | FIX PREPARED | UNTESTED |
| CPUFreq | FIX PREPARED | UNTESTED |
| HDMI CMA | FIX PREPARED | UNTESTED |
| MicroSD / eMMC cross automount | DISABLED BY DEFAULT | UNTESTED |

The candidate must not be treated as hardware PASS until a fresh MicroSD boot
runtime report confirms it. HDMI remains `FAIL / NO OUTPUT` until real display
output is observed.

## B. Compiled But Not Verified On Hardware

| Item | Status | Notes |
| --- | --- | --- |
| RTL8189ES Wi-Fi driver | PREPARED | Official `4.14` live board proves the SDIO radio can bind and broadcast; the current 6.x recovery line still keeps onboard Wi-Fi intentionally disabled. |
| USB HID | PREPARED | Kernel/module and manifest validation pass. |
| USB Storage | PREPARED | Storage modules and filesystem packages are present. |
| eMMC | PREPARED | DTS/kernel have eMMC paths, but only identify/read-only tests are allowed. |
| GPIO LED | PREPARED | Compiled DTS has `gpio-leds`; trigger behavior is untested. |
| GPIO Button | PREPARED | Compiled DTS has `gpio-keys`; input behavior is untested. |
| GPIO/I2C/SPI/PWM | PREPARED | Kernel/DTS support exists, but pin-safe hardware testing is pending. |
| Watchdog | PREPARED | Kernel support exists; runtime behavior is untested. |
| CPU frequency | PREPARED | Kernel support exists; clocks/governors are untested. |
| Temperature | PREPARED | Thermal support exists; thermal zones are untested. |
| tty1 console | PREPARED | Stage A validation passes, but HDMI has no physical output. |

## C. Software Packages Can Address

These gaps do not prove hardware failure. They are package/profile choices:

- Chinese LuCI: requested in the seed config, but absent from the current
  successful artifact manifest. Add only in a later config phase and verify the
  final manifest.
- HTTPS LuCI: add after certificate and first-boot policy is chosen.
- Web terminal: add only in Full Profile.
- Samba/ksmbd, MiniDLNA, DDNS, UPnP, SQM, WireGuard, statistics, watchcat:
  optional router or full-profile functions.
- OpenSSH/SFTP: optional; Dropbear already covers Base Profile SSH.
- USB serial and USB Ethernet adapters: optional kernel/package targets.
- File browser and disk-manager UI: Full Profile only.

## D. Must Modify DTS Or Kernel

HDMI:

- The system boots but has no display output.
- This cannot be fixed by adding LuCI software packages.
- Continue checking DRM, EDID, framebuffer, TTY, and DTS.
- The Stage A implementation is compiled and collected, but the hardware result
  is still `FAIL` until a real display shows output.

Audio:

- HDMI audio is not implemented in the current baseline.
- 3.5 mm audio is not implemented in the current baseline.
- I2S/PCM5102A support needs a separate audio phase.

Camera and infrared:

- FriendlyCore documents DVP camera and infrared support.
- Current ImmortalWrt baseline does not implement these paths.
- They need explicit DTS/kernel work and hardware goals before inclusion.

Bluetooth:

- BlueZ software can be preinstalled later.
- RTL8189ES is not a Bluetooth chip.
- Board-level Bluetooth HCI is not currently confirmed.
- External USB Bluetooth can be treated as a separate support target.

## E. Need Real Hardware Confirmation

- eMMC module presence and read-only detection.
- 6.x compatibility-track Wi-Fi: one real radio, AP authentication, and DHCP
  on the shared LAN bridge.
- USB Host with HID and storage devices.
- USB OTG role behavior.
- LED and button runtime behavior.
- UART1/2/3, I2C, SPI, PWM, I2S pin behavior.
- Watchdog runtime behavior.
- CPU frequency and temperature readings.
- Any Bluetooth HCI path.

eMMC rule:

- Current work may only identify eMMC and perform read-only tests.
- Automatic flashing is forbidden.
- eFlasher-style automatic disk write logic must not be added to this project
  baseline.
- The running system must not automatically mount the other MMC system medium.

## F. Not Recommended For Base Image

- eFlasher automatic write-to-eMMC workflow.
- Qt Embedded.
- NetworkManager.
- `npi-config`.
- WiringNP/RPi.GPIO as default base packages.
- Full multimedia stack before HDMI output is fixed.
- BlueZ before Bluetooth hardware is confirmed.
- Rockchip-specific FriendlyWrt drivers or board logic.
- Broad package selections such as `ALL_KMODS`, `ALL_NONSHARED`, SDK, toolchain,
  or DEVEL images.

## G. Official 4.14 Correction

The official FriendlyWrt `4.14` live board on July 21, 2026 clarified two
important things:

1. official onboard Wi-Fi is real, visible, and can authenticate clients
2. official AP-side DHCP is not a clean success baseline

Observed behavior:

- SSID is visible
- password `password` is accepted
- clients do not receive DHCP leases

Therefore the official image is useful for:

- RTL8189ES board enablement
- AP bring-up evidence

but not as a blind template for:

- LAN topology
- DHCP closure
- first-boot network policy
