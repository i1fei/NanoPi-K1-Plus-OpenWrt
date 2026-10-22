# Watchdog v2 CI evidence

- Run: `39710625084`
- Status/conclusion: `completed` / `success`
- Commit: `1ba2a5c32070f9fca7b1042d32190c472fd97021`
- Build job: `119600842724`
- BusyBox used by the simulator step: `BusyBox v1.36.1 (Ubuntu 1:1.36.1-6ubuntu3.1) multi-call binary.`
- Parser assertions: `PASS F1 AP present is healthy`; `PASS F2 missing interface returns unhealthy`; `PASS F3 non-AP info returns unhealthy`; `PASS F4 selects AP across multiple phys/interfaces`.
- Cooldown assertions: `PASS G1 cooldown suppression is logged`; `PASS G1 watchdog continues to stage 1 reload`; `PASS G1 cooldown refusal does not reboot`; `PASS G1 cooldown refusal does not create permanent disable marker`; `PASS G1 cooldown log is rate limited`; `PASS G2 existing disable marker does not stop startup`; `PASS G3 reboot is allowed after cooldown expires`.
- Simulator summary: `ALL PASS`.
- Squashfs SD full-disk image: `ede008aeaa324dcc8bd6f2de1aff2e3eb5a9bcb50944f187f1916005c3dad525`.
- Ext4 SD full-disk image: `36a9bd42a47a0757d28b7bded25945ae80ec28059b509526cf096d233fec4ebb`.
- Final built watchdog file SHA-256 (commits 1 and 2): `6D64FAAD8CB24AD78F7EE634554FEB70761B0B65C77153BCBD5322B520DEDC75`.
- Release metadata remains `STATUS=UNVERIFIED`; the build reports `DRY-RUN: FAILED(non-blocking; see wifi-release-v1-firstboot-dry-run.txt)`.

The local Bash simulator invocation was blocked by the Windows sandbox with `Bash/Service/CreateInstance/E_ACCESSDENIED`. The CI run above executed the full test suite under BusyBox and returned `ALL PASS`.
