# 020 implementation record

Status: IMPLEMENTED on `fix/020-assoc-timer-lock`, pending commit, CI #95, and
runtime validation. The patch was regenerated with `git diff` from an actual
012-019 scratch tree; it was not hand-edited. #94 remains paused.

## 1. Defect and scope

`core/rtw_mlme.c:2259` runs under `pmlmepriv->lock` and synchronously cancels
`assoc_timer`. The callback at `core/rtw_mlme.c:2991` takes the same lock.
The callback can therefore wait for the cancelling CPU while the cancelling
CPU waits for the callback: a real same-instance cycle, not a class merge.

The implemented change renames `assoc_timer` to `assoc_timeout.timer`; any missed
direct reference fails compilation. All state and deadlines are protected by
the existing `pmlmepriv->lock`. A process-context `drain_mutex` only serializes
concurrent drain/shutdown callers; callbacks and arm paths never take it.

## 2. Drain contexts, mutex semantics and ordering

`include/osdep_service_linux.h:328-337` confirms the unsafe wrapper:

```c
__inline static int _enter_critical_mutex(_mutex *pmutex, _irqL *pirqL)
{
	int ret = 0;
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 37))
	/* mutex_lock(pmutex); */
	ret = mutex_lock_interruptible(pmutex);
#else
	ret = down_interruptible(pmutex);
#endif
	return ret;
}
```

Its return value is commonly ignored. The implementation therefore uses the existing
non-interruptible `_enter_critical_mutex_lock()` (`mutex_lock()` at
`include/osdep_service_linux.h:341-350`) in both drain and shutdown.

```c
__inline static int _enter_critical_mutex_lock(_mutex *pmutex, _irqL *pirqL)
{
	int ret = 0;
#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 37))
	mutex_lock(pmutex);
#else
	down(pmutex);
#endif
	return ret;
}
```

| Point | Call chain / execution context | Implemented order |
|---|---|---|
| `core/rtw_mlme.c:2259` | `link_timer_hdl()` -> `report_join_res()` -> `rtw_joinbss_event_prehandle()`; timer/RX-softirq-capable | While holding `pmlmepriv->lock`, cancel only with `timer_delete()`/`del_timer()`. Never sleep or synchronize here. |
| `core/rtw_cmd.c:5829` | `rtw_cmd_thread()` -> `createbss_hdl()` -> `rtw_create_ibss_post_hdl()`; process context. Every active `rtw_create_ibss_cmd()` call passes flags `0`, so the IBSS command is queued. | Under lock set DRAINING and non-sync delete; unlock; sync drain; lock; re-arm deferred deadline or become IDLE. |
| `os_dep/linux/os_intfs.c:2819` | Process/work teardown; individual callers are proved in section 6. | Same two-phase drain. It remains restartable for down/up, suspend and reset. |
| `_rtw_free_mlme_priv():462` | Final driver/virtual-adapter destruction; process context after stop paths. | `shutdown` sets SHUTDOWN and synchronously closes the timer but never destroys the mutex. Final `deinit` then destroys `drain_mutex` and clears `initialized`. |

The non-sync delete return value is recorded before releasing the spinlock.
`_cancel_timer_ex()` is never called while `pmlmepriv->lock` is held.
`timer_shutdown_sync()` is limited to final destruction because using it in
`rtw_cancel_all_timer()` would make later down/up or reset unable to re-arm.
For pre-6.2 kernels `_shutdown_timer()` falls back to the existing synchronous
cancel; the SHUTDOWN state still rejects all wrapper-based re-arms.

The callback tree does not call `drain`, `shutdown`, or `deinit`, and the only
`drain_mutex` references are the helpers at `core/rtw_mlme.c:93-181`.
`rtw_join_timeout_handler():3155` takes only `pmlmepriv->lock`; therefore a
drain waiting synchronously for that callback does not create a mutex cycle.

## 3. Corrected state machine and deadline proof

Allowed transitions are `IDLE -> ARMED`, `ARMED -> IDLE`, any live state to
`DRAINING -> IDLE/ARMED`, and any live state to final `SHUTDOWN`.

The corrected `cancel_locked()` does not overwrite DRAINING or SHUTDOWN:

- ARMED: move to IDLE, clear the deadline, non-sync delete the timer.
- DRAINING: leave state/timer ownership unchanged and clear only the deferred
  `pending` arm.
- IDLE or SHUTDOWN: no operation.

This closes the reviewed A/B/C race: while thread A drains, thread B can no
longer change DRAINING to IDLE, so thread C cannot directly arm a timer that
A's later synchronous delete would remove. An arm during DRAINING is stored as
an absolute `pending_deadline`; only the drain owner installs it after the old
callback is fully drained. A cancel during that window clears the pending arm.

Absolute deadline plus lock validation is sufficient without a generation
counter. If an old callback is already waiting for `pmlmepriv->lock` while a
new join re-arms under that lock, the old callback subsequently observes the
new ARMED state and new deadline. It either re-arms the same timer for the
remaining time and returns, or handles timeout only after that current deadline
has expired. During DRAINING it sees a non-ARMED state and returns immediately;
the drain thread later installs the pending deadline. Therefore an old callback
cannot perform disconnect/state mutation for a newer, unexpired join.

The gate invariant is: while DRAINING, only the drain owner may touch the Linux
timer; arm/cancel callers may only update or clear the pending request. While
SHUTDOWN, arm is rejected and cancel is a no-op.

## 4. All 11 arm sites and lock proof

| # | Original point | MLME lock | Evidence and converted form |
|---:|---|---|---|
| 1 | `core/rtw_cmd.c:5810` | Not held | `rtw_cmd_thread:521` invokes callbacks at `672-679` without this lock; use `rtw_assoc_timeout_arm(pmlmepriv, 1)`. |
| 2 | `core/rtw_cmd.c:5812` | Not held | Same `rtw_joinbss_cmd_callback()` command-thread proof; use `arm()`. |
| 3 | `core/rtw_cmd.c:5827` | Not held | `createbss_hdl:13858` calls post-handler at `13915`; all active IBSS producers (`rtw_ioctl_set.c:155`, `rtw_mlme.c:1342,2947`) pass flags `0`, enqueueing to `rtw_cmd_thread`; use `arm()`. |
| 4 | `core/rtw_ioctl_set.c:135` | Held | Every `rtw_do_join()` caller holds it: set BSSID `216->259->262`, set SSID `287->355->358`, connect `394->424->427`, timeout roaming `rtw_mlme.c:3179->3206->3238`, and `_rtw_roaming` either at `3072` inside `3034-3118` or through wrapper `5264-5266`; use `arm_locked()`. |
| 5 | `core/rtw_mlme.c:1483` | Held | `rtw_surveydone_event_callback()` acquires at `1471` and releases at `1561`; use `arm_locked()`. |
| 6 | `core/rtw_mlme.c:1513` | Held | Same `1471-1561` critical section; use `arm_locked()`. |
| 7 | `core/rtw_mlme.c:2433` | Held | `rtw_joinbss_event_prehandle()` acquires at `2347`, releases at `2470`; use `arm_locked()`. |
| 8 | `core/rtw_mlme.c:2451` | Held | Same `2347-2470` critical section; use `arm_locked()`. |
| 9 | `core/rtw_mlme.c:2459` | Held | Same `2347-2470` critical section; use `arm_locked()`. |
| 10 | `core/rtw_mlme_ext.c:11304` | Not held | `rtw_cmd_thread()` executes `join_cmd_hdl:13921`, which calls `start_clnt_join:14104`; neither acquires `pmlmepriv->lock`; use `arm()`. |
| 11 | `core/rtw_rson.c:542` | Not held | `rtw_cmd_thread()` -> `rtw_drvextra_cmd_hdl:5570` -> `RSON_SCAN_WK_CID:5704-5705` -> `rtw_rson_scan_cmd_hdl:509`; no MLME lock in the chain; use `arm()`. This code is build-excluded when `CONFIG_RTW_REPEATER_SON` is absent. |

The field rename `assoc_timer -> assoc_timeout.timer` makes any missed direct
source reference fail compilation. All 11 direct arm references are converted.

## 5. Initialization, destruction and adapter reuse

| Question | Evidence and conclusion |
|---|---|
| Failure before timer init | `_rtw_init_mlme_priv()` can fail before its sole `rtw_init_mlme_timer()` call at `core/rtw_mlme.c:301`. Both SDIO primary (`sdio_intf.c:804`) and virtual (`os_intfs.c:3133`) allocations use `rtw_zvmalloc`, so `initialized` starts at zero and makes deinit a no-op. |
| Primary-adapter init failure | `rtw_sdio_primary_adapter_init()` calls `rtw_init_drv_sw()` at `sdio_intf.c:858` but its failure path frees adapter memory without `rtw_free_drv_sw()`. The common `rtw_init_drv_sw()` failure exit calls idempotent `deinit` at `os_intfs.c:2803`. No driver thread has been started at this stage. |
| Virtual-adapter init failure | `rtw_drv_add_vir_if()` copies the complete primary adapter at `os_intfs.c:3140`, then clears `assoc_timeout.initialized` at `3143` before any failing operation can deinit the copied primary synchronization objects. Its failure path may call deinit again through `rtw_free_drv_sw()`; the flag makes that repeat a no-op. |
| Repeated timer init | Static search finds exactly one call, `_rtw_init_mlme_priv():301`. `rtw_init_mlme_timer():168` warns and returns if the same adapter is initialized twice without deinit. cfg80211 add/delete reuses the initialized adapter and does not call timer init. |
| Cancel before final free | Normal primary removal is `rtw_dev_remove()` -> `rtw_sdio_primary_adapter_deinit()` -> `rtw_dev_unload()` (`rtw_cancel_all_timer`) -> `rtw_free_drv_sw()` -> `_rtw_free_mlme_priv()` (deinit). Virtual removal is `rtw_drv_stop_vir_if()` (threads stopped, then drain at `3257`) -> `rtw_drv_free_vir_if()` -> `rtw_free_drv_sw()` (deinit). |
| Concurrent destruction | `shutdown()` never destroys `drain_mutex`. Destruction occurs only in `deinit`: at failed initialization before threads start, or in `_rtw_free_mlme_priv()` after the primary/virtual stop path has stopped command threads and drained timers. Thus no valid caller can have passed the `initialized` check and be waiting on the mutex when it is destroyed. |
| Double free | `deinit` first checks `initialized`, performs shutdown and mutex destruction, then clears the flag. A sequential repeat is a no-op. Successful primary/virtual callers free the adapter immediately after `rtw_free_drv_sw()`; no reachable concurrent or second final free was found. |
| cfg80211 add/delete reuse | `cfg80211_rtw_add_virtual_intf()` gets a preallocated unregistered adapter (`ioctl_cfg80211.c:4850`) and calls only `rtw_os_ndev_init()`; delete calls `rtw_os_ndev_unregister()` at `4940`. The adapter and assoc timer remain initialized and are reused; `rtw_init_mlme_timer()` is not rerun. C2-C4 loops cover this reuse. A module unload/reload allocates and initializes new adapters. |

Final destruction uses `timer_shutdown_sync()` on Linux 6.18. Restartable
interface stop/reset uses only drain, so the timer can be armed again.

## 6. Every `rtw_cancel_all_timer()` caller and context

| Direct caller | Two-level chain and context proof |
|---|---|
| `rtw_drv_stop_vir_if()` at `os_intfs.c:3257` | `rtw_drv_stop_vir_ifaces()` is called from SDIO probe-failure cleanup and device removal, both driver probe/remove process context after `rtw_stop_drv_threads()`. |
| `rtw_dev_unload()` at `os_intfs.c:4621` | Called by ndo stop under RTNL, normal suspend through the SDIO PM callback, and `rtw_sdio_primary_adapter_deinit()` from device remove. All are sleepable process/PM context. |
| `_rtw_mi_cancel_all_timer()` at `core/rtw_mi.c:702` | `rtw_mi_cancel_all_timer:705-707` is called at `rtw_suspend_common()` `os_intfs.c:4939`, reached from the SDIO PM suspend callback at `sdio_intf.c:1206`; process context. |
| `sreset_stop_adapter()` at `core/rtw_sreset.c:228` | `_rtw_mi_sreset_adapter_hdl:1162-1176` is called from `sreset_reset:296`. Reset is reached either from the dynamic-check command worker (`rtw_cmd_thread` -> `rtw_dynamic_chk_wk_hdl:3268` -> HAL sreset checks) or user ioctl/debugfs; both are process context. It may hold the power mutex, but it is not tasklet/softirq context. |

No direct `rtw_cancel_all_timer()` caller was found in tasklet, hardirq or
timer callback context. The implemented mutex and synchronous drain are therefore
valid for these call chains. Runtime lockdep remains required for indirect
function-pointer paths.

## 7. STATIC-SAFE sample (15/113)

These are safe only in the precise Run #93 build because the code is absent;
they are not runtime proofs for a different configuration.

| Point | Static basis |
|---|---|
| `core/mesh/rtw_mesh_hwmp.c:1602` | `CONFIG_RTW_MESH` absent |
| `core/mesh/rtw_mesh_pathtbl.c:798` | `CONFIG_RTW_MESH` absent |
| `core/mesh/rtw_mesh.c:3117` | `CONFIG_RTW_MESH` absent |
| `core/mesh/rtw_mesh.c:3118` | `CONFIG_RTW_MESH` absent |
| `core/mesh/rtw_mesh.c:3119` | `CONFIG_RTW_MESH` absent |
| `core/rtw_ap.c:3770` | mesh cleanup; `CONFIG_RTW_MESH` absent |
| `core/rtw_ap.c:4246` | `CONFIG_IFACE_NUMBER=2`; software beacon timer disabled |
| `core/rtw_beamforming.c:872` | `CONFIG_BEAMFORMING` absent and symbols absent from Run #93 module |
| `core/rtw_beamforming.c:1489` | same beamforming exclusion |
| `core/rtw_beamforming.c:1564` | same beamforming exclusion |
| `core/rtw_cmd.c:4380` | RTL8188E target is 2.4 GHz; `CONFIG_DFS_MASTER` absent |
| `core/rtw_mlme_ext.c:16620` | Makefile sets `CONFIG_TDLS=n` |
| `core/rtw_mlme_ext.c:16628` | Makefile sets `CONFIG_TDLS=n` |
| `core/rtw_mlme_ext.c:16629` | Makefile sets `CONFIG_TDLS=n` |
| `core/rtw_mlme_ext.c:16630` | Makefile sets `CONFIG_TDLS=n` |

## 8. UNTESTED 48: functional groups and coverage

| Group / points | Targeted test and cancellation points |
|---|---|
| STA join/IBSS/link (9): `rtw_cmd.c:5829`; `rtw_mlme.c:2259`; `rtw_mlme_ext.c:2836,11339,11385,12303,13893,13946,14102` | WPA2 success, wrong-key timeout, ten reconnects, three kills during association, association-time rmmod. Covers join, link and assoc cancellation. |
| Disconnect/roam/security (6): `rtw_mlme_ext.c:2988,3076,9743,6931,7070,7251` | Explicit disconnect, AP loss/reconnect, FT/roam and 802.11w only when enabled. |
| P2P/ROC (20): `rtw_mlme_ext.c:6211,6235,6242,6274,6459,6524`; `rtw_p2p.c:2937,3381,5345-5349,5353`; `ioctl_cfg80211.c:6861,6971`; `ioctl_linux.c:4781,4791,4960,5459` | P2P discovery/listen/cancel, GO negotiation/invite/provision, remain-on-channel/cancel and teardown. Otherwise document outside release scope. |
| AP BA/reorder (2): `rtw_recv.c:3318,3452` | Sustained bidirectional AP traffic, client reconnect, stop AP and rmmod during traffic. |
| Power/IPS/SDIO (5): `os_intfs.c:2775`; `hal/rtl8188e/sdio/sdio_ops.c:1496`; generic helper rows `407,409,436` | Idle-to-IPS, traffic wake, repeated down/up, suspend/resume and unload in IPS. Helper rows are covered through concrete callers. |
| RM/PHYDM (2): `rtw_rm_fsm.c:137`; `hal/phydm/phydm_interface.c:737` | Radio-measurement request/deinit and PHYDM/antenna-diversity teardown, if enabled. |
| BT/MP (3): `rtw_bt_mp.c:65,479`; `rtw_mp.c:671` | MP/BT timeout and deinit, or explicitly document unsupported feature. |
| Deferred work (1): `os_dep/linux/rhashtable.c:817` | Force deferred rehash then teardown; otherwise it remains untested because callback lock ownership is unresolved. |

Audit total remains 181: COVERED-CLEAN 20, UNTESTED 48, STATIC-SAFE 113.
The audit traces caller locks upward two levels and callback locks downward two
levels; unresolved function-pointer/macro/object-identity paths remain
UNTESTED. Lockdep on an actually executed path is the acceptance authority.

## 9. Revised L3 functional acceptance

Every step records elapsed time, `debug_locks`, D-state tasks and only new
dmesg. Any timeout test must prove both that timeout/recovery occurred and that
a later valid association still succeeds.

| Test | PASS criterion |
|---|---|
| Wrong WPA2 password | Join fails within the driver's expected timeout; record actual elapsed time, `iw dev wlan0 link` is not connected, logs show the join/timeout path completed, and the state no longer remains UNDER_LINKING. Replacing only the password with the correct value then connects. |
| Missing AP/SSID | A nonexistent SSID completes scan/join timeout within a bounded measured interval, returns to an idle/retry-capable state, and a subsequent valid SSID connects. |
| Fast reconnect | 30 `reassociate` or disconnect/reconnect rounds complete; no lost timeout, D-state task or lockdep disable. |
| Association cancellation | Kill `wpa_supplicant` during association three times; run association-time `rmmod rtl8189es` three times. Each command stays under the 25-second driver-command limit and reload recovers. |
| Connected interface lifecycle | Five wlan0 down/up rounds while associated, reconnecting each round. |
| Adapter-pool reuse | Repeat C2-C4 add/delete sequence ten rounds. This covers cfg80211 reuse of the same initialized adapter/timer, not timer reinitialization. |
| AP regression | Client disconnect/reconnect, bidirectional transfer with transfer-time rmmod, and five AP start/stop rounds all pass. |

P2P/ROC remains outside 020. If it is removed, that must be a separate 021
after 020 validation. `CONFIG_DEBUG_OBJECTS_TIMERS` is not added by 020; #95
keeps the approved `wifi_compat_v3` lockdep profile unchanged.

Before flashing #95, run the wrong-password and missing-SSID cases on #93 with
the same 2.4 GHz AP and record elapsed recovery time. Repeat unchanged on #95;
both must recover in the same order of magnitude and permit a subsequent valid
association. The remaining L3 cases require #95 and are not claimed by this
static implementation record.
