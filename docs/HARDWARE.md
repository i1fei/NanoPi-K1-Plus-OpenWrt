# Hardware

以下信息来自本地真实运行设备的硬件资料，不是本仓库猜测：

- Board: FriendlyElec NanoPi K1 Plus
- Device Tree compatible: `friendlyelec,nanopi-k1-plus`, `allwinner,sun50i-h5`
- SoC: Allwinner H5
- CPU: 4× ARM Cortex-A53, `aarch64`
- Memory: 2 GiB DDR3
- Ethernet: Allwinner `dwmac-sun8i` with RTL8211E Gigabit PHY
- Wi‑Fi: Realtek RTL8189ES over SDIO, ID `024C:8179`, driver `rtl8189es`
- Storage: MicroSD on `mmc0`; onboard eMMC approximately 16 GiB
- Existing serial console: `ttyS0` at 115200 baud

本地参考目录是 `F:\K1Plus\reference`，只读使用，不复制进 Git 仓库。原始运行 DTS、DTB 和信息文件不作为公开文件提交。

第一版只做 MicroSD 启动。eMMC 只保留识别和后续只读测试的路径，不执行自动写入、格式化、Boot 分区修改或清除。

