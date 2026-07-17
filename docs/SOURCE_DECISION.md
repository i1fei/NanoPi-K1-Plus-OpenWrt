# Source decision

选择日期：2026-07-10

## 选定源码

- Repository: https://github.com/immortalwrt/immortalwrt
- Branch: `master`
- Tag: none published for the selected head
- Fixed commit: `4cafb73e88b6cf61cfeca2ee6cf8ecabb60f7a07`
- Linux kernel target: 6.18 (`target/linux/sunxi/Makefile`)
- Reason: 当前在线源码同时提供 `sunxi/cortexa53`、H5 设备、可生成 `sdcard.img.gz` 的 sunxi image 链、固定版本 RTL8189ES 包，以及当前 U‑Boot sunxi package；LEDE 当前 master 未提供同名 RTL8189ES package。
- RTL8189ES path: `package/kernel/rtl8189es`, source commit `0a5d04114fac3c9f48a343cb905fbb6a3f9f5df5`
- sunxi image path: `target/linux/sunxi/image/cortexa53.mk` and `target/linux/sunxi/image/gen_sunxi_sdcard_img.sh`
- U-Boot path: `package/boot/uboot-sunxi`, U-Boot package version `2026.04`

## 实际核对过的上游

- https://github.com/esirplayground/AutoBuild-OpenWrt — 仍可访问，但部分 Workflow 使用 `checkout@master`、`upload-artifact@master`，另有 `upload-artifact@v2`，不直接复制。
- https://github.com/coolsnowwolf/lede — 当前 master，sunxi/cortexa53 可见；当前检出的源码中未找到 `package/kernel/rtl8189es`。
- https://github.com/immortalwrt/immortalwrt — 当前 master 固定为上面的 SHA，含 RTL8189ES 包和 H5 image/U‑Boot 结构。
- https://github.com/friendlyarm/Actions-FriendlyWrt — 当前仍有构建 Workflow，但主要围绕 FriendlyWrt 旧式流程，不能替代现代 OpenWrt 镜像链。
- https://github.com/friendlyarm/sd-fuse_h5 — 当前脚本仍以 FriendlyARM 4.14 镜像和旧 U‑Boot 为中心，只作为启动布局参考。
- https://github.com/armbian/build — 当前包含 `nanopik1plus.conf`、Linux 6.18 K1 DTS 和 U‑Boot K1 补丁；其公开 DTS 含 Broadcom `brcm,bcm4329-fmac` 节点，与真实 RTL8189ES 硬件不一致，因此只取其板级电源、GPIO、eMMC 和 H5 结构参考，并删除该节点。
- https://github.com/u-boot/u-boot — 当前 master 含 NanoPi NEO2、NEO Plus2、R1S H5 的 H5 defconfig/DTS；K1 Plus 使用独立 `nanopi_k1_plus_defconfig` 和 DTS，不假设 NEO Plus2 可原样运行。

## 已知风险

1. K1 Plus 没有被选定 ImmortalWrt 版本原生支持，DTS、Image Profile 和 U‑Boot 都是本项目新增内容。
2. 主线 Linux/U‑Boot 与旧 4.14 运行系统的 MMC 编号和节点绑定可能不同；MicroSD 启动根设备是验收重点。
3. RTL8189ES 是外部驱动，必须以 `rtl8189es.ko` 实际生成、`packages.manifest` 入包和实机 SDIO 日志共同确认。
4. 未采集新的串口启动日志前，不把 Build PASS 写成 Boot PASS。

