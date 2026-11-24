# AGENTS.md: notes for AI assistants

This repo holds read-only Windows diagnostics. `AppLog.ps1` and `PCSpecs.ps1` never modify the system. They write only under `logs\` (or `-LogDir`).

`Schedule.ps1` is the one exception: it adds or removes a Task Scheduler task named `Personal-PC-AppLog`. Ask the user before running it. `Start.bat` (a window, `Launcher.ps1`) and `Menu.bat` (a terminal menu) are for people; agents should call `AppLog.ps1` and `PCSpecs.ps1` directly. After editing a script, run `tests\Smoke.ps1` and keep the scripts plain ASCII.

## Run

Use Windows PowerShell 5.1 (built in). From any shell:

```
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\PCSpecs.ps1 -Json -NoSave
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\AppLog.ps1 -Json
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\AppLog.ps1 -History 30 -Json
```

Exit code `0` means ok, `1` means error (the message is in the `error` field). With `-Json`, stdout is one JSON document.

## Typical questions

| Question | Do this |
|---|---|
| What hardware/OS is this? | `PCSpecs.ps1 -Json -NoSave` and read `spec` |
| Low disk? Long uptime? | `PCSpecs.ps1 -Json -NoSave` and read `live.volumes[].freePct`, `live.uptimeHours` |
| What changed before a problem started? | `AppLog.ps1 -History <days> -Json` plus `logs\specs\changes.jsonl` (driver/BIOS changes) |
| Is app X installed, which version? | `logs\apps\latest.json`, or run `AppLog.ps1 -Json` first |
| Did the scheduled task run? | Last lines of `logs\runs.jsonl` |

## Schemas

`apps/latest.json` (`schema: applog/1`)
```json
{"schema":"applog/1","taken":"2026-11-23T19:30:00-08:00","count":312,
 "apps":[{"name":"Blender","version":"5.2.0","publisher":"Blender Foundation","installDate":"20261101","source":"win32"}]}
```
`source` is `win32` (registry) or `store` (Microsoft Store package name). `installDate` is `yyyyMMdd` when the installer recorded one.

`apps/changes.jsonl`, one object per line:
```json
{"ts":"...","event":"added","name":"...","source":"win32","publisher":"...","version":"1.2"}
{"ts":"...","event":"updated","name":"...","source":"win32","publisher":"...","from":"1.2","to":"1.3"}
{"ts":"...","event":"removed","name":"...","source":"win32","publisher":"...","version":"1.3"}
{"ts":"...","event":"baseline","count":312}
```
Apps with the version in their name (for example `HandBrake 1.8.0`) show up as removed + added, not updated.

`specs/latest.json` (`schema: pcspecs/1`)
- `spec.os` {name, release, build, arch, installed, firmware}
- `spec.system` {maker, model, board, bios, biosDate}
- `spec.cpu[]` {name, cores, threads, maxMHz}
- `spec.memory` {totalGB, slotsUsed, slotsTotal, modules[] {slot, sizeGB, ratedMTs, configuredMTs, maker, part}}
- `spec.gpu[]` {name, vramGB, driver, driverFriendly (NVIDIA public version), driverDate}
- `spec.displays[]` {output, adapter, monitor (EDID name), width, height, hz, orientation, primary, x, y}
- `spec.monitors[]` {name, maker, year, inUse} (`inUse: false` = plugged in but not part of the desktop)
- `spec.disks[]` {disk, model, sizeGB, media, bus, health, letters}
- `spec.network[]` {name, device}
- `spec.audio[]` {name, maker}
- `live` {lastBoot, uptimeHours, ramFreeGB, volumes[] {drive, label, fs, sizeGB, freeGB, freePct}, network[] {name, status, linkSpeed}}

A section that failed to read holds `{"error":"..."}` instead of data. Report it; don't guess.

`specs/changes.jsonl`: `{"ts","event":"changed","field":"gpu[0].driver","from","to"}`. Only `spec` is diffed.

## Hints for diagnosis

- `memory.modules[].configuredMTs` lower than `ratedMTs` usually means XMP/EXPO is off. Many boards report `ratedMTs` equal to the current speed, so also read the XMP rating from `part` (for example `F4-3600C18` = DDR4-3600 CL18).
- `memory.slotsUsed` vs `slotsTotal` tells you about upgrade room.
- `disks[].health` other than `Healthy` is worth flagging right away.
- `displays[].hz` lower than the monitor supports often means a wrong cable or setting.
- Units: GB = 1024^3 bytes. Timestamps are local time with UTC offset.
