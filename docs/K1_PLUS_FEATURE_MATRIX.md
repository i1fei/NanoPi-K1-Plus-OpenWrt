# NanoPi K1 Plus Feature Matrix

Status values are limited to: `PASS`, `FAIL`, `PARTIAL`, `PREPARED`,
`UNTESTED`, `NOT IMPLEMENTED`, `NOT APPLICABLE`, `UNKNOWN`.

Sources:

- FriendlyCore Wiki and official image audit: `docs/FRIENDLYCORE_REFERENCE.md`
- Modern FriendlyWrt audit: `docs/FRIENDLYWRT_REFERENCE.md`
- Current ImmortalWrt artifact: `build\github-actions\run-29140690454`
- Current seed config: `configs\NanoPi_K1_Plus.config`

| 功能 | FriendlyCore | Modern FriendlyWrt | 当前 ImmortalWrt | 实现层 | 当前状态 | 建议 |
| --- | --- | --- | --- | --- | --- | --- |
| MicroSD Boot | PASS | PASS | PASS | boot/storage | PASS | Keep in Base Profile |
| eMMC | PASS | PARTIAL | PREPARED | DTS/kernel/storage | UNTESTED | Identify and read-only test only |
| Ethernet | PASS | PASS | PASS | DTS/kernel/netifd | PASS | Keep in Base Profile |
| Wi-Fi Driver | PASS | PARTIAL | PREPARED | kernel/package | PREPARED | Keep `kmod-rtl8189es`, test hardware |
| Wi-Fi AP | PARTIAL | PASS | NOT IMPLEMENTED | package/config | NOT IMPLEMENTED | Full Profile after driver test |
| Bluetooth | UNKNOWN | PARTIAL | NOT IMPLEMENTED | hardware/package | UNKNOWN | Do not assume onboard Bluetooth |
| HDMI Video | PASS | NOT APPLICABLE | PREPARED | DTS/kernel/DRM | FAIL | Debug DRM, EDID, framebuffer, TTY, DTS |
| HDMI tty1 | PASS | NOT APPLICABLE | PREPARED | kernel/init | FAIL | Depends on HDMI video output |
| HDMI Audio | PASS | NOT APPLICABLE | NOT IMPLEMENTED | kernel/audio | NOT IMPLEMENTED | Defer until HDMI video works |
| 3.5mm Audio | PASS | NOT APPLICABLE | NOT IMPLEMENTED | kernel/audio | NOT IMPLEMENTED | Full Profile only after codec work |
| USB Host | PASS | PASS | PREPARED | DTS/kernel | UNTESTED | Hardware test with low-risk devices |
| USB OTG | UNKNOWN | PARTIAL | PREPARED | DTS/kernel | UNKNOWN | Confirm connector role before profile |
| USB HID | PASS | PASS | PREPARED | kernel/package | PREPARED | Test keyboard after HDMI path |
| USB Storage | PASS | PASS | PREPARED | kernel/package | PREPARED | Keep in Base Profile |
| USB Serial | UNKNOWN | PARTIAL | NOT IMPLEMENTED | kernel/package | NOT IMPLEMENTED | Optional diagnostic target |
| USB Ethernet | PASS | PARTIAL | NOT IMPLEMENTED | kernel/package | NOT IMPLEMENTED | Optional router target |
| LED | PASS | PARTIAL | PREPARED | DTS/kernel | UNTESTED | Test sysfs/trigger behavior |
| Button | PASS | PARTIAL | PREPARED | DTS/kernel | UNTESTED | Test input events |
| GPIO | PASS | PARTIAL | PREPARED | kernel/userspace | UNTESTED | Add tools only after pin-safe plan |
| UART | PASS | PARTIAL | PREPARED | DTS/kernel/init | PREPARED | Keep TTL console; test extra UARTs separately |
| I2C | PASS | PARTIAL | PREPARED | DTS/kernel | UNTESTED | Optional hardware tools |
| SPI | PASS | PARTIAL | PARTIAL | DTS/kernel | UNTESTED | Needs user-space access decision |
| PWM | PASS | PARTIAL | PREPARED | DTS/kernel | UNTESTED | Test only with safe pin plan |
| I2S | PASS | NOT APPLICABLE | NOT IMPLEMENTED | DTS/kernel/audio | NOT IMPLEMENTED | Defer to audio phase |
| Infrared | PASS | NOT APPLICABLE | NOT IMPLEMENTED | DTS/kernel/input | NOT IMPLEMENTED | Defer until IR goal exists |
| Watchdog | PASS | PARTIAL | PREPARED | kernel | UNTESTED | Full Profile or reliability profile |
| Camera | PASS | NOT APPLICABLE | NOT IMPLEMENTED | DTS/kernel/media | NOT IMPLEMENTED | Not Base Profile |
| CPU Frequency | PASS | PASS | PREPARED | kernel | UNTESTED | Verify governors and clocks |
| Temperature | PASS | PASS | PREPARED | kernel | UNTESTED | Verify thermal zones |
| LuCI | NOT APPLICABLE | PASS | PASS | package | PASS | Keep in Base Profile |
| HTTPS | UNKNOWN | PASS | NOT IMPLEMENTED | package/config | NOT IMPLEMENTED | Full Profile after cert policy |
| Chinese UI | PASS | PASS | NOT IMPLEMENTED | package | NOT IMPLEMENTED | Add only if final manifest contains it |
| Package Manager | NOT APPLICABLE | PASS | PASS | package | PASS | Keep if image size stays acceptable |
| Web Terminal | NOT APPLICABLE | PASS | NOT IMPLEMENTED | package | NOT IMPLEMENTED | Full Profile only |
| File Browser | NOT APPLICABLE | PARTIAL | NOT IMPLEMENTED | package | NOT IMPLEMENTED | Full Profile only |
| Disk Manager | NOT APPLICABLE | PASS | PARTIAL | package/storage | PARTIAL | Full Profile; Base keeps block tools |
| Samba | NOT APPLICABLE | PASS | NOT IMPLEMENTED | package | NOT IMPLEMENTED | Full Profile only |
| SSH | PASS | PASS | PASS | package | PASS | Dropbear is Base Profile |
| SFTP | UNKNOWN | PASS | NOT IMPLEMENTED | package | NOT IMPLEMENTED | Full Profile with OpenSSH |
| Monitoring | PARTIAL | PASS | PARTIAL | package | PARTIAL | Base keeps htop; Full can add statistics |
| Filesystem support | PASS | PASS | PASS | kernel/package | PASS | Keep ext4/vfat/exfat/ntfs3 baseline |
| RootFS expansion | PASS | PARTIAL | UNKNOWN | storage/init | UNKNOWN | Verify before claiming |

## Recommended Base Profile

- Board target: sunxi cortexa53 NanoPi K1 Plus.
- MicroSD boot.
- Ethernet and LuCI.
- Dropbear SSH.
- Package manager.
- Nano, curl, wget, htop, ethtool, iperf3, usbutils.
- RTL8189ES driver, but mark Wi-Fi hardware as test pending.
- USB storage and USB HID.
- ext4, vfat, exfat, ntfs3, block-mount, e2fsprogs.
- Preserve TTL console and current Stage A tty1 preparation.

## Recommended Full Profile

- Everything in Base Profile.
- Wi-Fi AP packages after RTL8189ES client/driver verification.
- HTTPS LuCI after certificate policy is chosen.
- Chinese LuCI packages only if they appear in the final manifest.
- ttyd or equivalent web terminal.
- Samba/ksmbd and optional file sharing tools.
- LuCI statistics or other monitoring.
- Watchdog userspace integration.
- OpenSSH/SFTP only if needed beyond Dropbear.

## Optional Router Applications

- DDNS.
- UPnP.
- SQM.
- WireGuard.
- USB Ethernet adapter support.
- Additional Wi-Fi USB adapter support.

## Optional Multimedia Applications

- MiniDLNA.
- HDMI audio after HDMI video is fixed.
- 3.5 mm audio after codec support is implemented.
- I2S/PCM5102A after pin and codec plan is confirmed.
- Camera support only as a separate hardware phase.

## Not Recommended

- eFlasher automatic eMMC writing.
- Broad `ALL_KMODS` or `ALL_NONSHARED` style package selection.
- Rockchip-specific FriendlyWrt drivers or board files.
- Bluetooth packages as a base feature until real Bluetooth HCI hardware is
  confirmed.
- Qt Embedded, NetworkManager, or `npi-config` as direct OpenWrt base features.
- HDMI claims beyond `PREPARED` until the physical display output is fixed.
