<#
.SYNOPSIS
  Snapshot installed apps and log what changed since the last run.

.DESCRIPTION
  Reads the Windows uninstall registry (what Settings > Installed apps shows)
  plus Microsoft Store apps. Read-only on the system; writes only to -LogDir.
  Snapshots are saved only when something changed.

  Outputs (under -LogDir):
    apps\latest.json            current app list   {schema, taken, count, apps[]}
    apps\changes.jsonl          one event per line {ts, event, name, source, publisher, version | from,to}
    apps\snapshots\<stamp>.json full list at each change
    runs.jsonl                  one line per run   {ts, tool, status, ...}

.PARAMETER LogDir   Output folder. Default: the logs folder next to Start.bat.
.PARAMETER All      Include hidden components and sub-installers.
.PARAMETER NoStore  Skip Microsoft Store apps.
.PARAMETER History  Do not snapshot; print logged changes from the last N days.
.PARAMETER Json     Print JSON to stdout instead of text (for scripts and AI assistants).

.EXAMPLE
  .\AppLog.ps1
.EXAMPLE
  .\AppLog.ps1 -History 30 -Json
#>
[CmdletBinding()]
param(
  [string]$LogDir = '',
  [switch]$All,
  [switch]$NoStore,
  [int]$History = 0,
  [switch]$Json
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
$Schema  = 'applog/1'
$AppDir  = Join-Path $LogDir 'apps'
$SnapDir = Join-Path $AppDir 'snapshots'
$Latest  = Join-Path $AppDir 'latest.json'
$Changes = Join-Path $AppDir 'changes.jsonl'
$Runs    = Join-Path $LogDir 'runs.jsonl'
$Utf8    = New-Object System.Text.UTF8Encoding($false)   # no BOM

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

function Get-InstalledApps {
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $seen = @{}
  $out  = New-Object System.Collections.Generic.List[object]

  foreach ($p in $paths) {
    foreach ($k in @(Get-ItemProperty -Path $p -ErrorAction SilentlyContinue)) {
      if (-not $k.DisplayName) { continue }
      # Same filter Settings > Installed apps uses: hide components and child installers.
      if (-not $All -and ($k.SystemComponent -eq 1 -or $k.ParentKeyName)) { continue }
      $rec = [pscustomobject][ordered]@{
        name        = ([string]$k.DisplayName).Trim()
        version     = ([string]$k.DisplayVersion).Trim()
        publisher   = ([string]$k.Publisher).Trim()
        installDate = [string]$k.InstallDate
        source      = 'win32'
      }
      $id = "$($rec.name)|$($rec.version)|$($rec.publisher)"
      if ($seen.ContainsKey($id)) { continue }   # listed under 64-bit, 32-bit and per-user keys
      $seen[$id] = 1
      $out.Add($rec)
    }
  }

  if (-not $NoStore) {
    try {
      $pkgs = Get-AppxPackage -ErrorAction Stop |
        Where-Object { -not $_.IsFramework -and -not $_.IsResourcePackage -and "$($_.SignatureKind)" -eq 'Store' }
      foreach ($a in $pkgs) {
        $id = "store|$($a.Name)|$($a.Version)"
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = 1
        $out.Add([pscustomobject][ordered]@{
          name        = [string]$a.Name
          version     = [string]$a.Version
          publisher   = ([string]$a.Publisher -replace '^CN=([^,]+).*$', '$1')
          installDate = ''
          source      = 'store'
        })
      }
    } catch { }   # Store cmdlets unavailable (e.g. Windows Server): skip quietly
  }

  $out | Sort-Object source, name
}

function Join-Versions($set) { (@($set) | Where-Object { $_ }) -join ', ' }

function Group-Apps($apps) {
  $d = @{}
  foreach ($a in $apps) {
    $k = "$($a.source)|$($a.name)"
    if (-not $d.ContainsKey($k)) {
      $d[$k] = @{
        name = $a.name; source = $a.source; publisher = $a.publisher
        versions = New-Object 'System.Collections.Generic.SortedSet[string]'
      }
    }
    [void]$d[$k].versions.Add([string]$a.version)
  }
  $d
}

function Compare-Apps($old, $new, [string]$ts) {
  $o = Group-Apps $old
  $n = Group-Apps $new
  $ev = New-Object System.Collections.Generic.List[object]
  foreach ($k in @($n.Keys | Sort-Object)) {
    $x = $n[$k]
    if (-not $o.ContainsKey($k)) {
      $ev.Add([pscustomobject][ordered]@{ ts = $ts; event = 'added'; name = $x.name; source = $x.source; publisher = $x.publisher; version = (Join-Versions $x.versions) })
    } else {
      $from = Join-Versions $o[$k].versions
      $to   = Join-Versions $x.versions
      if ($from -cne $to) {
        $ev.Add([pscustomobject][ordered]@{ ts = $ts; event = 'updated'; name = $x.name; source = $x.source; publisher = $x.publisher; from = $from; to = $to })
      }
    }
  }
  foreach ($k in @($o.Keys | Sort-Object)) {
    if (-not $n.ContainsKey($k)) {
      $x = $o[$k]
      $ev.Add([pscustomobject][ordered]@{ ts = $ts; event = 'removed'; name = $x.name; source = $x.source; publisher = $x.publisher; version = (Join-Versions $x.versions) })
    }
  }
  $ev
}

function Read-Previous {
  # latest.json first; fall back to newest readable snapshot if it is damaged.
  $files = @()
  if (Test-Path -LiteralPath $Latest) { $files += $Latest }
  $files += @(Get-ChildItem -LiteralPath $SnapDir -Filter '*.json' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | ForEach-Object { $_.FullName })
  foreach ($f in $files) {
    try {
      $j = [IO.File]::ReadAllText($f, $Utf8) | ConvertFrom-Json
      if ($null -ne $j.apps) { return , @($j.apps) }
    } catch { }
  }
  $null
}

# ---- History mode: read the log, change nothing -------------------------------
if ($History -gt 0) {
  $cut = (Get-Date).AddDays(-$History)
  $rows = @()
  if (Test-Path -LiteralPath $Changes) {
    $rows = @(Get-Content -LiteralPath $Changes -Encoding UTF8 |
      Where-Object { $_.Trim() } |
      ForEach-Object { $_ | ConvertFrom-Json } |
      Where-Object { $_.event -ne 'baseline' -and [datetime]$_.ts -ge $cut })
  }
  if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 5 }
  elseif ($rows.Count -eq 0) { "No app changes in the last $History days." }
  else { $rows | Format-Table ts, event, name, version, from, to -AutoSize | Out-String -Width 220 }
  exit 0
}

# ---- Snapshot mode -------------------------------------------------------------
$ts     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$result = [ordered]@{ schema = $Schema; ts = $ts; status = 'ok'; apps = 0; changes = @(); logDir = $LogDir; error = $null }

try {
  New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null
  $apps = @(Get-InstalledApps)
  $prev = Read-Previous
  $result.apps = $apps.Count

  if ($null -eq $prev) {
    $events = @([pscustomobject][ordered]@{ ts = $ts; event = 'baseline'; count = $apps.Count })
  } else {
    $events = @(Compare-Apps $prev $apps $ts)
  }
  $result.changes = $events

  if ($events.Count -gt 0) {
    Add-JsonLines $Changes $events   # log first: a later failure duplicates an entry, never loses one
    $doc = [ordered]@{ schema = $Schema; taken = $ts; count = $apps.Count; apps = $apps } | ConvertTo-Json -Depth 4 -Compress
    Write-Atomic (Join-Path $SnapDir "$stamp.json") $doc
    Write-Atomic $Latest $doc
  }
} catch {
  $result.status = 'error'
  $result.error  = $_.Exception.Message
}

try {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  Add-JsonLines $Runs @([pscustomobject][ordered]@{
    ts = $ts; tool = 'applog'; status = $result.status; apps = $result.apps
    changes = @($result.changes).Count; error = $result.error
  })
} catch { }

if ($Json) {
  [pscustomobject]$result | ConvertTo-Json -Depth 5
} elseif ($result.status -eq 'error') {
  Write-Host "ERROR: $($result.error)" -ForegroundColor Red
} else {
  $ev = @($result.changes)
  if ($ev.Count -eq 0)                  { "No changes. $($result.apps) apps." }
  elseif ($ev[0].event -eq 'baseline')  { "Baseline saved: $($result.apps) apps. Future runs log what changed." }
  else {
    "$($ev.Count) change(s). $($result.apps) apps."
    foreach ($e in $ev) {
      switch ($e.event) {
        'added'   { "  + $($e.name) $($e.version)" }
        'removed' { "  - $($e.name) $($e.version)" }
        'updated' { "  ~ $($e.name): $($e.from) -> $($e.to)" }
      }
    }
  }
  "Log: $AppDir"
}

if ($result.status -eq 'error') { exit 1 }
