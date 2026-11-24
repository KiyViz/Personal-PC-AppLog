# Personal-PC-AppLog

Two tiny, read-only Windows tools for reviewing and diagnosing your PC:

- **AppLog**: snapshots installed apps and logs what was added, removed or updated since last time.
- **PCSpecs**: full hardware and OS specs in one click, copied to your clipboard. No clicking through Settings > About.

Runs on Windows 10/11 with built-in PowerShell. Nothing to install. No admin rights needed.

## Quick start

1. Download this folder (green **Code** button > **Download ZIP**, then unzip) or clone it anywhere.
2. Double-click **`Start.bat`**. A small window opens with these buttons:

| Button | What it does |
|---|---|
| **My PC** | Your hardware and Windows version in one short list. |
| **My apps** | Everything installed, plus what was added, removed or updated since your last check and over the last 30 days. |
| **Check automatically every Sunday at 10:00** | Tick to turn the weekly check on, untick to turn it off. |
| **Copy to clipboard** | Copies what is on screen, ready to paste into a chat, email or forum post. |
| **Open saved logs** | Opens the folder where results are kept. |

The first app check saves a baseline; later checks show what changed. Everything is saved in `logs\` next to the scripts.

Prefer the keyboard? Double-click **`Menu.bat`** for the same tools as a numbered terminal menu.

If Windows shows "Windows protected your PC" the first time, choose **More info > Run anyway**. The scripts are plain text, so you can read them first.

## What you get

**My PC** gives a list like this:

```
OS       Windows 11 Pro 24H2 (build 26100.2314, 64-bit)
CPU      AMD Ryzen 7 7800X3D 8-Core Processor - 8 cores / 16 threads
RAM      32 GB (2x16 GB @ 6000 MT/s, 2 of 4 slots)
GPU      NVIDIA GeForce RTX 4070 - 12 GB, driver 566.14 (32.0.15.6614), 2024-11-08
Board    Micro-Star International Co., Ltd. B650 TOMAHAWK, BIOS 1.90 (2024-08-21)
Display  2560x1440 @ 165 Hz [primary] - DELL S2721DGF on NVIDIA GeForce RTX 4070
Display  1080x1920 @ 60 Hz [portrait] - DELL U2419H on NVIDIA GeForce RTX 4070
Disk     Samsung SSD 990 PRO 2TB - 1863 GB SSD NVMe, Healthy [C:]
Network  Intel(R) Ethernet Controller I226-V
Free     C: 812/1862 GB (44%)
Uptime   5.2 h (boot 2024-11-23T09:01:12), RAM free 21.4 GB
```

**My apps** gives one page like this:

```
214 apps installed. Checked just now.

NEW SINCE YOUR LAST CHECK
  Added    Blender 4.3.0
  Updated  Google Chrome: 131.0.6778.86 -> 131.0.6778.109
  Removed  Old Game Launcher 2.1

EARLIER IN THE LAST 30 DAYS
  Nov 12  Updated  7-Zip: 24.07 -> 24.08

ALL INSTALLED APPS (171)
  7-Zip                    24.08
  Blender                  4.3.0
  Google Chrome            131.0.6778.109
  ...
```

## Outputs

```
logs\
  runs.jsonl                   one line per run (ok / error)
  apps\
    latest.json                current app list
    changes.jsonl              added / removed / updated, one event per line
    snapshots\<date>.json      full list at each change
  specs\
    latest.json                full specs ("spec" = stable, "live" = uptime, free space...)
    latest.txt                 plain-text summary
    changes.jsonl              field-level spec changes (e.g. GPU driver updated)
    history\<date>.json        full specs at each change
```

JSON, UTF-8, no BOM. Snapshots are written only when something changed, so the folder stays small.

## Command line

`Start.bat` and `Menu.bat` only run the scripts for you. You can also run them directly from Windows PowerShell:

```powershell
.\AppLog.ps1                    # snapshot + show changes
.\AppLog.ps1 -History 30        # changes in the last 30 days (writes nothing)
.\AppLog.ps1 -All               # include hidden components (runtimes, sub-installers)
.\AppLog.ps1 -NoStore           # skip Microsoft Store apps
.\PCSpecs.ps1 -Copy             # summary + copy to clipboard
.\PCSpecs.ps1 -NoSave           # print only, write nothing
.\Schedule.ps1 -Every Daily -At 09:30
.\Schedule.ps1 -Remove
```

AppLog and PCSpecs also take `-Json` (machine-readable output) and `-LogDir <path>` (save logs somewhere else).
Run `Get-Help .\AppLog.ps1 -Full` for details.

If PowerShell says running scripts is disabled, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\PCSpecs.ps1
```

## Using it with an AI assistant

See [AGENTS.md](AGENTS.md). Short version: run `.\PCSpecs.ps1 -Json -NoSave` and `.\AppLog.ps1 -History 30 -Json`, then paste the output (or let your agent run them).

## Privacy

- Read-only. AppLog and PCSpecs never change system settings or apps; they write only to `logs\`.
- The only system change is optional: the weekly-check tick box (`Schedule.ps1`) adds one Task Scheduler task, and unticking it removes it.
- Nothing is sent anywhere. The scripts make no network connections.
- PCSpecs collects no serial numbers, MAC addresses, computer name or user name.
- Your app list is personal. `logs\` is in `.gitignore`. Review before you post it anywhere.

## Uninstall

Double-click `Start.bat`, untick the weekly check if you turned it on, then delete the folder.

## Tests

`tests\Smoke.ps1` runs both tools into a temporary folder and checks the output contract (exit codes, JSON, no BOM, no false changes), then opens the window off-screen and presses each button. It runs on every push.

## License

[MIT](LICENSE)
