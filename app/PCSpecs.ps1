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
.PARAMETER FromFile  For tests: build the notes and summary from a specs JSON file instead of
                   this PC. Implies -NoSave. A display entry may carry "maxHz".

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
  [switch]$NoSave,
  [string]$FromFile = ''
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
function Cim([string]$Class, [string]$Ns = 'root\cimv2', [string[]]$Props) {
  if ($Props) { Get-CimInstance -ClassName $Class -Namespace $Ns -Property $Props -ErrorAction Stop }
  else        { Get-CimInstance -ClassName $Class -Namespace $Ns -ErrorAction Stop }
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

  // Highest refresh rate the display offers at this resolution (in either orientation).
  public static int MaxHz(string device, int w, int h) {
    int best = 0; DEVMODE m = NewMode();
    for (int i = 0; EnumDisplaySettings(device, i, ref m); i++) {
      bool same = (m.dmPelsWidth == w && m.dmPelsHeight == h) || (m.dmPelsWidth == h && m.dmPelsHeight == w);
      if (same && m.dmDisplayFrequency > best) best = m.dmDisplayFrequency;
    }
    return best;
  }
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
  # Only these four: the full class also measures CPU load, which alone takes about a second.
  foreach ($p in @(Cim Win32_Processor 'root\cimv2' 'Name', 'NumberOfCores', 'NumberOfLogicalProcessors', 'MaxClockSpeed')) {
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
$hzMax    = @{}   # output name -> highest refresh rate on offer; used only for the notes

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
    $hzMax[($dd.DeviceName -replace '^\\\\\.\\', '')] = [PCSpecsDisplay]::MaxHz($dd.DeviceName, $dm.dmPelsWidth, $dm.dmPelsHeight)
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
  # Same data and wording as Get-PhysicalDisk and Get-Partition, read straight from the classes
  # behind them. Loading the Storage module for those two cmdlets took over a second.
  $st = 'root\Microsoft\Windows\Storage'
  $mediaNames  = @{ 0 = 'Unspecified'; 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
  $busNames    = @{ 0 = 'Unknown'; 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'; 6 = 'Fibre Channel'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'
                    10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 14 = 'Virtual'; 15 = 'File Backed Virtual'; 16 = 'Spaces'; 17 = 'NVMe'; 18 = 'SCM'; 19 = 'UFS' }
  $healthNames = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy'; 5 = 'Unknown' }
  $parts = @()
  try { $parts = @(Cim MSFT_Partition $st | Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' }) } catch { }
  foreach ($d in @(Cim MSFT_PhysicalDisk $st | Sort-Object { [int]$_.DeviceId })) {
    $id = [string]$d.DeviceId
    $media = $mediaNames[[int]$d.MediaType];   if (-not $media)  { $media = 'Unspecified' }
    $health = $healthNames[[int]$d.HealthStatus]; if (-not $health) { $health = 'Unknown' }
    $bus = ''; if ($null -ne $d.BusType) { $bus = $busNames[[int]$d.BusType]; if (-not $bus) { $bus = 'Unknown' } }
    [pscustomobject][ordered]@{
      disk    = [int]$d.DeviceId
      model   = ([string]$d.FriendlyName).Trim()
      sizeGB  = (ToGB $d.Size)
      media   = $media
      bus     = $bus
      health  = $health
      letters = ((@($parts | Where-Object { [string]$_.DiskNumber -eq $id }) | ForEach-Object { "$($_.DriveLetter):" }) -join ' ')
    }
  }
})

# Same list as "Get-NetAdapter -Physical", read from the class behind it with the option that
# cmdlet passes. Loading the NetAdapter module for one cmdlet took most of a second.
$netRaw = @()
try {
  $opt = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions
  $opt.SetCustomOption('Physical', $true, $false)
  $session = [Microsoft.Management.Infrastructure.CimSession]::Create([NullString]::Value)
  try { $netRaw = @($session.EnumerateInstances('root\StandardCimv2', 'MSFT_NetAdapter', $opt) | Sort-Object Name) }
  finally { $session.Dispose() }
} catch { }
function Get-NetStatus($n) {
  # The wording of Get-NetAdapter's Status column.
  switch ([int]$n.InterfaceOperationalStatus) {
    1 { return 'Up' } 3 { return 'Testing' } 4 { return 'Unknown' } 5 { return 'Dormant' } 6 { return 'Not Present' } 7 { return 'Lower Layer Down' }
  }
  if ([int]$n.InterfaceOperationalStatus -ne 2) { return '' }
  if ([int]$n.InterfaceAdminStatus -eq 2) { return 'Disabled' }
  $why = @()
  if ($n.OperationalStatusDownDefaultPortNotAuthenticated) { $why += 'Not Authenticated' }
  if ($n.OperationalStatusDownMediaDisconnected)           { $why += 'Disconnected' }
  if ($n.OperationalStatusDownLowPowerState)               { $why += 'Low Power State' }
  $why -join ', '
}
function Get-LinkSpeed($n) {
  # The wording of Get-NetAdapter's LinkSpeed column: "2.5 Gbps", "100 Mbps".
  [decimal]$v = 0; if ($null -ne $n.TransmitLinkSpeed) { $v = $n.TransmitLinkSpeed }
  $units = '', 'K', 'M', 'G', 'T'; $i = 0
  while ($v -ge 1000 -and $i -lt 4) { $v /= 1000; $i++ }
  "$([math]::Round($v, 1)) $($units[$i])bps"
}
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
      [pscustomobject][ordered]@{ name = $n.Name; status = (Get-NetStatus $n); linkSpeed = (Get-LinkSpeed $n) }
    })
  }
}

if ($FromFile) {
  # Tests only: swap in the specs from a file, then build notes and summary exactly as usual.
  $t = [IO.File]::ReadAllText($FromFile) | ConvertFrom-Json
  $os = $t.spec.os; $system = $t.spec.system; $memory = $t.spec.memory; $live = $t.live
  $cpu = @($t.spec.cpu); $gpu = @($t.spec.gpu); $displays = @($t.spec.displays); $monitors = @($t.spec.monitors)
  $disks = @($t.spec.disks); $network = @($t.spec.network); $audio = @($t.spec.audio)
  $hzMax = @{}
  foreach ($d in $displays) { if ($d -and $d.PSObject.Properties['maxHz']) { $hzMax[[string]$d.output] = $d.maxHz } }
  $NoSave = $true
}

# ---- worth knowing: plain-language notes drawn from the data above ----------------------
# level "attention" = act soon, "info" = good to know. The rules are deliberately cautious:
# a note that is wrong is worse than a note that is missing.
$allNotes = @(Section {
  function Note([string]$Level, [string]$Text) { [pscustomobject][ordered]@{ level = $Level; text = $Text } }

  # Disks that report trouble.
  foreach ($d in @($disks)) {
    if (-not $d -or @('Warning', 'Unhealthy') -notcontains [string]$d.health) { continue }
    $where = ''; if ($d.letters) { $where = " (drive $($d.letters))" }
    Note 'attention' "Disk $($d.model)$where reports its health as '$($d.health)'. Back up anything important on it now."
  }

  # Drives that are nearly full. Windows itself turns the bar red below 10% free.
  foreach ($v in @($live.volumes)) {
    if (-not $v -or -not $v.sizeGB -or $v.sizeGB -lt 8) { continue }     # skip tiny system partitions
    $pct = 100 * $v.freeGB / $v.sizeGB
    $msg = "Drive $($v.drive) is $([math]::Round(100 - $pct))% full: $($v.freeGB) GB free of $($v.sizeGB) GB."
    if ($pct -lt 5 -or ($v.drive -eq $env:SystemDrive -and $v.freeGB -lt 15)) {
      Note 'attention' "$msg Windows needs free space to update and run well, so free some up soon."
    } elseif ($pct -lt 10) { Note 'info' $msg }
  }

  # No real graphics driver, or a very old one.
  foreach ($g in @($gpu)) {
    if (-not $g -or -not $g.name) { continue }
    if ($g.name -match 'Basic Display|Basic Render') {
      Note 'attention' 'Windows is using its basic display driver, so no proper graphics driver is installed. Get the driver from the maker of the PC or the graphics card.'
    } elseif ($g.driverDate -and ((Get-Date) - [datetime]$g.driverDate).TotalDays -ge 730) {
      Note 'info' "The graphics driver for $($g.name) is from $(([string]$g.driverDate).Substring(0, 7)). If you have display or game problems, updating it is a good first step."
    }
  }

  # Memory running below the speed it was sold for.
  $mods = @($memory.modules | Where-Object { $_ -and $_.configuredMTs })
  if ($mods.Count -gt 0) {
    $now = [int]($mods | Measure-Object -Property configuredMTs -Minimum).Minimum
    $rated = 0; $part = ''
    foreach ($m in $mods) {
      $r = [int]$m.ratedMTs
      # Many kits carry their speed in the part number: F4-3600C18, CMK32GX5M2B6000C36, F5-6000J3038.
      if ([string]$m.part -match '(?<!\d)(\d{4})[CJ]\d{2}') {
        $fromPart = [int]$Matches[1]
        if ($fromPart -ge 1600 -and $fromPart -le 10000 -and $fromPart -gt $r) { $r = $fromPart }
      }
      if ($r -gt $rated) { $rated = $r; $part = [string]$m.part }
    }
    if ($rated - $now -ge 200) {
      $msg = "Memory is running at $now MT/s, but at least one stick ($part) is rated for $rated. On a desktop this usually means XMP or EXPO (DOCP on some boards) is off in the BIOS."
      if (@($mods | ForEach-Object { [string]$_.part } | Sort-Object -Unique).Count -gt 1) { $msg += ' Mixing different memory kits can also hold the speed down.' }
      Note 'info' $msg
    }
  }
  if ($memory.totalGB -and $memory.totalGB -lt 8) {
    Note 'info' "This PC has $($memory.totalGB) GB of memory, which is tight for Windows today. Closing browser tabs and background apps helps the most."
  }

  # A display set below the refresh rate it can do.
  foreach ($d in @($displays)) {
    if (-not $d -or -not $d.hz) { continue }
    $max = [int]$hzMax[[string]$d.output]
    if ($max - $d.hz -ge 10) {
      Note 'info' "Display $($d.monitor) is set to $($d.hz) Hz but can do $max Hz at this resolution. Change it in Settings > System > Display > Advanced display."
    }
  }

  # A wired connection stuck at 100 Mbps on a faster adapter.
  foreach ($n in @($live.network)) {
    if (-not $n -or $n.status -ne 'Up' -or $n.linkSpeed -ne '100 Mbps') { continue }
    $dev = [string](@($network | Where-Object { $_.name -eq $n.name }) | Select-Object -First 1).device
    if ($dev -match 'Gigabit|GbE|2\.5G|10G' -and $dev -notmatch 'Wi-?Fi|Wireless') {
      Note 'info' "The wired network ($dev) is connected at 100 Mbps although the adapter can go faster. An old or damaged cable, or a slow router port, is the usual cause."
    }
  }

  # A long time without a restart.
  if ($live.uptimeHours -ge 240) {
    Note 'info' "Windows has been running for $([math]::Floor($live.uptimeHours / 24)) days without a restart. Restarting clears up many slowdowns and lets updates finish. Use Restart: Shut down may not count."
  }

  # Windows 10 is out of regular support.
  if ($os.name -like 'Windows 10*' -and $os.name -notmatch 'LTSC|IoT') {
    Note 'info' 'Windows 10 support ended in October 2025. Unless this PC is enrolled in Extended Security Updates, it no longer gets security fixes.'
  }
})
# "attention" first, otherwise in the order above.
$notes = @($allNotes | Where-Object { $_.level -eq 'attention' }) + @($allNotes | Where-Object { $_.level -ne 'attention' })

$spec = [ordered]@{
  os = $os; system = $system; cpu = $cpu; memory = $memory; gpu = $gpu
  displays = $displays; monitors = $monitors; disks = $disks; network = $network; audio = $audio
}
$doc = [ordered]@{ schema = $Schema; taken = $ts; notes = $notes; spec = $spec; live = $live }

# ---- text summary --------------------------------------------------------------
function Get-Wrapped([string]$Text, [int]$Width) {
  $line = ''
  foreach ($w in ($Text -split ' ')) {
    if ($line -and ($line.Length + 1 + $w.Length) -gt $Width) { $line; $line = $w }
    elseif ($line) { $line += " $w" } else { $line = $w }
  }
  if ($line) { $line }
}
function Get-Summary {
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add('WORTH KNOWING')
  $shown = @($notes | Where-Object { $_ -and $_.PSObject.Properties['text'] })
  if ($shown.Count -eq 0) {
    $L.Add('  Nothing stands out. Checked: disk space and health, memory speed, display')
    $L.Add('  refresh rate, graphics driver, network link and time since the last restart.')
  }
  foreach ($n in $shown) {
    $mark = '-'; if ($n.level -eq 'attention') { $mark = '!' }
    $first = $true
    foreach ($piece in @(Get-Wrapped $n.text 78)) {
      if ($first) { $L.Add("  $mark $piece"); $first = $false } else { $L.Add("    $piece") }
    }
  }
  $L.Add('')
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
    $mem = ''; if ($g.vramGB) { $mem = " - $($g.vramGB) GB" }
    $L.Add("GPU      $($g.name)$mem, driver $ver, $($g.driverDate)")
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
  foreach ($k in @($spec.Keys) + 'live' + 'notes') {
    $v = if ($k -eq 'live') { $live } elseif ($k -eq 'notes') { $notes } else { $spec[$k] }
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
