# Watchdog Cooldown V2 Test Evidence

Base behavior commit: `6e9cffe`.

Local runner: Git Bash on Windows. The CI workflow reruns this suite with BusyBox applets; that runner result is pending the recover build.

Command:

```sh
bash scripts/test-wifi-watchdog-sim.sh \
  overlays/wifi_release_v1/files/usr/sbin/k1plus-wifi-watchdog \
  overlays/wifi_release_v1/files/usr/libexec/wifi-diag-collect.sh
```

Complete output:

```text
== A: observe mode ==
PASS  A threshold reached logged
PASS  A predicate rc line logged
PASS  A observe bundle written
PASS  A NO reload was issued
PASS  A self-recovery logged
== B: recover mode ==
PASS  B exactly one reload
PASS  B post-reload OK logged
PASS  B pre-reload collection succeeded
PASS  B pre-reload bundle written
PASS  B post-reload bundle written
PASS  B real collector initial rc=0
PASS  B second pre-reload skipped rc=3
PASS  B secret never written to disk
PASS  B redaction marker present
PASS  B watchdog log has timeline
PASS  B watchdog log has first failure
== C: observe mode at driver-reload stage ==
PASS  C observe did not call driver reload
== D: observe mode at reboot stage ==
PASS  D observe did not call sync or reboot
== E: stage 3 healthy recheck aborts reboot ==
PASS  E stage 3 abort logged
PASS  E stage 3 did not call sync or reboot
PASS  E aborted stage 3 did not consume reboot cooldown
== F: tab-indented iw parser fixtures ==
PASS  F1 AP present is healthy
PASS  F2 missing interface returns unhealthy
PASS  F3 non-AP info returns unhealthy
PASS  F4 selects AP across multiple phys/interfaces
== G: cooldown suppression keeps recovery active ==
PASS  G1 cooldown suppression is logged
PASS  G1 watchdog continues to stage 1 reload
PASS  G1 cooldown refusal does not reboot
PASS  G1 cooldown refusal does not create permanent disable marker
PASS  G1 cooldown log is rate limited
PASS  G2 existing disable marker does not stop startup
PASS  G3 reboot is allowed after cooldown expires
ALL PASS
TEST_EXIT=0
```
