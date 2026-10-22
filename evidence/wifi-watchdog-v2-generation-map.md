# Wi-Fi Watchdog V2 Generation Map

Source records are in the sibling checkout `../nanopi-release-bridge/evidence`. `boot_id` was not captured in the available round metadata/logs; it is therefore reported as not recorded. `HEALTH` means a runtime watchdog log row exists in the round evidence, not merely that the source contains the logging code. Stage/reboot values are uptime seconds from the recorded boot; `unknown` means the surviving evidence does not establish attribution.

| Image generation / round | Boot ID | First AP uptime | Runtime HEALTH | Stage 3 / reboot uptime | Evidence |
|---|---|---:|---|---|---|
| Recover Run 38939238849 / R01 | not recorded | 23.879537s | no; image predates runtime HEALTH instrumentation | stage 3 observed; reboot 619.152554s | `../nanopi-release-bridge/evidence/P4/recover-01/round.json`, `round.log`, COM9 log |
| Recover Run 38939238849 / R02 | not recorded | 180.722414s | no; image predates runtime HEALTH instrumentation | stage 3 attribution unknown; reboot 484.131545s | `../nanopi-release-bridge/evidence/P4/recover-02/round.json`, `round.log`, COM9 log |
| Recover Run 39408824234 / R01 | not recorded | 181.462080s | yes; captured gate log | stage 3 observed; reboot 620.724521s | `../nanopi-release-bridge/evidence/P4/recover-r394088-01/`, COM9 log |
| Recover Run 39408824234 / R02 | not recorded | 182.320600s | yes; captured gate log | stage 3 observed; reboot 621.194569s | `../nanopi-release-bridge/evidence/P4/recover-r394088-02/`, COM9 log |
| Recover Run 39408824234 / R03 | not recorded | 23.953909s | yes | stage 3 observed; reboot 620.944540s | `../nanopi-release-bridge/evidence/P4/recover-r394088-03/round.json`, `watchdog.log` |
| Recover Run 39408824234 / R04 | not recorded | 179.719701s | yes | stage 3 observed; reboot 618.744559s | `../nanopi-release-bridge/evidence/P4/recover-r394088-04/round.json`, `watchdog.log` |
| Recover Run 39408824234 / R05 | not recorded | 180.339954s | yes | stage 3 observed; reboot 619.383551s | `../nanopi-release-bridge/evidence/P4/recover-r394088-05/round.json`, `watchdog.log` |
| Recover Run 39408824234 / R06 | not recorded | 180.589233s | yes | stage 3 observed; reboot 619.783489s | `../nanopi-release-bridge/evidence/P4/recover-r394088-06/round.json`, `watchdog.log` |
| Observe Run 39229375745 / R01 (P3 cycle) | not recorded | absent at captured 179s and 331s | no; runtime HEALTH fields are absent from the round record | not applicable; observe mode suppresses recovery | `../nanopi-release-bridge/evidence/P3/`, `evidence/P3-P4-20261019.md` |
| Observe Run 39229375745 / R02 | not recorded | absent at T+300 and uptime 605s | no; runtime HEALTH fields are absent from the round record | no stage 3; reboot 774.814903s is recorded without watchdog attribution | `../nanopi-release-bridge/evidence/P4/observe-02/round.json`, `state.log` |
| Observe Run 39416504363 / R01 | not recorded | absent through 600s | yes | no stage 3; no reboot recorded | `../nanopi-release-bridge/evidence/P4/observe-r394165-01/round.json`, `watchdog.log` |
| Observe Run 39416504363 / R02 | not recorded | absent through 600s | yes | no stage 3; no reboot recorded | `../nanopi-release-bridge/evidence/P4/observe-r394165-02/round.json`, `watchdog.log` |
| Observe Run 39416504363 / R03 | not recorded | absent through 600s | yes | no stage 3; no reboot recorded in its observation window | `../nanopi-release-bridge/evidence/P4/observe-r394165-03/round.json`, `watchdog.log` |
| Observe Run 39416504363 / R04 | not recorded | absent through 600s | yes | no stage 3; no reboot recorded | `../nanopi-release-bridge/evidence/P4/observe-r394165-04/round.json`, `watchdog.log` |

## Generation Corrections

- The legacy `recover-01` / `recover-02` directories use Run 38939238849 (`efda7b98...14477bb`). They are not the first two rounds of Run 39408824234.
- `recover-r394088-01` through `-06` all use Run 39408824234 (`79bfeb14...a60d93b`). AP first appeared near 180 seconds in five rounds (R01, R02, R04, R05, R06), and at 23.953909 seconds in one round (R03).
- The old observe pair uses Run 39229375745 (`d7e277...ffba`); the later observe batch uses Run 39416504363 (`438f2315...4752cb`). These are separate image generations.
- Rows with `no runtime HEALTH` mean no `HEALTH hostapd_rc=...` row appears in the round record; `yes` means the raw round evidence contains those runtime rows. The first-run recover R01/R02 HEALTH rows are in captured gate transcripts rather than standalone `watchdog.log` files.
- Across the six Run 39408824234 recover rounds, runtime `stage3 aborted` log rows were not observed. The phrase exists in the watchdog source as a guard event; its presence in source is not a runtime event.

Root cause for why some boots do not create the AP interface remains unlocated. No release acceptance is inferred from this evidence map.
