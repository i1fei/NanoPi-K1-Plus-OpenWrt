# Task AA Report

## AA1 Root Cause

The defect was introduced by commit `6f2964e` in
`patches/nanopi-k1-plus/008-fix-k1-plus-runtime-radio-generation.patch`:

```ucode
let k1_release_provisioned = !!readfile("/etc/wifi-release-done");
```

The first-boot script used `touch /etc/wifi-release-done`, creating a zero-byte
file. On the device, `readfile()` returned `null` for a missing file, `""` for
the zero-byte file, and a non-empty string for a populated file. Therefore the
zero-byte completion marker evaluated false and a later `wifi config` generated
the K1 Plus AP with `disabled='1'`.

The repository scan found the other release gates using file existence tests.
The two source fixes are now:

```ucode
let k1_release_provisioned = readfile("/etc/wifi-release-done") != null;
```

```sh
printf '%s\n' done > /etc/wifi-release-done
```

The ucode path also emits a decision log when the provisioned marker is seen:
`k1plus: release provisioned; preserving enabled wireless policy`.

## AA2 Device Verification

The original device file was backed up as:

```text
/root/mac80211.uc.original-20261015
/root/mac80211.uc.before-aa-fix-20261015
```

Original device SHA-256:

```text
fe2bd727b41affdd88823bfa783fad7dce4bace478eb8fc50f773beaf51d1ec9
```

Temporary fixed-device SHA-256:

```text
562a922d01b8d08fb4c4f0cabd4f00f1ee4e99f968c752186f22bca391b68bb7
```

The device ucode probe returned:

```text
missing_null=true empty=false bool=false
empty_null=false empty=true bool=false
data_null=false empty=false bool=true value=data
```

With the temporary fix installed, three `wifi config` runs returned:

```text
CONFIG_RUN=1 CONFIG_RC=0 disabled='0'
CONFIG_RUN=2 CONFIG_RC=0 disabled='0'
CONFIG_RUN=3 CONFIG_RC=0 disabled='0'
```

The serial log showed the AP being created and attached to the bridge:

```text
cfg80211_rtw_add_virtual_intf(phy0) name:phy0-ap0
rtw_cfg80211_start_ap(phy0-ap0)
br-lan: port 2(phy0-ap0) entered forwarding state
```

The remaining AA2 actions also completed successfully. After each action,
`wireless.default_radio0.disabled='0'`, `iw dev` showed `phy0-ap0` with type
`AP`, and `ubus call network.wireless status` reported `radio0.up=true`,
`pending=false`, `retry_setup_failed=false`, and `ifname=phy0-ap0`:

```text
ubus call network reload       PASS
/etc/init.d/network restart   PASS (temporarily interrupts wired link)
wifi reload                   PASS
```

The network restart log still contains the previously observed driver message
`Free disconnecting network of scanned_queue failed due to pwlan == NULL`, but
the interface was deleted and recreated successfully. This message is not the
cause of the completion-marker regression.

## AA3 and AA4 Status

The repository fix and the dry-run/image validation assertions are staged in
the working tree but have not yet been built into a new image. The dry-run now
requires the completion marker content to be exactly `done`, and the image
validation rejects the old `!!readfile(...wifi-release-done...)` boolean form.

The final clean-TF first-boot test, Q/X hardware validation, and long-duration
stability test remain pending until the fixed image is built and written to a
clean card. The temporary device patch must not be used as evidence for those
final image tests because clearing the overlay removes it.

## Environment Boundary

WSL and POSIX shell execution were unavailable in the Windows sandbox because
the helper returned `E_ACCESSDENIED`. `git diff --check`, source scans, and the
serial/device checks completed. POSIX syntax and full rootfs dry-run validation
must be confirmed by CI or another Linux environment.
