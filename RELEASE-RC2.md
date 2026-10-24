# Release RC2 evidence record

This file records observed facts only. The wireless startup root cause remains unresolved; this is not a release approval.

## Images

- Recover image: Run `39710625084`, commit `1ba2a5c32070f9fca7b1042d32190c472fd97021`, SHA-256 `ede008aeaa324dcc8bd6f2de1aff2e3eb5a9bcb50944f187f1916005c3dad525`.
- Raw image extracted from the Run artifact: SHA-256 `ED66ED2E37A41B4EF9AF8505345DBD5FA5C1CF13727DA732AF5B92E07D7E6662`, 31,893,691 bytes. It has not been written to a clean TF card.
- Observe image: not built for v2.

## 已验证

- Parser and cooldown simulator assertions ran under BusyBox v1.36.1 in CI and reported `ALL PASS`; see `evidence/wifi-watchdog-v2-ci-39710625084.md`.
- Six recover-image device rounds were recorded in `evidence/P3-P4-20261022-v2.md` and `evidence/P4/recover-v2-r397106-01/` through `-06/`.
- AP first appeared at 34.172140 seconds in R01, 181.216914 in R02, 183.400230 in R03, 183.048513 in R04, 180.899256 in R05, and 179.350525 in R06.
- Stage 1 `wifi reload` was recorded in R02–R06 at 180, 182, 182, 180, and 178 seconds respectively. Stage 2, `health recovered`, stage 3 abort, and watchdog reboot events were not recorded in these six rounds.
- The two-hour stability observation recorded 24 successful SSH samples, AP present in all samples, unchanged boot ID, and no recorded reboot; see `evidence/P4/stability-v2-20261022-163948.log`.
- CI cooldown tests passed. The six round watchdog logs and the current device watchdog log contain no `reboot suppressed by cooldown` event; device execution of that branch is unverified.
- Current device snapshot was read over SSH on 2026-10-23: mode `recover`, AP interface `phy0-ap0` present, watchdog SHA-256 `6d64faad8cb24ad78f7ee634554feb70761b0b65c77153bcbd5322b520dedc75`, boot ID `b6831a18-0d14-46db-b277-750550baaa7c`.

## 未验证

- Clean TF-card write and first boot.
- PC client reconnection and DHCP lease.
- Q3 mode A/B, automatic switch-back, and address-conflict checks.
- Five normal reboots, Wi-Fi rapid reconnect, idle recovery, online driver unload/reload, multi-client test, and eight-hour stability are not present in the old AC record. The six v2 boot rounds and two-hour stability are separate evidence and do not cover those checks.
- The v2 real-device cooldown suppression path has not been exercised.
- Q/X4 is not defined as a standalone acceptance label in `AC-REPORT.md`; that document labels Q3, X, and Q4 separately.

## Known issue

- In the six v2 recover rounds, five boots had no AP until stage 1 ran near 180 seconds. The cause of delayed AP creation remains unresolved.

## 已知设计问题

- `allow_recovery()` increments `recovery_count` and returns 1 after the fourth recovery inside the 3600-second window (`overlays/wifi_release_v1/files/usr/sbin/k1plus-wifi-watchdog:104-116`). Its caller uses `allow_recovery || exit 0` for stage 1, stage 2, and stage 3 (`.../k1plus-wifi-watchdog:203-205,222-224,243-245`), so the watchdog process exits without executing that recovery step. The init script configures `procd_set_param respawn 3600 5 5` (`overlays/wifi_release_v1/files/etc/init.d/k1plus-wifi-watchdog:10`); this is the configured respawn policy for repeated short-lived exits.
- The same recovery-limit branch writes `/root/WATCHDOG-DISABLED.txt` (`.../k1plus-wifi-watchdog:111-114`). A repository search found no read of that path in the v2 watchdog or its init script; the administrator stop mechanism that is read is the UCI `.disabled='1'` check (`.../k1plus-wifi-watchdog:89-102`).
- Current watchdog values are `interval=30`, `failure_threshold=5`, `reload_grace=60`, `command_timeout=25`, `recovery_window=3600`, `max_recoveries=3`, and `reboot_cooldown=3600` (`overlays/wifi_release_v1/files/etc/config/k1plus_watchdog:2-8`). With no earlier healthy check, the loop sleeps 30 seconds before its first check and reaches the fifth failed check after approximately 150 seconds, before stage 1; stage 1 then waits 60 seconds after `wifi reload` (`.../k1plus-wifi-watchdog:172-211`). These values therefore set the earliest first escalation timing; observed AP creation timing remains an observation, not a root-cause conclusion.

## 追加记录：已验证

- B1 ordinary reboot observation: ten requested reboots were recorded. Serial logs show `phy0-ap0` creation from 23.278655s to 24.413122s after boot; all ten were before uptime 60s. The per-boot watchdog records show no stage 1/2/3 event during the observation windows. Evidence: `evidence/device-v2-followup-20261023.md`, `evidence/device-v2-Reboot-20261023-090532/runner.log`, and `reboot-01..10-com9.log` / `reboot-01..10-watchdog.log`.
- B2 AP deletion injection 1: `iw dev phy0-ap0 del` returned rc 0 at T0 uptime 730.34s; AP was observed again at uptime 873s (141s elapsed), with stage 1 recorded at 873s and no stage 2/3 or reboot in the capture. Evidence: `evidence/device-v2-FaultInjection-20261023-105016/fault-01-delete-ap-*`.
- B2 AP deletion injection 2: `iw dev phy0-ap0 del` returned rc 0 at T0 uptime 1326.41s. AP remained absent through the monitor's last observation at uptime 2040s; stage 1 was logged at 1450s and stage 2 at 1666s. `killall hostapd` was not run. Evidence: `evidence/device-v2-FaultInjection-20261023-105016/fault-02-delete-ap-*`.
- B3 driver reload attempt: the sequence `/sbin/kmodloader -r rtl8189es`, `/sbin/kmodloader rtl8189es`, `wifi reload` returned rc 0 for all three commands at T0 uptime 2336s. The AP was absent in the first post-command sample, SSH reset, and the serial log later recorded `reboot: Restarting system` at uptime 2477.783493s. The accepted attribution for this event is watchdog stage 3, based on the complete watchdog/serial log chain; B3 command completion preceded it but the command output itself does not identify the reboot initiator. Evidence: `evidence/device-v2-FaultInjection-20261023-105016/b3-driver-reload.log`, `b3-post-sequence-snapshot.log`, `b3-com9-tail.log`, and `evidence/incident-2477-readonly-20261023/`.
- Wireless startup comparison: the accepted log comparison found that failed startup windows lacked `cfg80211_rtw_add_virtual_intf(phy0)` and `rtw_ndev_init(phy0-ap0)` before the delayed recovery, while normal startup samples recorded those events near 24s. In the six v2 recover rounds, AP creation was recorded at 34.172140s in R01 and 179.350525–183.400230s in R02–R06. The parser defect in the earlier watchdog was separately reproduced: the real indented `iw dev` output did not satisfy its beginning-of-line interface match. The startup reason for the delayed AP creation remains unresolved. Evidence: `evidence/wifi-watchdog-v2-generation-map.md`, `evidence/P4/recover-v2-r397106-01/` through `-06/`, `evidence/device-v2-Reboot-20261023-090532/`, and `../nanopi-release-bridge/evidence/live-fail-old-fw-20261020-181031/device-capture-redacted.log`.

## 追加记录：未验证

- The second `killall hostapd` injection, further B2 injections, and a clean TF-card first boot have not been recorded. The second delete-AP attempt did not meet the required AP-stable precondition for the next injection.
- B3 does not establish the effect of an isolated driver unload/reload: the command sequence was issued while AP recovery was still incomplete and watchdog stage 2 was active. No isolated rerun was performed.
- The eight-hour stability observation was not completed. The run stopped after the reboot event; the available stability record is two hours, not eight.
- Clean-card first boot remains pending the user's physical write, insertion, and power-on. No device commands are sent before the user reports power-on.
