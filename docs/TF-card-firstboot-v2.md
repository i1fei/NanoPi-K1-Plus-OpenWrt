# v2 recover image: clean TF-card first boot

## Image

- Source: Run `39710625084` artifact, recover SD full-disk image.
- Raw file: `artifacts/run-39710625084/NanoPi-K1-Plus-OpenWrt/NanoPi-K1-Plus-sunxi-cortexa53.img`
- Size: 31,893,691 bytes.
- SHA-256: `ED66ED2E37A41B4EF9AF8505345DBD5FA5C1CF13727DA732AF5B92E07D7E6662`.
- The local raw file hash was recalculated from the extracted file. The compressed artifact hash is `ede008aeaa324dcc8bd6f2de1aff2e3eb5a9bcb50944f187f1916005c3dad525`.

## Write and verify

1. Open balenaEtcher, select the raw `.img`, select the intended TF card, then start Flash. Etcher verifies the written data after flashing; do not select the eMMC or another removable drive.
2. When verification completes, eject the card, insert it into the NanoPi, and power on.

## Capture

The COM9 recorder is configured as the current-user scheduled task `Codex-NanoPi-COM9-Recorder`, using 115200 baud, 8 data bits, no parity, and 1 stop bit. If it is not already running, the operator can start it with `Start-ScheduledTask -TaskName Codex-NanoPi-COM9-Recorder`; the log is written under `work/nanopi-release-bridge/evidence/`.

After power-on, the host-side recorder captures the full serial stream without sending input. The existing validation workflow records the boot banner, PHY/AP creation timestamps, watchdog events, SSH availability, and the 600-second startup snapshot. No device-side command is needed from the user.

## Time estimate

Allow about 10–20 minutes for card writing and verification, plus at least 10 minutes for the startup observation. Total estimate: 20–35 minutes, depending on the card and reader. This is an estimate; no clean-card first boot has yet been recorded.
