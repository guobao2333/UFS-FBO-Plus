# Technical details

How FBO+ reaches Xiaomi's File-Based Optimization, what the chain looks like, and what this module
deliberately does *not* do.

> [!NOTE]
> Everything below was verified on a Redmi M332BF (`warsaw`) running HyperOS 3.0.305
> (`OS3.0`, Android 16 / SDK 36). Other models may expose a different surface.

## What FBO is

FBO is a UFS extension defined by JEDEC (JESD220-4, previously `JC-64.1-22-67`). The host tells the
storage device which LBA ranges belong to a file, the device reports how fragmented those ranges are,
and — if needed — physically defragments them.

Xiaomi ships this as **焕新存储** (Storage refresh) in HyperOS. Like JEDEC, this module implements no
defragmentation algorithm: the firmware and the system do the work.

## Call chain

```
WebUI / action.sh
  └─ fbo.sh run
       ├─ setprop persist.sys.fboservice.ctrl false; true   → init starts fbo-installd
       ├─ am broadcast miui.intent.action.transferActiveFboTrigger --es appList "pkg1,pkg2"
       │    └─ com.miui.server.MiuiFboService        (system_server, miui-services.jar)
       │         └─ /system_ext/bin/FboNativeService (init service fbo-installd, uid 0)
       │              └─ f2fs GC → vendor.xiaomi.hardware.fbo IFbo (AIDL HAL)
       └─ logcat polling → per-app result
```

## Components

| Path | Role |
| --- | --- |
| `miui.fbo.service` | Binder service in system_server (`miui.fbo.IFboManager`) that receives the trigger broadcast |
| `/system_ext/bin/FboNativeService` | Walks each app's data dir, computes LBA ranges, drives f2fs GC |
| `/vendor/bin/hw/vendor.xiaomi.hardware.fbo-service` | AIDL HAL in front of the UFS device |
| `persist.sys.fboservice.ctrl` | Property that makes init `start` / `stop` `fbo-installd` |
| `persist.sys.stability.miui_fbo_enable` | User-level feature switch |

## Triggering

`appList` is a comma separated string. The system processes one app per batch step and finishes the
whole list before reporting back:

```sh
am broadcast -a miui.intent.action.transferActiveFboTrigger --es appList "com.kugou.android.lite,com.termux.widget"
```

`ActiveFBO_trigger(String pkg)` (binder) validates that the package belongs to the *calling* uid, so
root cannot call it directly — the broadcast is the only scriptable path.

## Reading results

Everything ends up in logcat, tagged `MiuiFboService` / `FboNativeService`:

```
Receive data from native:pkg:com.kugou.android.lite:F2FS:1882:204
fbo event report data startCount:3,fragment_count:1678,stopReason:[]
sendBroadcast and resultNumber:1678resultPkg[com.kugou.android.lite, com.termux.widget]
```

`F2FS:<before>:<after>` is the per-app fragmentation count before and after the pass.
`fragment_count` is the sum of `before - after`.

> [!IMPORTANT]
> `fbo-installd` is marked `disabled` in its init rc and **exits on its own** after every batch.
> Without the `ctrl` toggle before each run the next trigger silently does nothing.

## Why MIUI Security Center must stay installed

`com.miui.securitycenter` is not part of the processing chain, but the system will not resolve a
package list without it:

| Operation | Result |
| --- | --- |
| `am force-stop` | Fine — FBO still completes |
| `pm disable-user` | Rejected: `Cannot disable miui core packages` |
| `pm suspend` | Does not stick (`suspended=false` again immediately) |
| `pm uninstall --user 0` | Aborts within 1 s, falls back to `PackageNamePlaceholder`, result 0 |

> [!WARNING]
> When the package is missing, suspended or disabled, `fbo.sh` refuses to run and reports the reason
> instead of spending minutes producing a meaningless zero.

## The UFS sysfs path is not used

Xiaomi's out-of-tree patch series (`drivers/ufs/core/ufsfbo.c`, 2022) exposes
`fbo_dev_ctrl/{fbo_support,fbo_prog_state,fbo_operation_ctrl,fbo_exe_threshold,fbo_send_lba,fbo_lba_frag_state}`
under the SCSI device. That series was never merged upstream and the sysfs nodes do not exist on this
kernel — the device implements FBO through f2fs and the HAL instead. A sysfs backend was written and
then removed; it lives in the `v0.1.0` history if a kernel ever exposes those attributes.

## Known issues

- `FboNativeService` has crashed with `SIGABRT` inside a recursive `get_all_file()` (tombstones from
  2026-11-13 / 11-14). A crashed batch reports 0 fragments; re-running usually works.
- Processing time grows with data size (WeChat, 4 GB: ~65 s), not a fixed window.
