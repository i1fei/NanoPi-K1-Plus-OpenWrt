# RTL8189ES Inert Validation

## Build artifact gate

For a successful rtl8189es_inert run, archive these files together:

    sha256sum rtl8189es.ko *.img *.img.gz > sha256sums.rtl8189es-inert

The CI artifact collector copies the module to rtl8189es.ko and records its
original build path in rtl8189es.build-check.txt. The expected module path
inside the build tree is:

    build_dir/.../linux-sunxi_cortexa53/rtl8189es-*/rtl8189es.ko

## Stage A: inert profile and lock regression

Run after flashing the rtl8189es_inert image:

- lsmod, modinfo rtl8189es, iw dev, and iw phy
- ip -br link, ip -br addr, ip route, and ethtool eth0
- Repeat Wi-Fi interface up/down and iw dev/iw phy queries
- Create and delete the P2P interface when the driver exposes P2P support
- Repeat the same checks while watching dmesg for sdio_rx_dpc packet/elapsed logs
- Confirm eth0 remains linkable and its address/route do not change

When the lockup reproduces, run as root:

    /root/collect-task-census.sh /overlay/k1plus-task-census

This records every readable task state, comm, wchan, and /proc/<pid>/stack
without filtering on D, S, or R.

## Stage B: functional Wi-Fi profile

The inert profile intentionally excludes AP/userspace Wi-Fi packages. Run these
only with the Wi-Fi compatibility profile:

- iwinfo/iw dev/iw phy capability checks
- WPA2 association
- DHCP lease acquisition
- sustained throughput measurement
- repeated association/disassociation and P2P create/delete
- eth0 regression checks during Wi-Fi activity

This build contains only RX DPC packet-count/elapsed-time logging. It does not
contain IPS, rtw_hal_init, or rtw_hal_deinit stage tracing, and it does not
add a bips_processing timeout.
