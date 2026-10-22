# Watchdog Parser V2 Test Evidence

Base: `76698e3` (`diag/wifi-watchdog-stage3-guard-20261020`).

Local runner: Git Bash on Windows. These local runs use the host's awk/grep/sh, not BusyBox. CI is configured to rerun the same suite with BusyBox `sh`, `awk`, and `grep`, and print the BusyBox version.

## Fixed Parser

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
ALL PASS
TEST_EXIT=0
```

## Old Parser Negative Control

Command used the `76698e3` watchdog blob as input to the same new test script:

```text
git show 76698e3:overlays/wifi_release_v1/files/usr/sbin/k1plus-wifi-watchdog > "$tmp/watchdog-76698e3"
bash scripts/test-wifi-watchdog-sim.sh "$tmp/watchdog-76698e3" overlays/wifi_release_v1/files/usr/libexec/wifi-diag-collect.sh
```

Complete output:

```text
== A: observe mode ==
PASS  A threshold reached logged
PASS  A predicate rc line logged
PASS  A observe bundle written
PASS  A NO reload was issued
FAIL  A self-recovery logged
== B: recover mode ==
PASS  B exactly one reload
FAIL  B post-reload OK logged
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
FAIL  E stage 3 abort logged
FAIL  E stage 3 did not call sync or reboot
FAIL  E aborted stage 3 did not consume reboot cooldown
== F: tab-indented iw parser fixtures ==
FAIL  F1 AP present is healthy
PASS  F2 missing interface returns unhealthy
FAIL  F3 non-AP info returns unhealthy
FAIL  F4 selects AP across multiple phys/interfaces
FAILED -- artifacts kept in /tmp/tmp.6sz5RsXYow
OLD_VERSION_TEST_EXIT=1
```

These failures are expected for the old watchdog; the negative control confirms the new AP-discovery assertions detect the tab-indented interface line.
