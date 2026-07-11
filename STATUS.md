# Status

最后更新：2026-07-11

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
