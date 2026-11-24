<#
.SYNOPSIS
  Smoke test: run AppLog and PCSpecs into a temp folder and check the output contract.

.DESCRIPTION
  Uses Windows PowerShell 5.1 (powershell.exe) no matter which shell starts it.
  Writes only to a temp folder, which it deletes afterwards. Exit code = number of failures.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Smoke.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ('applog-smoke-' + [guid]::NewGuid().ToString('N'))
$script:fail = 0

function Check([string]$Name, $Ok) {
  if ($Ok) { "ok    $Name" } else { "FAIL  $Name"; $script:fail++ }
}
function Run([string]$Script, [string[]]$A) {
  $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $Script) @A
  $r = [pscustomobject]@{ code = $LASTEXITCODE; text = (@($out) -join "`n"); json = $null }
  try { $r.json = $r.text | ConvertFrom-Json } catch { }
  $r
}

try {
  # ---- source files ----
  foreach ($f in @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -in '.ps1', '.bat' })) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    Check "$($f.Name) is plain ASCII" (-not ($bytes | Where-Object { $_ -gt 127 } | Select-Object -First 1))
  }

  # ---- PCSpecs ----
  $r = Run 'PCSpecs.ps1' @('-Json', '-NoSave', '-LogDir', $tmp)
  Check 'PCSpecs -Json -NoSave exits 0'          ($r.code -eq 0)
  Check 'PCSpecs -Json -NoSave is valid JSON'    ($r.json -and $r.json.schema -eq 'pcspecs/1')
  Check 'PCSpecs -NoSave writes nothing'         (-not (Test-Path -LiteralPath $tmp))
  foreach ($k in 'os', 'system', 'cpu', 'memory', 'gpu', 'displays', 'monitors', 'disks', 'network', 'audio') {
    Check "PCSpecs spec has '$k'"                ($r.json -and $r.json.spec.PSObject.Properties[$k])
  }

  $r = Run 'PCSpecs.ps1' @('-NoSave', '-LogDir', $tmp)
  Check 'PCSpecs text mode exits 0'              ($r.code -eq 0)
  Check 'PCSpecs text mode prints a summary'     ($r.text -match '(?m)^OS\s+\S')

  $r = Run 'PCSpecs.ps1' @('-Json', '-LogDir', $tmp)
  Check 'PCSpecs first save is a baseline'       ($r.code -eq 0 -and @($r.json.changes).Count -eq 1 -and $r.json.changes[0].event -eq 'baseline')
  $r = Run 'PCSpecs.ps1' @('-Json', '-LogDir', $tmp)
  Check 'PCSpecs second save has no false changes' ($r.code -eq 0 -and @($r.json.changes).Count -eq 0)

  # ---- AppLog ----
  $r = Run 'AppLog.ps1' @('-Json', '-LogDir', $tmp)
  Check 'AppLog first run is a baseline'         ($r.code -eq 0 -and $r.json.status -eq 'ok' -and @($r.json.changes).Count -eq 1 -and $r.json.changes[0].event -eq 'baseline')
  Check 'AppLog finds apps'                      ($r.json -and $r.json.apps -gt 0)
  $r = Run 'AppLog.ps1' @('-Json', '-LogDir', $tmp)
  Check 'AppLog second run has no changes'       ($r.code -eq 0 -and @($r.json.changes).Count -eq 0)
  $r = Run 'AppLog.ps1' @('-LogDir', $tmp)
  Check 'AppLog text mode says no changes'       ($r.code -eq 0 -and $r.text -match 'No changes')

  # Change detection: edit the saved list, then expect added + updated + removed.
  $latest = Join-Path $tmp 'apps\latest.json'
  $doc    = [IO.File]::ReadAllText($latest) | ConvertFrom-Json
  # Pick apps listed once, so a second copy of the same name cannot blur the result.
  $uniq   = @($doc.apps | Group-Object { "$($_.source)|$($_.name)" } | Where-Object { $_.Count -eq 1 } | ForEach-Object { $_.Group[0] })
  $gone   = $uniq[0]
  $uniq[1].version = '0.0.0-smoke'
  $list   = New-Object System.Collections.ArrayList
  foreach ($a in @($doc.apps)) { if (-not [object]::ReferenceEquals($a, $gone)) { [void]$list.Add($a) } }
  [void]$list.Add([pscustomobject]@{ name = 'Smoke Test Removed App'; version = '9.9'; publisher = 'Nobody'; installDate = ''; source = 'win32' })
  $doc.apps = @($list)
  [IO.File]::WriteAllText($latest, ($doc | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
  $r  = Run 'AppLog.ps1' @('-Json', '-LogDir', $tmp)
  $ev = @($r.json.changes | ForEach-Object { $_.event }) -join ','
  Check 'AppLog detects added, updated, removed' ($r.code -eq 0 -and $ev -match 'added' -and $ev -match 'updated' -and $ev -match 'removed')
  Check 'AppLog names the removed app'           (@($r.json.changes | Where-Object { $_.event -eq 'removed' -and $_.name -eq 'Smoke Test Removed App' }).Count -eq 1)

  $r = Run 'AppLog.ps1' @('-History', '30', '-Json', '-LogDir', $tmp)
  Check 'AppLog -History -Json is a JSON array'  ($r.code -eq 0 -and $r.text.TrimStart().StartsWith('[') -and @($r.json).Count -ge 3)
  $r = Run 'AppLog.ps1' @('-History', '30', '-LogDir', $tmp)
  Check 'AppLog -History text mode exits 0'      ($r.code -eq 0 -and $r.text -match 'Smoke Test Removed App')

  # ---- files on disk ----
  $files = @(Get-ChildItem -LiteralPath $tmp -Recurse -File)
  Check 'no .tmp files left behind'              (@($files | Where-Object { $_.Extension -eq '.tmp' }).Count -eq 0)
  foreach ($f in @($files | Where-Object { $_.Extension -in '.json', '.jsonl' })) {
    $rel   = $f.FullName.Substring($tmp.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    Check "$rel has no BOM"                      (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF))
    $ok = $true
    try {
      $text = [IO.File]::ReadAllText($f.FullName)
      if ($f.Extension -eq '.jsonl') { foreach ($line in ($text -split "`n")) { if ($line.Trim()) { [void]($line | ConvertFrom-Json) } } }
      else { [void]($text | ConvertFrom-Json) }
    } catch { $ok = $false }
    Check "$rel parses"                          $ok
  }
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

''
if ($script:fail) { "$($script:fail) check(s) FAILED" } else { 'All checks passed.' }
exit $script:fail
