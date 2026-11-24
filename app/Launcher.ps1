<#
.SYNOPSIS
  Point-and-click window for AppLog and PCSpecs. Start.bat opens it.

.DESCRIPTION
  A small window with buttons: My PC (specs), My apps (what is installed and
  what changed), copy the result, and turn the weekly automatic check on or
  off. It only runs the other scripts in this folder and shows what they
  print. Prefer the keyboard? Use Menu.bat.

.PARAMETER LogDir    Passed through to AppLog.ps1 and PCSpecs.ps1.
.PARAMETER TestHook  For the automated tests only: a script to run inside the window
                     (off-screen) instead of waiting for clicks. See tests\LauncherHook.ps1.

.EXAMPLE
  .\Launcher.ps1
#>
[CmdletBinding()]
param(
  [string]$LogDir = '',
  [string]$TestHook = ''
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot; if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$PsExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TaskName = 'Personal-PC-AppLog'
$logsPath = $LogDir
if (-not $logsPath) {
  # Same default as the tools: logs\ next to Start.bat, one level above app\.
  $base = $here; $up = Split-Path -Parent $here
  if ($up -and (Test-Path -LiteralPath (Join-Path $up 'Start.bat'))) { $base = $up }
  $logsPath = Join-Path $base 'logs'
}
$script:job  = $null
$script:fail = 0

$Welcome = @'
Welcome. Pick a button on the left.

  My PC
      Your hardware and Windows version in one short list.
      Handy to paste into a support chat, an email or a forum post.

  My apps
      Everything installed on this PC, plus what was added, removed
      or updated since your last check and over the last 30 days.

Nothing on your PC is changed. Results are saved in the "logs" folder
next to this program and are never sent anywhere.
'@

function Quote([string]$s) { "'" + ($s -replace "'", "''") + "'" }

function Format-Change($e, [bool]$WithDate) {
  $ver = ''
  if ($e.version -and -not ([string]$e.name).Contains([string]$e.version)) { $ver = " $($e.version)" }
  $what = $null
  switch ($e.event) {
    'added'   { $what = "Added    $($e.name)$ver" }
    'removed' { $what = "Removed  $($e.name)$ver" }
    'updated' { $what = "Updated  $($e.name): $($e.from) -> $($e.to)" }
  }
  if (-not $what) { return }
  if ($WithDate) { '  {0,-7} {1}' -f ([datetime]$e.ts).ToString('MMM d'), $what } else { "  $what" }
}

function Get-AppsReport($r) {
  # One page for "my apps": what changed just now, what changed recently, and the full list.
  # $r is the JSON result of AppLog.ps1 -Json; the rest comes from the logs it just wrote.
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $apps = @()
  $latest = Join-Path $logsPath 'apps\latest.json'
  if (Test-Path -LiteralPath $latest) {
    try { $apps = @(([IO.File]::ReadAllText($latest, $utf8) | ConvertFrom-Json).apps) } catch { }
  }
  $desk  = @($apps | Where-Object { $_.source -ne 'store' } | Sort-Object name)
  $store = @($apps | Where-Object { $_.source -eq 'store' } | Sort-Object name)

  $L = New-Object System.Collections.Generic.List[string]
  $head = "$($r.apps) apps installed"
  if ($store.Count -gt 0) { $head += " ($($desk.Count) desktop apps + $($store.Count) Microsoft Store apps)" }
  $L.Add("$head. Checked just now.")
  $L.Add('')

  $L.Add('NEW SINCE YOUR LAST CHECK')
  $new = @($r.changes | Where-Object { $_.event -ne 'baseline' })
  if (@($r.changes | Where-Object { $_.event -eq 'baseline' }).Count -gt 0) {
    $L.Add('  This was your first check, so there is nothing to compare yet.')
    $L.Add('  From now on this part shows what was added, removed or updated.')
  } elseif ($new.Count -eq 0) {
    $L.Add('  Nothing changed.')
  } else {
    foreach ($e in $new) { $line = Format-Change $e $false; if ($line) { $L.Add($line) } }
  }
  $L.Add('')

  $L.Add('EARLIER IN THE LAST 30 DAYS')
  $old = @()
  $log = Join-Path $logsPath 'apps\changes.jsonl'
  if (Test-Path -LiteralPath $log) {
    $cut = (Get-Date).AddDays(-30)
    foreach ($row in ([IO.File]::ReadAllText($log, $utf8) -split "`n")) {
      if (-not $row.Trim()) { continue }
      try { $e = $row | ConvertFrom-Json } catch { continue }
      if ($e.event -ne 'baseline' -and $e.ts -ne $r.ts -and [datetime]$e.ts -ge $cut) { $old += $e }
    }
  }
  if ($old.Count -eq 0) { $L.Add('  Nothing.') }
  else {
    [array]::Reverse($old)   # newest first
    foreach ($e in $old) { $line = Format-Change $e $true; if ($line) { $L.Add($line) } }
  }
  $L.Add('')

  if ($apps.Count -gt 0) {
    $w = 10
    foreach ($a in $apps) { $n = ([string]$a.name).Length; if ($n -gt $w) { $w = $n } }
    if ($w -gt 44) { $w = 44 }
    $L.Add("DESKTOP APPS ($($desk.Count))")
    foreach ($a in $desk) { $L.Add(('  ' + ([string]$a.name).PadRight($w) + '  ' + $a.version).TrimEnd()) }
    if ($store.Count -gt 0) {
      $L.Add('')
      $L.Add("MICROSOFT STORE APPS ($($store.Count))")
      foreach ($a in $store) { $L.Add(('  ' + ([string]$a.name).PadRight($w) + '  ' + $a.version).TrimEnd()) }
    }
  }
  $L -join "`r`n"
}

function Test-AutoRun {
  try {
    $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList '/query', '/tn', $TaskName -WindowStyle Hidden -PassThru -Wait
    $p.ExitCode -eq 0
  } catch { $false }
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  try {
    # Sharp text on high-DPI screens. Must run before the first window is created.
    Add-Type -Namespace PCAppLog -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][PCAppLog.Dpi]::SetProcessDPIAware()
  } catch { }
  [System.Windows.Forms.Application]::EnableVisualStyles()

  # ---- window --------------------------------------------------------------------
  $form = New-Object System.Windows.Forms.Form
  $form.SuspendLayout()
  $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
  $form.Text          = 'PC AppLog'
  $form.Font          = New-Object System.Drawing.Font('Segoe UI', 10)
  $form.ClientSize    = New-Object System.Drawing.Size(940, 560)
  $form.MinimumSize   = New-Object System.Drawing.Size(700, 420)
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

  $txt = New-Object System.Windows.Forms.TextBox
  $txt.Multiline  = $true
  $txt.ReadOnly   = $true
  $txt.WordWrap   = $false
  $txt.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
  $txt.Dock       = [System.Windows.Forms.DockStyle]::Fill
  $txt.Font       = New-Object System.Drawing.Font('Consolas', 10)
  $txt.BackColor  = [System.Drawing.SystemColors]::Window
  $txt.TabStop    = $false
  $txt.Text       = ($Welcome -replace "`r?`n", "`r`n")

  $left = New-Object System.Windows.Forms.FlowLayoutPanel
  $left.Dock          = [System.Windows.Forms.DockStyle]::Left
  $left.Width         = 270
  $left.Padding       = New-Object System.Windows.Forms.Padding(12)
  $left.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
  $left.WrapContents  = $false

  function New-Button([string]$Text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text   = $Text
    $b.Size   = New-Object System.Drawing.Size(244, 44)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    $left.Controls.Add($b)
    $b
  }
  $btnSpecs = New-Button 'My PC'
  $btnApps  = New-Button 'My apps'

  $chkAuto = New-Object System.Windows.Forms.CheckBox
  $chkAuto.Text      = 'Check automatically every Sunday at 10:00'
  $chkAuto.AutoCheck = $false          # the tick follows the real scheduled task, not the click
  $chkAuto.Size      = New-Object System.Drawing.Size(244, 48)
  $chkAuto.Margin    = New-Object System.Windows.Forms.Padding(2, 12, 0, 12)
  $left.Controls.Add($chkAuto)

  $btnCopy = New-Button 'Copy to clipboard'
  $btnLogs = New-Button 'Open saved logs'

  $status = New-Object System.Windows.Forms.Label
  $status.Dock      = [System.Windows.Forms.DockStyle]::Bottom
  $status.Height    = 30
  $status.Padding   = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
  $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
  $status.Text      = 'Ready. Read-only: nothing on your PC is changed.'

  # Docking runs from the last control added to the first, so the text box (Fill) goes in first.
  $form.Controls.Add($txt)
  $form.Controls.Add($left)
  $form.Controls.Add($status)
  $form.ResumeLayout($false)
  $form.PerformLayout()

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 100

  # ---- running a tool without freezing the window ----------------------------------
  function Set-Busy([bool]$On, [string]$Msg) {
    foreach ($c in $btnSpecs, $btnApps, $chkAuto) { $c.Enabled = -not $On }
    $form.UseWaitCursor = $On
    $status.Text = $Msg
  }
  function Show-Text([string]$Text) {
    # Drop the "Saved: C:\Users\<name>\..." lines: people paste this text into chats and forums.
    $Text = $Text -replace '(?m)^(Saved|Log|Logs): .*$', ''
    $txt.Text = ($Text.Trim() -replace "`r?`n", "`r`n")
    $txt.SelectionStart = 0
    $txt.SelectionLength = 0
  }
  function Start-Tool([string]$Script, [string[]]$ToolArgs, [string]$Busy, [scriptblock]$Done) {
    if ($script:job) { return }
    # UTF-8 keeps app names with accents readable. Arguments here are fixed switches and numbers.
    $cmd = '$ProgressPreference = ''SilentlyContinue''; [Console]::OutputEncoding = [Text.Encoding]::UTF8; & ' + (Quote (Join-Path $here $Script))
    if ($ToolArgs) { $cmd += ' ' + ($ToolArgs -join ' ') }
    if ($LogDir -and $Script -ne 'Schedule.ps1') { $cmd += ' -LogDir ' + (Quote $LogDir) }
    $cmd += '; exit $LASTEXITCODE'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $PsExe
    $psi.Arguments              = '-NoProfile -ExecutionPolicy Bypass -Command "' + $cmd + '"'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:job = @{ proc = $p; out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync(); done = $Done }
    Set-Busy $true $Busy
    $timer.Start()
  }
  $timer.Add_Tick({
    $j = $script:job
    if (-not $j -or -not $j.proc.HasExited -or -not $j.out.IsCompleted -or -not $j.err.IsCompleted) { return }
    $timer.Stop()
    $script:job = $null
    try {
      $text = [string]$j.out.Result
      $err  = ([string]$j.err.Result).Trim()
      if ($err -and $err -notlike '#< CLIXML*') { $text = $text.TrimEnd() + "`r`n`r`n" + $err }
      $code = $j.proc.ExitCode
      Set-Busy $false 'Ready.'
      & $j.done $text $code
    } catch {
      Set-Busy $false 'Something went wrong.'
      Show-Text "Something went wrong:`r`n$($_.Exception.Message)"
    }
  })

  # ---- buttons -------------------------------------------------------------------
  $btnSpecs.Add_Click({
    Start-Tool 'PCSpecs.ps1' @() 'Reading your PC specs...' {
      param($text, $code)
      Show-Text $text
      if ($code -eq 0) { $status.Text = 'Done. Press "Copy to clipboard" to paste this somewhere.' } else { $status.Text = 'Finished with an error.' }
    }
  })
  $btnApps.Add_Click({
    Start-Tool 'AppLog.ps1' @('-Json') 'Checking your apps...' {
      param($text, $code)
      $r = $null
      try { $r = $text | ConvertFrom-Json } catch { }
      if ($r -and $r.status -eq 'ok') {
        Show-Text (Get-AppsReport $r)
        $n = @($r.changes | Where-Object { $_.event -ne 'baseline' }).Count
        if ($n -eq 0) { $status.Text = 'Done. Nothing changed since your last check.' }
        else          { $status.Text = "Done. $n change(s) since your last check." }
      } else {
        if ($r -and $r.error) { Show-Text "Could not check your apps:`r`n$($r.error)" } else { Show-Text $text }
        $status.Text = 'Finished with an error.'
      }
    }
  })
  $chkAuto.Add_Click({
    $toolArgs = @(); $busy = 'Turning on the weekly check...'
    if ($chkAuto.Checked) { $toolArgs = @('-Remove'); $busy = 'Turning off the weekly check...' }
    Start-Tool 'Schedule.ps1' $toolArgs $busy {
      param($text, $code)
      Show-Text $text
      $chkAuto.Checked = Test-AutoRun
      if ($chkAuto.Checked) { $status.Text = 'The weekly check is on.' } else { $status.Text = 'The weekly check is off.' }
    }
  })
  $btnCopy.Add_Click({
    if ($txt.Text) {
      [System.Windows.Forms.Clipboard]::SetText($txt.Text)
      $status.Text = 'Copied. Paste it anywhere with Ctrl+V.'
    }
  })
  $btnLogs.Add_Click({
    if (-not (Test-Path -LiteralPath $logsPath)) { New-Item -ItemType Directory -Force -Path $logsPath | Out-Null }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $logsPath)
  })

  $chkAuto.Checked = Test-AutoRun
  $form.Add_Shown({ $form.Activate() })

  # ---- test seam: the hook script presses the buttons and checks the result ------------
  if ($TestHook) {
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location      = New-Object System.Drawing.Point(-32000, -32000)   # off-screen
    $form.ShowInTaskbar = $false
    $form.Show()
    . $TestHook
    $form.Close()
    $form.Dispose()
    exit $script:fail
  }

  [System.Windows.Forms.Application]::Run($form)
} catch {
  if ($TestHook) { "FAIL  launcher: $($_.Exception.Message)"; exit 1 }
  # No window available (stripped-down Windows): fall back to the keyboard menu.
  Start-Process -FilePath (Join-Path $here 'Menu.bat')
}
