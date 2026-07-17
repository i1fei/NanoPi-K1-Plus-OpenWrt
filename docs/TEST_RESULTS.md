# Test results

本文件是实机测试记录模板。空白项保持未验证，不推断结果。

| Test | Result | Evidence |
| --- | --- | --- |
| Build | PENDING | GitHub Actions run URL |
| Boot from new MicroSD | UNTESTED | serial log |
| Model and kernel | UNTESTED | `/proc/device-tree/model`, `uname -a` |
| Ethernet `eth0` | UNTESTED | `ip -br link`, link speed |
| RTL8189ES SDIO | UNTESTED | `lsmod`, `dmesg`, `SDIO_ID=024C:8179` |
| USB host/storage | UNTESTED | `dmesg`, `lsusb`, mount test |
| CPU frequency | UNTESTED | cpufreq inspection |
| Thermal | UNTESTED | thermal/cpufreq log |
| eMMC identification | READ-ONLY TEST PENDING | `mmc`/`lsblk` log |

不要在没有串口和 MicroSD 实测证据时填写 Fully Working、Stable、Production Ready 或 All Hardware Supported。

