# NanoPi K1 Plus OpenWrt

这是 FriendlyElec NanoPi K1 Plus 的可复现移植工程，默认从固定的 ImmortalWrt 源码版本构建 `sunxi/cortexa53` MicroSD 镜像。

硬件依据是真实运行设备：Allwinner H5、4× Cortex-A53、2 GiB DDR3、单千兆以太网口、RTL8189ES SDIO Wi‑Fi（SDIO ID `024C:8179`）、MicroSD 和约 16 GiB eMMC。硬件参考资料保留在本地 `F:\K1Plus\reference`，不会进入本仓库。

## 当前状态

| 项目 | 状态 |
| --- | --- |
| Build | NOT RUN |
| Boot | UNTESTED |
| Ethernet | UNTESTED |
| RTL8189ES | UNTESTED |
| USB | UNTESTED |
| eMMC | READ-ONLY TEST PENDING |

编译成功不等于硬件已经验证；详见 [STATUS.md](STATUS.md)。

## GitHub Actions

打开 Actions，运行 `Build NanoPi K1 Plus`，默认使用 [docs/SOURCE_DECISION.md](docs/SOURCE_DECISION.md) 中的固定源码 SHA。成功产物名为 `NanoPi-K1-Plus-OpenWrt`，验收必须包含：

- `NanoPi-K1-Plus-sunxi-cortexa53.img.gz`
- K1 Plus DTB
- `sha256sums`
- `config.buildinfo`、`feeds.buildinfo`、`version.buildinfo`
- `packages.manifest`、完整 `.config` 和编译日志

默认网络只把 `eth0` 放入 LAN，管理地址为 `192.168.1.1/24`。Wi‑Fi 默认不写入任何密码，也不复制旧 FriendlyWrt 配置；RTL8189ES 真实验证成功后，再按需要配置 `wlan0`。

## 安全启动规则

第一版只面向新的备用 MicroSD。不会自动写入、格式化、清除或修改 eMMC；首次测试步骤见 [docs/FIRST_BOOT.md](docs/FIRST_BOOT.md)。

## 本地构建

正式构建默认交给 GitHub Actions。若必须使用 WSL，请把源码放在 Linux 文件系统，例如 `~/k1plus-build`，不要在 `/mnt/f/K1Plus` 直接运行完整 `make -j`；步骤见 [docs/BUILD.md](docs/BUILD.md)。

