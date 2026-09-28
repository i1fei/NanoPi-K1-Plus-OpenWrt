# RTL8189ES Inert Build Audit

This document records the source audit for the validation build. Line numbers
refer to the pristine source at upstream commit
`0a5d04114fac3c9f48a343cb905fbb6a3f9f5df5`; patch files are applied in numeric
order by `scripts/apply-patches.sh`.

## Task 1: open and close paths

### `netdev_open()`

`os_dep/linux/os_intfs.c:_netdev_open()` calls `rtw_hal_init()` at source
lines 3564 and 3692, then starts driver threads at 3569 and 3703, and starts
the interface at 3575 and 3718. The wrapper is serialized by
`hw_init_mutex` in `pm_netdev_open()` at lines 3809-3831.

The RTL8188ES HAL binding is in
`hal/rtl8188e/sdio/sdio_halinit.c:1738-1739`:

```c
hal_func.hal_init = &rtl8188es_hal_init;
hal_func.hal_deinit = &rtl8188es_hal_deinit;
```

`rtl8188es_hal_init()` has a time-bounded CPWM polling loop at
`sdio_halinit.c:994-1014`; it exits on state change or when
`LPS_RPWM_WAIT_MS` expires. `HalPwrSeqCmdParsing()` has a polling counter at
`hal/HalPwrSeqCmd.c:137-160` and returns failure after `maxPollingCnt` (5000
or 100000) is exceeded. These two loops are bounded in the audited source.

### `netdev_close()`

The actual order in `os_dep/linux/os_intfs.c:4071-4179` is:

1. `rtw_hw_client_port_release()` when enabled.
2. `rtw_netif_stop_queue()`.
3. `LeaveAllPowerSaveMode()`.
4. `rtw_disassoc_cmd(..., 500, RTW_CMDF_WAIT_ACK)`.
5. `rtw_indicate_disconnect()`.
6. `rtw_free_assoc_resources_cmd(..., RTW_CMDF_WAIT_ACK)`.
7. `rtw_free_network_queue()`.
8. `nat25_db_cleanup()` when bridge extension is enabled.
9. `rtw_p2p_enable(..., P2P_ROLE_DISABLE)` when P2P is enabled.
10. `rtw_scan_abort()`.
11. `rtw_cfg80211_wait_scan_req_empty(padapter, 200)`.
12. `bips_processing` wait at source lines 4166-4168.
13. `rtw_dev_unload()` at line 4170.
14. `rtw_sdio_set_power(0)` at line 4171.

The original unbounded wait was:

```c
while (pwrctl->bips_processing == _TRUE)
    rtw_msleep_os(1);
```

Patch `013-timeout-rtl8189es-bips-close.patch` bounds this wait to 5000
iterations, emits `RTW_TIMEOUT:`, marks the adapter stopped and
surprise-removed, and returns before `rtw_dev_unload()` if the transition did
not complete. It does not claim that hardware unload completed.

`rtw_dev_unload()` at `os_dep/linux/os_intfs.c:4496-4564` calls
`rtw_intf_stop()`, `rtw_stop_drv_threads()`, and then `rtw_hal_deinit()`.
`rtw_hal_deinit()` binds to `rtl8188es_hal_deinit()` at
`hal/rtl8188e/sdio/sdio_halinit.c:1435`, which only calls
`rtw_hal_power_off()` when hardware initialization is complete and returns
`_SUCCESS`.

`rtw_stop_drv_threads()` at `os_dep/linux/os_intfs.c:2173-2212` calls
`rtw_thread_stop()`, which maps to `kthread_stop()` at
`include/osdep_service.h:427-431`. `kthread_stop()` synchronously waits for
the target thread to exit. This is a remaining lifecycle risk: this build does
not replace it with an unsafe timeout that would release adapter state while a
kernel thread could still access it. A future bounded stop requires a complete
thread-lifetime design, not a caller-side early return.

## Task 2: runtime evidence

Patch `014-rtl8189es-runtime-trace.patch` adds:

- `RTW_TRACE: IPS_ENTER_BEGIN/END` and `IPS_LEAVE_BEGIN/END` in
  `core/rtw_pwrctrl.c:_ips_enter()` and `_ips_leave()`.
- `RTW_TRACE: HAL_INIT_BEGIN/END` and `HAL_DEINIT_BEGIN/END` in
  `hal/hal_intf.c`, with elapsed time and status. The open call sites emit
  `HAL_INIT_PATH=netdev_open` or `HAL_INIT_PATH=ips_netdrv_open`; the close
  call site emits `HAL_DEINIT_PATH=netdev_close->rtw_dev_unload`.
- `RTW_TRACE: HAL_DEINIT_PATH=netdev_close->rtw_dev_unload` at the complete
  close/unload path.
- `sdio_rx_dpc: packets=... elapsed_ms=...` in patch `012`.
- `RTW_SDIO_CLAIM: request/acquired/released` around driver-owned claims in
  `sd_read()`, `sd_write()`, `rtw_sdio_raw_read()`, and
  `rtw_sdio_raw_write()` in `os_dep/linux/sdio_ops_linux.c`. IRQ-thread-owned
  claims are not duplicated because `rtw_sdio_claim_host_needed()` explicitly
  detects that context.
- `RTW_TIMEOUT: netdev_close bips_processing ...` in patch `013`.

## Verification boundary

The patch chain has been applied successfully to a pristine checkout of the
exact upstream commit and passed `git diff --check`. This proves patch
applicability only. It does not prove cross-compilation, module inclusion,
boot, or device behavior. Those remain separate gates in
`rtl8189es-inert-validation.md`.

## Task 2: kthread_stop audit

`rtw_stop_drv_threads()` is implemented at
`os_dep/linux/os_intfs.c:2173-2212`. It stops the command thread for the
primary adapter, then the optional event, transmit, and receive threads, and
finally calls `rtw_hal_stop_thread()`. `rtw_thread_stop()` maps directly to
`kthread_stop()` at `include/osdep_service.h:427-431`.

| Thread function | Creation | Exit condition | Hardware access | Covered by 014 |
|---|---|---|---|---|
| `rtw_cmd_thread()` | `os_dep/linux/os_intfs.c:2146`, `kthread_run()` | `core/rtw_cmd.c:543-728`; exits on command semaphore failure or `RTW_CANNOT_RUN` | Yes; queued handlers call HAL functions, e.g. `core/rtw_cmd.c:3276-3288` | No direct thread-stop timing; HAL calls are covered only where they pass through patched HAL entry points |
| `rtw_xmit_thread()` | `os_dep/linux/os_intfs.c:2121` | `core/rtw_xmit.c:5734-5737`; exits when `rtw_hal_xmit_thread_handler()` is not `_SUCCESS` | Yes, through `rtw_hal_xmit_thread_handler()` at `core/rtw_xmit.c:5734` | No direct coverage |
| `rtw_recv_thread()` | `os_dep/linux/os_intfs.c:2134` | `core/rtw_recv.c:4882-4909`; exits on semaphore failure, `RTW_CANNOT_RUN`, or `rtw_hal_recv_hdl()` failure | Yes, `rtw_hal_recv_hdl()` at `core/rtw_recv.c:4894` | No direct coverage |
| `rtl8189es_xmit_thread()` (`RTWHALXT`) | `hal/rtl8188e/rtl8188e_hal_init.c:2371-2376` | `hal/rtl8188e/sdio/rtl8189es_xmit.c:1364-1367`; exits when `rtl8189es_xmit_handler()` is not `_SUCCESS` | Yes; handler waits on `SdioXmitSema` and performs SDIO TX at `rtl8189es_xmit.c:1296` and following handler code | No direct coverage |
| `rtw_event_thread()` | Stop site `os_dep/linux/os_intfs.c:2179-2183`; event semaphore init `core/rtw_cmd.c:145-149` | Implementation not found in the exact source tree; exit condition unresolved | Unresolved because implementation was not found | Unresolved |

`rtw_hal_stop_thread()` is called at `os_dep/linux/os_intfs.c:2211` and
dispatches the SDIO HAL transmit-thread stop path at
`hal/hal_intf.c:918-922` and `hal/rtl8188e/rtl8188e_hal_init.c:2393-2396`.
That path wakes `SdioXmitSema` and then synchronously calls `kthread_stop()`.
The thread audit does not add a timeout or modify this lifecycle.

The old observation that `ps w` did not show `RTW_CMD_THREAD` is not fully
resolved by source audit. The source creates the command thread with a
`kthread_run()` call at `os_dep/linux/os_intfs.c:2146`, but the exact runtime
`comm` value and whether the thread had already exited at the observation time
are not available from this static tree. Therefore the discrepancy remains
**unresolved** rather than being attributed to a name change.
