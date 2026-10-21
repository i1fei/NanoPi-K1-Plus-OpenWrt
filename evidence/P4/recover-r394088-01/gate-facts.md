# Recover Round 1 Gate

- Device watchdog SHA-256: `50fcbec9f1c37f2199f8c4f8802e1fc057dd7c0a3ce5ef16358158a0aed1c780`; expected `50FCBEC9F1C37F2199F8C4F8802E1FC057DD7C0A3CE5EF16358158A0AED1C780`.
- `grep -c 'stage3 aborted' /usr/sbin/k1plus-wifi-watchdog`: `1`.
- `/etc/wifi-watchdog.mode`: `recover`.
- `uptime`: `2:03`; `iw dev` listed `phy0-ap0`, `type AP`.
- `/root/WATCHDOG-DISABLED.txt`: present, 60 bytes, `Jul 22 16:53`.
- `/etc/k1plus-watchdog-last-reboot`: present, 11 bytes, `Jul 22 16:42`.
- `/root/wifi-diag/watchdog.log`: present, 5,830 bytes. Full returned text is in the timestamped serial transcript; collected watchdog rows are indexed in `evidence/P3-P4-20261019.md`.
- SSH strict host-key fingerprint matched the ED25519 key read over COM9 (`SHA256:k6+s7T0IBxP2hVlSTxsrINhljBgqteTILbOIP3aRNsE`), but public-key authentication returned `Permission denied (publickey,password)`. Therefore the read-only gate was retrieved by the COM9 fallback after waking the shell. The global `known_hosts` file was not changed; the verified key is stored in `known_hosts.postboot-verified`.
- Source transcript: `evidence/com9-20261020-102145.log`; command response excerpt: `watchdog-gate-com9.log`.
