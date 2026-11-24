<#
.SYNOPSIS
  PC hardware and OS specs in one shot - no clicking through Settings > About.

.DESCRIPTION
  Collects OS, CPU, RAM (per stick), GPU (real VRAM + driver), board/BIOS,
  displays (resolution, refresh, rotation), monitors, disks, network and audio.
  Read-only on the system. No serial numbers, MAC addresses, computer name or
  user name are collected, so the summary is safe to paste into a chat or forum.

  Outputs (under -LogDir):
    specs\latest.json           {schema, taken, spec{...}, live{...}}
    specs\latest.txt            plain-text summary (same as the console output)
    specs\changes.jsonl         one event per changed field {ts, event, field, from, to}
    specs\history\<stamp>.json  full spec at each change
    runs.jsonl                  one line per run

  "spec" holds stable facts (diffed between runs). "live" holds values that
  change constantly (uptime, free RAM, free disk, link status) and is not diffed.

.PARAMETER LogDir  Output folder. Default: the logs folder next to Start.bat.
.PARAMETER Json    Print JSON to stdout instead of the text summary.
.PARAMETER Copy    Also copy the text summary to the clipboard.
.PARAMETER NoSave  Print only; write nothing to disk.

.EXAMPLE
  .\PCSpecs.ps1 -Copy
.EXAMPLE
  .\PCSpecs.ps1 -Json -NoSave
#>
[CmdletBinding()]
param(
  [string]$LogDir = '',
  [switch]$Json,
  [switch]$Copy,
  [switch]$NoSave
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1, so resolve here.
if (-not $LogDir) {
  $here = $PSScriptRoot; if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
  # Normal layout: this script is in app\ and logs\ sits one level up, next to Start.bat.
  $up = Split-Path -Parent $here
  if ($up -and (Test-Path -LiteralPath (Join-Path $up 'Start.bat'))) { $here = $up }
  $LogDir = Join-Path $here 'logs'
}
$Schema   = 'pcspecs/1'
$SpecDir  = Join-Path $LogDir 'specs'
$HistDir  = Join-Path $SpecDir 'history'
$Latest   = Join-Path $SpecDir 'latest.json'
$Changes  = Join-Path $SpecDir 'changes.jsonl'
$Runs     = Join-Path $LogDir 'runs.jsonl'
$Utf8     = New-Object System.Text.UTF8Encoding($false)
$ts       = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'

# ---- helpers -------------------------------------------------------------------
function Section([scriptblock]$Block) {
  # One failing section never kills the whole report.
  try { & $Block } catch { [pscustomobject]@{ error = $_.Exception.Message } }
}
function Cim([string]$Class, [string]$Ns = 'root\cimv2') {
  Get-CimInstance -ClassName $Class -Namespace $Ns -ErrorAction Stop
}
function ToGB($bytes, [int]$Digits = 0) {
  if ($bytes) { [math]::Round([double]$bytes / 1GB, $Digits) } else { $null }
}
function VolGB($bytes) {
  # Free space: 0 is a real value, and small volumes (e.g. a 50 MB System Reserved) need decimals.
  if ($null -eq $bytes) { return $null }
  $g = [double]$bytes / 1GB
  if ($g -lt 10) { [math]::Round($g, 2) } else { [math]::Round($g) }
}
function ToDate($d) { if ($d) { ([datetime]$d).ToString('yyyy-MM-dd') } else { $null } }
function Write-Atomic([string]$Path, [string]$Text) {
  $tmp = "$Path.tmp"
  [IO.File]::WriteAllText($tmp, $Text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Add-JsonLines([string]$Path, $Objects) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($o in $Objects) { [void]$sb.Append(($o | ConvertTo-Json -Compress -Depth 5)).Append("`n") }
  [IO.File]::AppendAllText($Path, $sb.ToString(), $Utf8)
}
function Join-Key([string]$Prefix, [string]$Name) { if ($Prefix) { "$Prefix.$Name" } else { $Name } }
function ConvertTo-Flat($Obj, [string]$Prefix, [hashtable]$Out) {
  # Flatten nested objects to "gpu[0].driver" = "32.0.15.6156" for field-level diffs.
  if ($null -eq $Obj) { $Out[$Prefix] = ''; return }
  if ($Obj -is [string] -or $Obj -is [ValueType]) { $Out[$Prefix] = [string]$Obj; return }
  if ($Obj -is [System.Collections.IDictionary]) {
    foreach ($k in $Obj.Keys) { ConvertTo-Flat $Obj[$k] (Join-Key $Prefix $k) $Out }
    return
  }
  if ($Obj -is [System.Collections.IEnumerable]) {
    $i = 0
    foreach ($x in $Obj) { ConvertTo-Flat $x ('{0}[{1}]' -f $Prefix, $i) $Out; $i++ }
    return
  }
  foreach ($p in $Obj.PSObject.Properties) { ConvertTo-Flat $p.Value (Join-Key $Prefix $p.Name) $Out }
}

# ---- display enumeration (true per-monitor resolution, refresh, rotation) -------
$DisplayApi = @'
using System;
using System.Runtime.InteropServices;
public static class PCSpecsDisplay {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
    public int dmFields;
    public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency;
    public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
    public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool EnumDisplayDevices(string lpDevice, int iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, int dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

  public static DISPLAY_DEVICE NewDevice() { var d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(d); return d; }
  public static DEVMODE NewMode() { var m = new DEVMODE(); m.dmSize = (short)Marshal.SizeOf(m); return m; }
}
'@

# ---- collect -------------------------------------------------------------------
$osCim = $null
try { $osCim = Cim Win32_OperatingSystem } catch { }

$os = Section {
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  [pscustomobject][ordered]@{
    name      = ($osCim.Caption -replace '^Microsoft\s+', '').Trim()
    release   = [string]$cv.DisplayVersion
    build     = "$($osCim.BuildNumber).$($cv.UBR)"
    arch      = $osCim.OSArchitecture
    installed = (ToDate $osCim.InstallDate)
    firmware  = [string]$env:firmware_type
  }
}

$system = Section {
  $cs = Cim Win32_ComputerSystem
  $bb = @(Cim Win32_BaseBoard)[0]
  $bi = @(Cim Win32_BIOS)[0]
  [pscustomobject][ordered]@{
    maker    = ([string]$cs.Manufacturer).Trim()
    model    = ([string]$cs.Model).Trim()
    board    = ("$($bb.Manufacturer) $($bb.Product)").Trim()
    bios     = ([string]$bi.SMBIOSBIOSVersion).Trim()
    biosDate = (ToDate $bi.ReleaseDate)
  }
}

$cpu = @(Section {
  foreach ($p in @(Cim Win32_Processor)) {
    [pscustomobject][ordered]@{
      name    = ([string]$p.Name).Trim()
      cores   = $p.NumberOfCores
      threads = $p.NumberOfLogicalProcessors
      maxMHz  = $p.MaxClockSpeed
    }
  }
})

$memory = Section {
  $mods  = @(Cim Win32_PhysicalMemory)
  $slots = (@(Cim Win32_PhysicalMemoryArray) | Measure-Object -Property MemoryDevices -Sum).Sum
  [pscustomobject][ordered]@{
    totalGB    = (ToGB (($mods | Measure-Object -Property Capacity -Sum).Sum))
    slotsUsed  = $mods.Count
    slotsTotal = $slots
    modules    = @(foreach ($m in $mods) {
      [pscustomobject][ordered]@{
        slot          = [string]$m.DeviceLocator
        sizeGB        = (ToGB $m.Capacity)
        ratedMTs      = $m.Speed
        configuredMTs = $m.ConfiguredClockSpeed
        maker         = ([string]$m.Manufacturer).Trim()
        part          = ([string]$m.PartNumber).Trim()
      }
    })
  }
}

$gpu = @(Section {
  # Win32_VideoController.AdapterRAM caps at 4 GB; the driver's registry key has the real size.
  $vram = @{}
  $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
  foreach ($key in @(Get-ChildItem -LiteralPath $cls -ErrorAction SilentlyContinue)) {
    if ($key.PSChildName -notmatch '^\d{4}$') { continue }
    $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.DriverDesc) { continue }
    $q = $p.'HardwareInformation.qwMemorySize'
    if ($q -is [byte[]]) { $q = [BitConverter]::ToUInt64($q, 0) }
    if ($q) { $vram[[string]$p.DriverDesc] = [double]$q }
  }
  foreach ($v in @(Cim Win32_VideoController)) {
    if ([string]$v.PNPDeviceID -notlike 'PCI\*') { continue }   # skip virtual/remote adapters
    $drv = [string]$v.DriverVersion
    $friendly = $null
    if ($v.Name -match 'NVIDIA' -and $drv) {
      # 32.0.16.1656 -> 616.56 (NVIDIA's public version number)
      $d = $drv -replace '\.', ''
      if ($d.Length -ge 5) { $t = $d.Substring($d.Length - 5); $friendly = $t.Substring(0, 3) + '.' + $t.Substring(3) }
    }
    $mem = $vram[[string]$v.Name]
    if (-not $mem) { $mem = [double]$v.AdapterRAM }
    [pscustomobject][ordered]@{
      name           = ([string]$v.Name).Trim()
      vramGB         = (ToGB $mem)
      driver         = $drv
      driverFriendly = $friendly
      driverDate     = (ToDate $v.DriverDate)
    }
  }
})

# EDID names keyed like "display#gsm5bc2#5&37e87c47&0&uid33027" so outputs can be matched to monitors.
function Get-MonitorKey([string]$Id) {
  ((($Id -replace '^\\\\\?\\', '') -replace '#\{.*$', '') -replace '_\d+$', '' -replace '\\', '#').ToLowerInvariant()
}
$wmiMon = @()
try { $wmiMon = @(Cim WmiMonitorID 'root\wmi') } catch { $wmiMonErr = $_.Exception.Message }
$decode = { param($a) if ($a) { -join (@($a) | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) } }
$monByKey = @{}
foreach ($m in $wmiMon) { $monByKey[(Get-MonitorKey $m.InstanceName)] = (& $decode $m.UserFriendlyName) }
$monInUse = @{}   # filled by the displays section (hashtable, so the child scope can write to it)

$displays = @(Section {
  if (-not ('PCSpecsDisplay' -as [type])) { Add-Type -TypeDefinition $DisplayApi }
  $orient = @('landscape', 'portrait', 'landscape (flipped)', 'portrait (flipped)')
  for ($i = 0; $i -lt 32; $i++) {
    $dd = [PCSpecsDisplay]::NewDevice()
    # [NullString]::Value: PowerShell would turn $null into "" and the API needs a real NULL.
    if (-not [PCSpecsDisplay]::EnumDisplayDevices([NullString]::Value, $i, [ref]$dd, 0)) { break }
    if (($dd.StateFlags -band 1) -eq 0) { continue }            # not attached to desktop
    $dm = [PCSpecsDisplay]::NewMode()
    if (-not [PCSpecsDisplay]::EnumDisplaySettings($dd.DeviceName, -1, [ref]$dm)) { continue }
    # An output can list several monitors (e.g. a plugged-in but disabled TV); take the active one.
    # Flag 1 = EDD_GET_DEVICE_INTERFACE_NAME, so DeviceID matches WmiMonitorID.InstanceName.
    $monName = $null
    for ($j = 0; $j -lt 8; $j++) {
      $mon = [PCSpecsDisplay]::NewDevice()
      if (-not [PCSpecsDisplay]::EnumDisplayDevices($dd.DeviceName, $j, [ref]$mon, 1)) { break }
      if (($mon.StateFlags -band 1) -eq 0) { continue }         # DISPLAY_DEVICE_ACTIVE
      $key = Get-MonitorKey $mon.DeviceID
      $monInUse[$key] = $true
      $monName = $monByKey[$key]
      if (-not $monName) { $monName = $mon.DeviceString }
      break
    }
    [pscustomobject][ordered]@{
      output      = ($dd.DeviceName -replace '^\\\\\.\\', '')
      adapter     = $dd.DeviceString
      monitor     = $monName
      width       = $dm.dmPelsWidth
      height      = $dm.dmPelsHeight
      hz          = $dm.dmDisplayFrequency
      orientation = $orient[[math]::Max(0, [math]::Min(3, $dm.dmDisplayOrientation))]
      primary     = [bool]($dd.StateFlags -band 4)
      x           = $dm.dmPositionX
      y           = $dm.dmPositionY
    }
  }
})

$monitors = @(Section {
  if ($wmiMonErr) { throw $wmiMonErr }
  foreach ($m in $wmiMon) {
    [pscustomobject][ordered]@{
      name  = (& $decode $m.UserFriendlyName)
      maker = (& $decode $m.ManufacturerName)
      year  = $m.YearOfManufacture
      # false = connected but not part of the desktop; null if the displays section failed.
      inUse = $(if ($displays.Count -and $displays[0].error) { $null } else { [bool]$monInUse[(Get-MonitorKey $m.InstanceName)] })
    }
  }
})

$disks = @(Section {
  $parts = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' })
  foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId })) {
    $id = [string]$d.DeviceId
    [pscustomobject][ordered]@{
      disk    = [int]$d.DeviceId
      model   = ([string]$d.FriendlyName).Trim()
      sizeGB  = (ToGB $d.Size)
      media   = [string]$d.MediaType
      bus     = [string]$d.BusType
      health  = [string]$d.HealthStatus
      letters = ((@($parts | Where-Object { [string]$_.DiskNumber -eq $id }) | ForEach-Object { "$($_.DriveLetter):" }) -join ' ')
    }
  }
})

$netRaw = @()
try { $netRaw = @(Get-NetAdapter -Physical -ErrorAction Stop | Sort-Object Name) } catch { }
$network = @(foreach ($n in $netRaw) {
  [pscustomobject][ordered]@{ name = $n.Name; device = $n.InterfaceDescription }
})

$audio = @(Section {
  foreach ($a in @(Cim Win32_SoundDevice)) {
    [pscustomobject][ordered]@{ name = ([string]$a.Name).Trim(); maker = ([string]$a.Manufacturer).Trim() }
  }
})

$live = Section {
  $boot = $null; $up = $null; $ramFree = $null
  if ($osCim) {
    $boot    = ([datetime]$osCim.LastBootUpTime).ToString('yyyy-MM-ddTHH:mm:ss')
    $up      = [math]::Round(((Get-Date) - [datetime]$osCim.LastBootUpTime).TotalHours, 1)
    $ramFree = [math]::Round([double]$osCim.FreePhysicalMemory * 1KB / 1GB, 1)
  }
  [pscustomobject][ordered]@{
    lastBoot    = $boot
    uptimeHours = $up
    ramFreeGB   = $ramFree
    volumes     = @(foreach ($v in @(Cim Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 })) {
      $pct = $null
      if ($v.Size) { $pct = [math]::Round(100 * [double]$v.FreeSpace / [double]$v.Size) }
      [pscustomobject][ordered]@{
        drive = $v.DeviceID; label = $v.VolumeName; fs = $v.FileSystem
        sizeGB = (VolGB $v.Size); freeGB = (VolGB $v.FreeSpace); freePct = $pct
      }
    })
    network     = @(foreach ($n in $netRaw) {
      [pscustomobject][ordered]@{ name = $n.Name; status = [string]$n.Status; linkSpeed = [string]$n.LinkSpeed }
    })
  }
}

$spec = [ordered]@{
  os = $os; system = $system; cpu = $cpu; memory = $memory; gpu = $gpu
  displays = $displays; monitors = $monitors; disks = $disks; network = $network; audio = $audio
}
$doc = [ordered]@{ schema = $Schema; taken = $ts; spec = $spec; live = $live }

# ---- text summary --------------------------------------------------------------
function Get-Summary {
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("OS       $($os.name) $($os.release) (build $($os.build), $($os.arch))")
  # Custom builds report placeholders ("System Product Name"); the Board line covers those.
  $placeholder = 'System manufacturer|System Product Name|To Be Filled|Default string'
  if ($system.maker -and "$($system.maker) $($system.model)" -notmatch $placeholder) { $L.Add("System   $($system.maker) $($system.model)") }
  foreach ($c in $cpu) { $L.Add("CPU      $($c.name) - $($c.cores) cores / $($c.threads) threads") }
  if ($memory.modules) {
    $sizes = (@($memory.modules) | Group-Object sizeGB | ForEach-Object { "$($_.Count)x$($_.Name) GB" }) -join ' + '
    $speed = (@($memory.modules) | ForEach-Object { $_.configuredMTs } | Sort-Object -Unique) -join '/'
    $L.Add("RAM      $($memory.totalGB) GB ($sizes @ $speed MT/s, $($memory.slotsUsed) of $($memory.slotsTotal) slots)")
  }
  foreach ($g in $gpu) {
    $ver = $g.driver; if ($g.driverFriendly) { $ver = "$($g.driverFriendly) ($($g.driver))" }
    $L.Add("GPU      $($g.name) - $($g.vramGB) GB, driver $ver, $($g.driverDate)")
  }
  $L.Add("Board    $($system.board), BIOS $($system.bios) ($($system.biosDate))")
  foreach ($d in $displays) {
    $tags = @(); if ($d.orientation -ne 'landscape') { $tags += $d.orientation }; if ($d.primary) { $tags += 'primary' }
    $t = ''; if ($tags) { $t = " [" + ($tags -join ', ') + "]" }
    $L.Add("Display  $($d.width)x$($d.height) @ $($d.hz) Hz$t - $($d.monitor) on $($d.adapter)")
  }
  $idle = @($monitors | Where-Object { $_.name -and $_.inUse -eq $false } | ForEach-Object { $_.name })
  if ($idle) { $L.Add("Monitors connected but not in use: " + ($idle -join ', ')) }
  foreach ($d in $disks) {
    $where = ''; if ($d.letters) { $where = " [$($d.letters)]" }
    $L.Add("Disk     $($d.model) - $($d.sizeGB) GB $($d.media) $($d.bus), $($d.health)$where")
  }
  foreach ($n in $network) { $L.Add("Network  $($n.device)") }
  $vols = @($live.volumes | ForEach-Object { "$($_.drive) $($_.freeGB)/$($_.sizeGB) GB ($($_.freePct)%)" })
  if ($vols) { $L.Add("Free     " + ($vols -join '; ')) }
  $L.Add("Uptime   $($live.uptimeHours) h (boot $($live.lastBoot)), RAM free $($live.ramFreeGB) GB")
  foreach ($k in @($spec.Keys) + 'live') {
    $v = if ($k -eq 'live') { $live } else { $spec[$k] }
    foreach ($x in @($v)) { if ($x -and $x.PSObject.Properties['error']) { $L.Add("Error    ${k}: $($x.error)") } }
  }
  $L -join "`r`n"
}
$summary = Get-Summary

# ---- save + diff ---------------------------------------------------------------
$events = @()
$status = 'ok'; $err = $null
if (-not $NoSave) {
  try {
    New-Item -ItemType Directory -Force -Path $HistDir | Out-Null
    $prev = $null
    if (Test-Path -LiteralPath $Latest) {
      try { $prev = ([IO.File]::ReadAllText($Latest, $Utf8) | ConvertFrom-Json).spec } catch { }
    }
    $docJson = $doc | ConvertTo-Json -Depth 6 -Compress
    if ($null -eq $prev) {
      $events = @([pscustomobject][ordered]@{ ts = $ts; event = 'baseline' })
    } else {
      $a = @{}; $b = @{}
      ConvertTo-Flat $prev '' $a
      # Round-trip current spec through JSON so both sides have identical types.
      ConvertTo-Flat (($spec | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json) '' $b
      $events = @(foreach ($k in @(@($a.Keys) + @($b.Keys) | Sort-Object -Unique)) {
        if ("$($a[$k])" -cne "$($b[$k])") {
          [pscustomobject][ordered]@{ ts = $ts; event = 'changed'; field = $k; from = $a[$k]; to = $b[$k] }
        }
      })
    }
    if ($events.Count -gt 0) {
      Add-JsonLines $Changes $events
      Write-Atomic (Join-Path $HistDir "$stamp.json") $docJson
    }
    Write-Atomic $Latest $docJson
    Write-Atomic (Join-Path $SpecDir 'latest.txt') $summary
  } catch { $status = 'error'; $err = $_.Exception.Message }
  try {
    Add-JsonLines $Runs @([pscustomobject][ordered]@{ ts = $ts; tool = 'pcspecs'; status = $status; changes = $events.Count; error = $err })
  } catch { }
}

# ---- output --------------------------------------------------------------------
if ($Copy) { try { Set-Clipboard -Value $summary } catch { } }

if ($Json) {
  $doc['changes'] = $events
  $doc['status']  = $status
  $doc['error']   = $err
  [pscustomobject]$doc | ConvertTo-Json -Depth 6
} else {
  $summary
  ''
  $real = @($events | Where-Object { $_.event -eq 'changed' })
  if ($real.Count -gt 0) {
    "$($real.Count) spec change(s) since last run:"
    foreach ($e in $real) { "  ~ $($e.field): $($e.from) -> $($e.to)" }
  }
  if (@($events | Where-Object { $_.event -eq 'baseline' }).Count) { 'Baseline saved. Future runs list spec changes (drivers, BIOS, hardware).' }
  if ($status -eq 'error') { Write-Host "ERROR saving: $err" -ForegroundColor Red }
  elseif (-not $NoSave)    { "Saved: $SpecDir" }
  if ($Copy) { 'Copied to clipboard.' }
}

if ($status -eq 'error') { exit 1 }
