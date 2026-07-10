# First boot

这份清单只适用于第一版 MicroSD 测试：

1. 只使用新的备用 MicroSD，保留原 FriendlyWrt SD 卡。
2. 不要写入 eMMC，不要格式化 eMMC，不要修改 eMMC Boot 分区。
3. Windows 可用 Rufus 或 balenaEtcher 写入 `NanoPi-K1-Plus-*.img.gz`。
4. Linux 写卡前必须确认 `/dev/sdX` 是备用卡：

```sh
gzip -dc firmware.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

串口使用 3.3V TTL、115200、8N1；连接 GND、RX、TX，禁止连接 USB-TTL 5V。

首次启动后，仅执行以下只读检查：

```sh
cat /proc/device-tree/model
uname -a
ip -br link
ip -br addr
lsmod
dmesg | grep -Ei 'mmc|emmc|eth|stmmac|rtl8211|8189|sdio|usb|thermal|cpufreq'
```

重点记录：串口完整启动日志、`mmc`/SDIO 枚举、`rtl8189es` 加载、有线网口、USB、CPU 调频和温控。未经确认，不执行任何 eMMC 写入命令。

