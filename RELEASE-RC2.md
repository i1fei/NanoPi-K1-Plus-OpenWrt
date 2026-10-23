# Release RC2 evidence record

This file records observed facts only. The wireless startup root cause remains unresolved; this is not a release approval.

## Images

- Recover image: Run `39710625084`, commit `1ba2a5c32070f9fca7b1042d32190c472fd97021`, SHA-256 `ede008aeaa324dcc8bd6f2de1aff2e3eb5a9bcb50944f187f1916005c3dad525`.
- Raw image extracted from the Run artifact: SHA-256 `ED66ED2E37A41B4EF9AF8505345DBD5FA5C1CF13727DA732AF5B92E07D7E6662`, 31,893,691 bytes. It has not been written to a clean TF card.
- Observe image: not built for v2.

## Recorded validation

- Parser and cooldown simulator assertions ran under BusyBox v1.36.1 in CI and reported `ALL PASS`; see `evidence/wifi-watchdog-v2-ci-39710625084.md`.
- Six recover-image device rounds were recorded in `evidence/P3-P4-20261022-v2.md` and `evidence/P4/recover-v2-r397106-01/` through `-06/`.
- AP first appeared at 34.172140 seconds in R01, 181.216914 in R02, 183.400230 in R03, 183.048513 in R04, 180.899256 in R05, and 179.350525 in R06.
- Stage 1 `wifi reload` was recorded in R02–R06 at 180, 182, 182, 180, and 178 seconds respectively. Stage 2, `health recovered`, stage 3 abort, and watchdog reboot events were not recorded in these six rounds.
- The two-hour stability observation recorded 24 successful SSH samples, AP present in all samples, unchanged boot ID, and no recorded reboot; see `evidence/P4/stability-v2-20261022-163948.log`.
- CI cooldown tests passed. The six round watchdog logs and the current device watchdog log contain no `reboot suppressed by cooldown` event; device execution of that branch is unverified.
- Current device snapshot was read over SSH on 2026-10-23: mode `recover`, AP interface `phy0-ap0` present, watchdog SHA-256 `6d64faad8cb24ad78f7ee634554feb70761b0b65c77153bcbd5322b520dedc75`, boot ID `b6831a18-0d14-46db-b277-750550baaa7c`.

## Not recorded or incomplete

- Clean TF-card write and first boot.
- PC client reconnection and DHCP lease.
- Q3 mode A/B, automatic switch-back, and address-conflict checks.
- Five normal reboots, Wi-Fi rapid reconnect, idle recovery, online driver unload/reload, multi-client test, and eight-hour stability are not present in the old AC record. The six v2 boot rounds and two-hour stability are separate evidence and do not cover those checks.
- The v2 real-device cooldown suppression path has not been exercised.
- Q/X4 is not defined as a standalone acceptance label in `AC-REPORT.md`; that document labels Q3, X, and Q4 separately.

## Known issue

- In the six v2 recover rounds, five boots had no AP until stage 1 ran near 180 seconds. The cause of delayed AP creation remains unresolved.
