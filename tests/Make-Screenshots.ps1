<#
.SYNOPSIS
  Regenerate the README screenshots (docs\screenshots\*.png) with made-up sample data.

.DESCRIPTION
  Copies the real window (app\Launcher.ps1) into a temp folder next to two stand-in tools that
  print fictional specs and a fictional app list, then lets tests\LauncherHook.ps1 press the
  buttons and take the pictures. Nothing from this PC's real hardware or app list is shown.

  The window appears on screen for a few seconds while the pictures are taken.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Make-Screenshots.ps1
#>
$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ps    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$out   = Join-Path $root 'docs\screenshots'
$demo  = Join-Path ([IO.Path]::GetTempPath()) ('applog-demo-' + [guid]::NewGuid().ToString('N'))
$utf8  = New-Object System.Text.UTF8Encoding($false)
$now   = Get-Date
function Stamp([datetime]$d) { $d.ToString('yyyy-MM-ddTHH:mm:ssK') }

# ---- fictional data ---------------------------------------------------------------
$specs = @"
OS       Windows 11 Home 24H2 (build 26100.2314, 64-bit)
CPU      AMD Ryzen 7 7800X3D 8-Core Processor - 8 cores / 16 threads
RAM      32 GB (2x16 GB @ 6000 MT/s, 2 of 4 slots)
GPU      NVIDIA GeForce RTX 4070 - 12 GB, driver 566.14 (32.0.15.6614), 2024-11-12
Board    Micro-Star International Co., Ltd. B650 TOMAHAWK, BIOS 1.90 (2024-08-21)
Display  2560x1440 @ 165 Hz [primary] - DELL S2721DGF on NVIDIA GeForce RTX 4070
Display  1080x1920 @ 60 Hz [portrait] - DELL U2419H on NVIDIA GeForce RTX 4070
Disk     Samsung SSD 990 PRO 2TB - 1863 GB SSD NVMe, Healthy [C:]
Disk     WDC WD40EZAZ-00SF3B0 - 3726 GB HDD SATA, Healthy [D:]
Network  Intel(R) Ethernet Controller I226-V
Network  Intel(R) Wi-Fi 6E AX211 160MHz
Free     C: 812/1862 GB (44%); D: 2105/3726 GB (56%)
Uptime   5.2 h (boot $($now.AddHours(-5.2).ToString('yyyy-MM-ddTHH:mm:ss'))), RAM free 21.4 GB
"@

$desktop = @'
7-Zip 24.08 (x64)|24.08
Audacity|3.7.0
Blender|4.3.0
Discord|1.0.9172
Dropbox|212.4.5767
Epic Games Launcher|1.3.128.0
GIMP 2.10.38|2.10.38
Google Chrome|131.0.6778.109
HandBrake 1.8.2|1.8.2
LibreOffice 24.8.3.2|24.8.3.2
Microsoft 365 Apps|16.0.18129.20158
Microsoft Edge|131.0.2903.70
Mozilla Firefox (x64 en-US)|133.0
Notepad++ (64-bit x64)|8.7.1
NVIDIA App|11.0.1.163
NVIDIA Graphics Driver 566.14|566.14
OBS Studio|31.0.0
Paint.NET|5.1.1
qBittorrent|5.0.2
Spotify|1.2.51.345
Steam|2.10.91.91
VLC media player|3.0.21
Zoom Workplace (64-bit)|6.2.11
'@
$store = @'
Microsoft.Paint|11.2410.28.0
Microsoft.ScreenSketch|11.2409.25.0
Microsoft.Windows.Photos|2024.11110.4004.0
Microsoft.WindowsCalculator|11.2409.0.0
Microsoft.WindowsNotepad|11.2410.21.0
Microsoft.WindowsTerminal|1.21.3231.0
'@
$apps = @()
foreach ($l in ($desktop -split "`r?`n")) { $p = $l.Split('|'); $apps += [pscustomobject][ordered]@{ name = $p[0]; version = $p[1]; publisher = ''; installDate = ''; source = 'win32' } }
foreach ($l in ($store   -split "`r?`n")) { $p = $l.Split('|'); $apps += [pscustomobject][ordered]@{ name = $p[0]; version = $p[1]; publisher = ''; installDate = ''; source = 'store' } }

$ts = Stamp $now
$newChanges = @(
  [pscustomobject][ordered]@{ ts = $ts; event = 'added';   name = 'Blender';           source = 'win32'; publisher = 'Blender Foundation'; version = '4.3.0' }
  [pscustomobject][ordered]@{ ts = $ts; event = 'updated'; name = 'Google Chrome';     source = 'win32'; publisher = 'Google LLC'; from = '131.0.6778.86'; to = '131.0.6778.109' }
  [pscustomobject][ordered]@{ ts = $ts; event = 'removed'; name = 'Old Game Launcher'; source = 'win32'; publisher = 'Example Games'; version = '2.1' }
)
$oldChanges = @(
  [pscustomobject][ordered]@{ ts = (Stamp $now.AddDays(-16)); event = 'added';   name = 'OBS Studio'; source = 'win32'; publisher = 'OBS Project'; version = '31.0.0' }
  [pscustomobject][ordered]@{ ts = (Stamp $now.AddDays(-9));  event = 'updated'; name = 'NVIDIA App'; source = 'win32'; publisher = 'NVIDIA Corporation'; from = '11.0.1.150'; to = '11.0.1.163' }
)
$result = [ordered]@{ schema = 'applog/1'; ts = $ts; status = 'ok'; apps = $apps.Count; changes = $newChanges; logDir = 'demo'; error = $null }

try {
  # ---- demo folder: the real window, stand-in tools --------------------------------
  New-Item -ItemType Directory -Force -Path (Join-Path $demo 'app'), (Join-Path $demo 'logs\apps'), (Join-Path $demo 'logs\specs'), $out | Out-Null
  [IO.File]::WriteAllText((Join-Path $demo 'logs\specs\latest.json'), '{"schema":"pcspecs/1","spec":{},"live":{}}', $utf8)
  Copy-Item -LiteralPath (Join-Path $root 'app\Launcher.ps1') -Destination (Join-Path $demo 'app\Launcher.ps1')
  [IO.File]::WriteAllText((Join-Path $demo 'app\specs.txt'),  $specs, $utf8)
  [IO.File]::WriteAllText((Join-Path $demo 'app\result.json'), ([pscustomobject]$result | ConvertTo-Json -Depth 5), $utf8)
  $stub = 'param([string]$LogDir, [switch]$Json, [int]$History) [IO.File]::ReadAllText((Join-Path $PSScriptRoot ''{0}''))'
  [IO.File]::WriteAllText((Join-Path $demo 'app\PCSpecs.ps1'), ($stub -f 'specs.txt'),  $utf8)
  [IO.File]::WriteAllText((Join-Path $demo 'app\AppLog.ps1'),  ($stub -f 'result.json'), $utf8)
  $latest = [ordered]@{ schema = 'applog/1'; taken = $ts; count = $apps.Count; apps = $apps }
  [IO.File]::WriteAllText((Join-Path $demo 'logs\apps\latest.json'), ($latest | ConvertTo-Json -Depth 4 -Compress), $utf8)
  $lines = foreach ($e in @($oldChanges) + @($newChanges)) { $e | ConvertTo-Json -Compress }
  [IO.File]::WriteAllText((Join-Path $demo 'logs\apps\changes.jsonl'), (($lines -join "`n") + "`n"), $utf8)

  # ---- take the pictures -----------------------------------------------------------
  $env:PCAPPLOG_SHOTS = $out
  & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $demo 'app\Launcher.ps1') -TestHook (Join-Path $root 'tests\LauncherHook.ps1') -LogDir (Join-Path $demo 'logs')
  $code = $LASTEXITCODE
} finally {
  $env:PCAPPLOG_SHOTS = $null
  if (Test-Path -LiteralPath $demo) { Remove-Item -LiteralPath $demo -Recurse -Force }
}
"Screenshots are in $out"
exit $code
