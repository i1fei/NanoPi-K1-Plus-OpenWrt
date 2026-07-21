# NanoPi K1 Plus 6.x Wi-Fi Patch Map

Date: 2026-07-21

## Purpose

Map the current repository patches and configs to the future 6.x Wi-Fi
compatibility experiment.

This document answers one question only:

- when Wi-Fi returns to 6.x, which existing changes stay, which changes move to
  the compatibility track, and which ideas must be discarded.

## Current Recovery Baseline

The current validated recovery direction is:

- `eth0` as LAN
- `192.168.1.1`
- LuCI reachable over wired LAN
- onboard Wi-Fi intentionally excluded

That baseline remains the safety line.

## Patch-by-Patch Assessment

### `001-add-k1-plus-dts.patch`

Status:

- KEEP

Reason:

- board DTS is still the foundation for SDIO RTL8189ES, Ethernet PHY, USB,
  power, HDMI, and other board wiring
- official `4.14` live validation confirms the SDIO Wi-Fi path is real

Wi-Fi track role:

- required foundation

### `002-add-k1-plus-device-profile.patch`

Status:

- KEEP

Reason:

- device profile registration is required for both the recovery image and the
  future compatibility experiment

Wi-Fi track role:

- required foundation

### `003-add-k1-plus-network.patch`

Status:

- KEEP for the recovery track
- DO NOT reuse unchanged for the official-style Wi-Fi topology

Reason:

- it intentionally defines the LAN-first recovery model:
  - `ucidef_set_interface_lan "eth0"`
- this is correct for the stable rescue image
- this is intentionally different from official `4.14`

Wi-Fi track role:

- if a future compatibility experiment wants Wi-Fi on the same LAN as Ethernet,
  the modern target should be:
  - `br-lan`
  - `eth0` in `br-lan`
  - `wlan0` AP in `br-lan`
  - `lan.proto=static`
  - `192.168.1.1`

So the Wi-Fi experiment should **not** blindly switch to the official
`wlan0=LAN / eth0=WAN` model, and should **not** reuse this patch unchanged as
the final AP closure either. It needs a separate, deliberate board policy.

### `004-add-stage-a-console-support.patch`

Status:

- KEEP

Reason:

- unrelated to Wi-Fi migration

### `005-add-k1-plus-uboot.patch`

Status:

- KEEP

Reason:

- unrelated to Wi-Fi migration

### `006-restore-k1-plus-hardware-foundation.patch`

Status:

- KEEP

Reason:

- R_PIO, CMA, and cross-MMC auto-mount policy are board-foundation fixes
- none of them conflict with the Wi-Fi compatibility experiment

### `007-stabilize-k1-plus-rtl8189es-radio.patch`

Status:

- KEEP for the current recovery track if Wi-Fi remains excluded
- DO NOT treat its current behavior as the final Wi-Fi strategy

Current behavior:

- makes `50_rtl-wifi` inert
- removes old package-local boot mutations

Why that was useful:

- it prevented the old RTL8189ES package script from mutating shared wireless
  helpers during the LAN-first recovery work

Why it is not enough for the future Wi-Fi track:

- official `4.14` proves the old board needed more than just "do nothing"
- official AP recovery depended on runtime closure after the initial radio
  setup failure
- the final 6.x Wi-Fi experiment may need a very small board-guarded RTL8189ES
  helper again, but only if hardware tests prove it is still required

So the future branch should revisit this patch instead of assuming either:

1. full inert behavior is enough
2. the old vendor script should come back wholesale

### `008-fix-k1-plus-runtime-radio-generation.patch`

Status:

- LIKELY KEEP for the Wi-Fi compatibility track

Reason:

- the single most valuable runtime lesson from earlier 6.x failures was:
  one real PHY must map to one real `radio0`
- this patch explicitly protects against ghost `radio*` growth

Constraint:

- keep the single-radio cleanup idea
- do not confuse it with the final LAN/DHCP design

This patch solves:

- radio ownership
- config drift
- ghost wireless sections

It does **not** solve:

- AP/LAN bridge closure
- DHCP
- first-boot Wi-Fi policy

## Config Assessment

### `configs/NanoPi_K1_Plus_base.config`

Status:

- KEEP as the wired recovery baseline

### `configs/NanoPi_K1_Plus.config`
### `configs/NanoPi_K1_Plus_full.config`

Status:

- KEEP as recovery/full software baselines
- onboard Wi-Fi remains intentionally excluded

Reason:

- current profiles correctly preserve the stable rescue story
- they are not the right place to reintroduce experimental onboard Wi-Fi

## What The First Wi-Fi Compatibility Branch Should Add

The first Wi-Fi branch should add a **separate** configuration target rather
than mutating the current recovery profile in place.

Recommended shape:

1. recovery profile remains unchanged
2. new compatibility profile enables:
   - RTL8189ES package
   - AP-capable Wi-Fi userspace
   - regulatory database
   - basic Wi-Fi inspection tools
3. board policy explicitly creates:
   - `br-lan`
   - `eth0` in `br-lan`
   - `wlan0` AP in `br-lan`
   - static LAN at `192.168.1.1`
   - dnsmasq DHCP on LAN

## Ideas That Must Be Rejected

Do not carry these ideas into the 6.x Wi-Fi branch:

1. "Official `4.14` is the golden DHCP template."
2. "Return to `eth0=WAN` before Wi-Fi on 6.x is stable."
3. "Restoring vendor `50_rtl-wifi` behavior wholesale is enough."
4. "One successful AP beacon means the modern migration is done."
5. "Bluetooth should be bundled into the first Wi-Fi restoration step."

## First Patch-Set Goal

The first compatibility patch set should be judged only by this:

1. wired `192.168.1.1` still works
2. one real onboard AP appears
3. client authentication succeeds
4. client receives DHCP on the shared LAN

Until those four checks pass together, the Wi-Fi migration is not yet correct.
