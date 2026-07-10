# Status

最后更新：2026-07-10

| 阶段 | 状态 | 说明 |
| --- | --- | --- |
| Source selection | PASS | ImmortalWrt 固定 SHA，见 `docs/SOURCE_DECISION.md` |
| DTS/Profile/U-Boot patch | PREPARED | 等待 GitHub Actions 实际编译 |
| Build | NOT RUN | 未把在线构建结果写成成功 |
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
