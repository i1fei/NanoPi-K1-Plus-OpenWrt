# Build

正式编译由 `.github/workflows/build-nanopi-k1-plus.yml` 完成。

Workflow 会依次：checkout 项目、检查并释放 Runner 空间、安装依赖、Clone 固定 ImmortalWrt SHA、更新 feeds、应用 K1 Plus 补丁、复制配置、`make defconfig`、下载源码、并行编译；并行失败时自动再跑一次单线程详细编译，并上传失败日志。

成功 Artifact 名称：`NanoPi-K1-Plus-OpenWrt`。

验收条件：

- Target 为 `sunxi`
- Subtarget 为 `cortexa53`
- 设备为 NanoPi K1 Plus
- 产物包含 `NanoPi-K1-Plus-*.img.gz`
- 产物包含 K1 Plus DTB、`sha256sums`、构建元数据、`.config` 和 `packages.manifest`
- `packages.manifest` 包含 `kmod-rtl8189es`
- 构建目录实际生成 `rtl8189es.ko`

## WSL 例外

只在确有需要时，把源码放到 Linux 文件系统：

```sh
mkdir -p ~/k1plus-build
git clone https://github.com/i1fei/NanoPi-K1-Plus-OpenWrt ~/k1plus-build
```

不要在 `/mnt/f/K1Plus` 直接运行完整 OpenWrt 编译。不要把本地 `reference` 目录复制到源码或 Artifact。

