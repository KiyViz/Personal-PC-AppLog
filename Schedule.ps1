<#
.SYNOPSIS
  Run AppLog + PCSpecs automatically (Windows Task Scheduler).

.DESCRIPTION
  Registers one task, "Personal-PC-AppLog", for the current user. If the PC is
  off at the scheduled time, it runs at next startup. Re-run after moving this
  folder (the task stores the script paths).

.PARAMETER Every   Weekly (default, Sundays) or Daily.
.PARAMETER At      Time of day, 24h. Default 10:00.
.PARAMETER Remove  Delete the task.

.EXAMPLE
  .\Schedule.ps1
.EXAMPLE
  .\Schedule.ps1 -Every Daily -At 09:30
.EXAMPLE
  .\Schedule.ps1 -Remove
#>
[CmdletBinding()]
param(
  [ValidateSet('Weekly', 'Daily')][string]$Every = 'Weekly',
  [string]$At = '10:00',
  [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Personal-PC-AppLog'

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  "Removed scheduled task '$TaskName'. Logs were kept."
  exit 0
}

$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fmt = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"'
$actions = @(
  (New-ScheduledTaskAction -Execute $ps -Argument ($fmt -f (Join-Path $PSScriptRoot 'AppLog.ps1'))),
  (New-ScheduledTaskAction -Execute $ps -Argument ($fmt -f (Join-Path $PSScriptRoot 'PCSpecs.ps1')))
)
if ($Every -eq 'Daily') { $trigger = New-ScheduledTaskTrigger -Daily -At $At }
else                    { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $At }
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

try {
  Register-ScheduledTask -TaskName $TaskName -Action $actions -Trigger $trigger -Settings $settings `
    -Description 'Personal-PC-AppLog: logs installed apps and PC specs.' -Force | Out-Null
} catch {
  Write-Host "Could not create the task: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'Try again: right-click Start.bat > Run as administrator.'
  exit 1
}

$when = 'Sundays'; if ($Every -eq 'Daily') { $when = 'daily' }
"Scheduled '$TaskName': $when at $At. Runs at next startup if the PC was off."
"Logs: $(Join-Path $PSScriptRoot 'logs')"
"Undo: Start.bat option 5, or Schedule.ps1 -Remove"
