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
  $out = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root (Join-Path 'app' $Script)) @A
  $r = [pscustomobject]@{ code = $LASTEXITCODE; text = (@($out) -join "`n"); json = $null }
  try { $r.json = $r.text | ConvertFrom-Json } catch { }
  $r
}

try {
  # ---- source files ----
  $src = @(Get-ChildItem -LiteralPath $root -File) + @(Get-ChildItem -LiteralPath (Join-Path $root 'app'), (Join-Path $root 'tests') -File)
  foreach ($f in @($src | Where-Object { $_.Extension -in '.ps1', '.bat' })) {
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

  # ---- Worth knowing: every rule, on made-up PCs (tests\fixtures) ----
  $r = Run 'PCSpecs.ps1' @('-Json', '-NoSave', '-LogDir', $tmp)
  Check 'PCSpecs JSON has a notes list'          ($r.json -and $r.json.PSObject.Properties['notes'])
  $fx = Join-Path $root 'tests\fixtures'
  $runsBefore = @(Get-Content -LiteralPath (Join-Path $tmp 'runs.jsonl')).Count
  $r = Run 'PCSpecs.ps1' @('-Json', '-FromFile', (Join-Path $fx 'trouble.json'), '-LogDir', $tmp)
  $notes = @($r.json.notes)
  Check 'trouble PC: exits 0 and saves nothing'  ($r.code -eq 0 -and @(Get-Content -LiteralPath (Join-Path $tmp 'runs.jsonl')).Count -eq $runsBefore)
  Check 'trouble PC: 11 notes'                   ($notes.Count -eq 11)
  Check 'trouble PC: the 3 urgent notes come first' ((@($notes | ForEach-Object { $_.level }) -join ',') -eq (@('attention') * 3 + @('info') * 8 -join ','))
  $expect = 'health as .Warning', 'Drive C: is 98% full', 'basic display driver', 'Drive D: is 92% full', 'is from 2020-03',
            'rated for 3200', '4 GB of memory', '60 Hz but can do 165 Hz', 'connected at 100 Mbps', '21 days without a restart', 'Windows 10 support ended'
  foreach ($k in $expect) { Check "trouble PC: note about '$k'" (@($notes | Where-Object { $_.text -match $k }).Count -eq 1) }
  $all = @($notes | ForEach-Object { $_.text }) -join ' '
  Check 'trouble PC: USB stick, Wi-Fi, tiny partition and second display stay quiet' ($all -notmatch 'USB Stick|Wi-Fi|Drive [EG]:|Example 24 ')

  # A healthy made-up PC. Its two dates are filled in relative to today so the test does not age.
  $clean = Join-Path ([IO.Path]::GetTempPath()) ('applog-sample-' + [guid]::NewGuid().ToString('N') + '.json')
  $json = [IO.File]::ReadAllText((Join-Path $fx 'sample.json')).Replace('DRIVERDATE', (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')).Replace('LASTBOOT', (Get-Date).AddHours(-5).ToString('yyyy-MM-ddTHH:mm:ss'))
  [IO.File]::WriteAllText($clean, $json)
  try {
    $r = Run 'PCSpecs.ps1' @('-Json', '-FromFile', $clean)
    Check 'healthy PC: no notes'                 ($r.code -eq 0 -and @($r.json.notes).Count -eq 0)
    $r = Run 'PCSpecs.ps1' @('-FromFile', $clean)
    Check 'healthy PC: says nothing stands out'  ($r.text -match '(?m)^WORTH KNOWING\r?$' -and $r.text -match 'Nothing stands out')
    # One setting wrong: exactly one note, and long notes wrap instead of running off the window.
    [IO.File]::WriteAllText($clean, $json.Replace('"hz": 165, "maxHz": 165', '"hz": 60, "maxHz": 165'))
    $r = Run 'PCSpecs.ps1' @('-FromFile', $clean)
    Check 'one wrong setting: one note'          (@([regex]::Matches($r.text, '(?m)^  [!-] ')).Count -eq 1 -and $r.text -match 'DELL S2721DGF is set to 60 Hz')
    Check 'notes wrap at the window width'       (@(($r.text -split "`n") | Where-Object { $_.TrimEnd().Length -gt 84 -and $_ -match '^  ' }).Count -eq 0)
  } finally { Remove-Item -LiteralPath $clean -Force }

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

  # ---- window (Start.bat -> app\Launcher.ps1) ----
  Check 'Start.bat points at the window'         ((Get-Content -LiteralPath (Join-Path $root 'Start.bat') -Raw) -match 'app\\Launcher\.ps1')
  $r = Run 'Launcher.ps1' @('-TestHook', (Join-Path $root 'tests\LauncherHook.ps1'), '-LogDir', $tmp)
  Check 'Launcher window opens and its buttons work' ($r.code -eq 0)
  Check 'Launcher My apps page shows earlier changes' ($r.text -match 'EARLIER IN THE LAST 30 DAYS[\s\S]*Removed\s+Smoke Test Removed App')
  if ($r.code -ne 0) { $r.text }

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
