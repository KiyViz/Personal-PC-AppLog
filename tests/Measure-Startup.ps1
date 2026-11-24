<#
.SYNOPSIS
  Measure how long Start.bat takes from double-click to a visible window.

.DESCRIPTION
  Starts Start.bat the way Explorer does, waits for the "PC AppLog" window to become visible,
  closes it, and repeats. Prints each time and the median in milliseconds.
  The budget is under 1000 ms on an ordinary PC.

.PARAMETER Runs      How many launches to time. Default 5.
.PARAMETER BudgetMs  If set, exit 1 when the median is above this.
.PARAMETER StartFile A different .bat to time instead of Start.bat (for comparing variants).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Measure-Startup.ps1
#>
[CmdletBinding()]
param([int]$Runs = 5, [int]$BudgetMs = 0, [string]$StartFile = '')

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$start = $StartFile; if (-not $start) { $start = Join-Path $root 'Start.bat' }

Add-Type -Namespace PCAppLogTest -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr w, IntPtr l);
'@
function Get-Windows {
  # Every visible top-level window titled "PC AppLog".
  $h = [IntPtr]::Zero
  while ($true) {
    $h = [PCAppLogTest.Win]::FindWindowEx([IntPtr]::Zero, $h, [NullString]::Value, 'PC AppLog')
    if ($h -eq [IntPtr]::Zero) { break }
    if ([PCAppLogTest.Win]::IsWindowVisible($h)) { $h }
  }
}
# A window the user already has open is left alone; only new ones are timed and closed.
$mine = @(Get-Windows)
function Find-Window {
  foreach ($h in @(Get-Windows)) { if ($mine -notcontains $h) { return $h } }
  [IntPtr]::Zero
}

$times = @()
foreach ($i in 1..$Runs) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $env:ComSpec
  $psi.Arguments = '/c "' + $start + '"'
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $psi.UseShellExecute = $true
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  [void][System.Diagnostics.Process]::Start($psi)
  $h = [IntPtr]::Zero
  while ($sw.ElapsedMilliseconds -lt 20000) {
    $h = Find-Window
    if ($h -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 5
  }
  $ms = $sw.ElapsedMilliseconds
  if ($h -eq [IntPtr]::Zero) { "run ${i}: window did not appear"; exit 1 }
  $times += $ms
  "run ${i}: $ms ms"
  [void][PCAppLogTest.Win]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
  $wait = [System.Diagnostics.Stopwatch]::StartNew()
  while ([PCAppLogTest.Win]::IsWindow($h) -and $wait.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
  Start-Sleep -Milliseconds 300
}
$sorted = @($times | Sort-Object)
$median = $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
"median: $median ms (fastest $($sorted[0]), slowest $($sorted[-1]))"
if ($BudgetMs -gt 0 -and $median -gt $BudgetMs) { "over the $BudgetMs ms budget"; exit 1 }
