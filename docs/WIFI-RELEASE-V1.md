# Wi-Fi release v1 design

Status: UNVERIFIED until task P hardware validation passes.

The `lan` interface owns `br-lan` with `eth0` as its static bridge port.
`wireless.default_radio0.network='lan'` makes netifd add the runtime AP
interface to the same bridge without hard-coding a driver-owned interface
name into the bridge port list. The RTL8189ES interface currently appears as
`phy0-ap0` on the tested image.
The mode service changes only IPv4 addresses, routes, and the dedicated
fallback DHCP process; it never invokes `wifi` or restarts hostapd.
The PC is only a test client; it does not run DHCP or participate in this
state machine.

Mode A runs an upstream DHCP client on `br-lan` with hostname
`nanopi-k1plus`. Mode B first runs duplicate-address detection, then uses
`192.168.1.1/24` and serves `192.168.1.100-199`. The fallback server is stopped
before every upstream probe. All timing and address values are in
`/etc/config/k1plus_network`.

The current validation upstream is `192.168.10.0/24` with gateway
`192.168.10.254`. This is test-environment information, not firmware policy.

The AP uses a 30-minute inactivity limit to tolerate sleeping IoT clients,
disables low-ACK disassociation because the legacy driver can report noisy ACK
health, and limits associations to 16. Runtime logs previously showed a driver
station pool of 32, so 16 stays below that limit and leaves driver headroom.

The Wi-Fi watchdog checks every 30 seconds. Five consecutive failures cause a
Wi-Fi reload, followed by a 60-second grace period. A second set causes a
driver reload followed by another Wi-Fi reload; a third set reboots. Recovery
is capped at three escalations per hour and is suppressed when an administrator
has disabled wireless in UCI. The watchdog never uses `wifi down` or `wifi up`.
The hardware watchdog is driven by procd with a 30-second timeout and a
5-second ping period, allowing six missed pings before reset.

Known limitation: on the tested RTL8189ES stack, manual `wifi down` followed by
`wifi up` is not reliable and may leave the kernel AP interface and netifd's
UBus state out of sync. The X validation reproduced this in 5/5 rounds. Use
`wifi reload` or a normal reboot instead; this path is excluded from automatic
watchdog recovery.
