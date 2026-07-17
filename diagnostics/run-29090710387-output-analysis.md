# Run 29090710387 Output Analysis

## Build firmware

PASS

## Target

sunxi

## Subtarget

cortexa53

## Output directory

`.work/openwrt/bin/targets/sunxi/cortexa53`

## IMG found in log

YES

## IMG.GZ found in log

YES

## IMG file name

- `immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus-squashfs-sdcard.img.gz`
- `immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus-ext4-sdcard.img.gz`

## Manifest files found

- `immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus.manifest`

## SHA256 file found

The old workflow log shows per-image `.sha256sum` generation and the final `make checksum` step, but it did not list the final target directory. The workflow now writes `target-output-files.txt` on every run so the next run records the exact final checksum files.

## DTB found

YES: `sun50i-h5-nanopi-k1-plus.dtb` was used while creating the K1 Plus FIT image, and artifact collection reached `verify-image.sh`, which means the existing DTB lookup did not fail.

## Exact collection failure

`verify-image.sh` failed with:

```text
packages.manifest missing
```

## Root cause

The ImmortalWrt APK-based build generated a device-named manifest:

```text
immortalwrt-sunxi-cortexa53-friendlyarm_nanopi-k1-plus.manifest
```

The old collection and verification scripts only treated `packages.manifest` as valid, so a successful firmware build was failed during artifact verification because the manifest filename changed.

## Required correction

Discover generated K1 Plus images and manifest files dynamically, keep image/DTB/checksum verification mandatory, and verify `kmod-rtl8189es` when any manifest is present.
