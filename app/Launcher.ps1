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

function Get-AppsData($r) {
  # Everything the "My apps" page shows, as data: the screen text and every file format are
  # made from this. $r is the JSON result of AppLog.ps1 -Json; the rest comes from its logs.
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $apps = @()
  $latest = Join-Path $logsPath 'apps\latest.json'
  if (Test-Path -LiteralPath $latest) {
    try { $apps = @(([IO.File]::ReadAllText($latest, $utf8) | ConvertFrom-Json).apps) } catch { }
  }
  $old = @()
  $log = Join-Path $logsPath 'apps\changes.jsonl'
  if (Test-Path -LiteralPath $log) {
    $cut = (Get-Date).AddDays(-30)
    foreach ($row in ([IO.File]::ReadAllText($log, $utf8) -split "`n")) {
      if (-not $row.Trim()) { continue }
      try { $e = $row | ConvertFrom-Json } catch { continue }
      if ($e.event -ne 'baseline' -and $e.ts -ne $r.ts -and [datetime]$e.ts -ge $cut) { $old += $e }
    }
    [array]::Reverse($old)   # newest first
  }
  $d = @{
    kind  = 'apps'; name = 'My apps'; json = $latest
    total = $r.apps
    first = (@($r.changes | Where-Object { $_.event -eq 'baseline' }).Count -gt 0)
    new   = @($r.changes | Where-Object { $_.event -ne 'baseline' })
    old   = $old
    desk  = @($apps | Where-Object { $_.source -ne 'store' } | Sort-Object name)
    store = @($apps | Where-Object { $_.source -eq 'store' } | Sort-Object name)
  }
  $d.head = "$($d.total) apps installed"
  if ($d.store.Count -gt 0) { $d.head += " ($($d.desk.Count) desktop apps + $($d.store.Count) Microsoft Store apps)" }
  $d
}

function Format-AppsText($d) {
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("$($d.head). Checked just now.")
  $L.Add('')
  $L.Add('NEW SINCE YOUR LAST CHECK')
  if ($d.first) {
    $L.Add('  This was your first check, so there is nothing to compare yet.')
    $L.Add('  From now on this part shows what was added, removed or updated.')
  } elseif ($d.new.Count -eq 0) {
    $L.Add('  Nothing changed.')
  } else {
    foreach ($e in $d.new) { $line = Format-Change $e $false; if ($line) { $L.Add($line) } }
  }
  $L.Add('')
  $L.Add('EARLIER IN THE LAST 30 DAYS')
  if ($d.old.Count -eq 0) { $L.Add('  Nothing.') }
  else { foreach ($e in $d.old) { $line = Format-Change $e $true; if ($line) { $L.Add($line) } } }
  $L.Add('')
  if ($d.desk.Count + $d.store.Count -gt 0) {
    $w = 10
    foreach ($a in @($d.desk) + @($d.store)) { $n = ([string]$a.name).Length; if ($n -gt $w) { $w = $n } }
    if ($w -gt 44) { $w = 44 }
    $L.Add("DESKTOP APPS ($($d.desk.Count))")
    foreach ($a in $d.desk) { $L.Add(('  ' + ([string]$a.name).PadRight($w) + '  ' + $a.version).TrimEnd()) }
    if ($d.store.Count -gt 0) {
      $L.Add('')
      $L.Add("MICROSOFT STORE APPS ($($d.store.Count))")
      foreach ($a in $d.store) { $L.Add(('  ' + ([string]$a.name).PadRight($w) + '  ' + $a.version).TrimEnd()) }
    }
  }
  $L -join "`r`n"
}

function Get-SpecsData([string]$Text) {
  # The "My PC" page as rows of Item / Details, read back from the summary text.
  $rows = @(); $inSummary = $true
  foreach ($line in ($Text -split "`r?`n")) {
    if (-not $line.Trim()) { $inSummary = $false; continue }
    if ($inSummary -and $line -match '^(\S+)\s+(\S.*)$') { $rows += [pscustomobject]@{ Item = $Matches[1]; Details = $Matches[2] } }
    elseif ($line -match '^\s+~ (.+)$')                  { $rows += [pscustomobject]@{ Item = 'Changed since last run'; Details = $Matches[1] } }
  }
  @{ kind = 'pc'; name = 'PC specs'; json = (Join-Path $logsPath 'specs\latest.json'); rows = $rows }
}

# ---- saving the page to a file --------------------------------------------------------
function ConvertTo-CsvLine($Cells) {
  (@($Cells) | ForEach-Object {
    $c = [string]$_
    if ($c -match '^[=+\-@]') { $c = "'" + $c }   # so a spreadsheet never runs a cell as a formula
    '"' + $c.Replace('"', '""') + '"'
  }) -join ','
}
function ConvertTo-MdRow($Cells) {
  '| ' + ((@($Cells) | ForEach-Object { ([string]$_).Replace('|', '\|') }) -join ' | ') + ' |'
}
function Get-ChangeCells($e, [string]$Section) {
  $ver = $e.version; if ($e.event -eq 'updated') { $ver = $e.to }
  @($Section, $e.name, $ver, $e.publisher, ([string]$e.event), $e.from, ([datetime]$e.ts).ToString('yyyy-MM-dd'))
}
function Get-Export($v, [string]$Format, [string]$ScreenText) {
  # $v is what Get-AppsData or Get-SpecsData returned. Returns the file content as one string.
  $nl = "`r`n"
  $today = (Get-Date).ToString('yyyy-MM-dd')
  if ($Format -eq 'json') { return [IO.File]::ReadAllText($v.json, (New-Object System.Text.UTF8Encoding($false))) }
  if ($Format -eq 'txt')  { return $ScreenText + $nl }
  $L = New-Object System.Collections.Generic.List[string]
  if ($v.kind -eq 'pc') {
    if ($Format -eq 'csv') {
      $L.Add((ConvertTo-CsvLine 'Item', 'Details'))
      foreach ($r in $v.rows) { $L.Add((ConvertTo-CsvLine $r.Item, $r.Details)) }
    } else {
      $L.Add('# PC specs'); $L.Add(''); $L.Add("Checked $today."); $L.Add('')
      $L.Add('| Item | Details |'); $L.Add('|---|---|')
      foreach ($r in $v.rows) { $L.Add((ConvertTo-MdRow $r.Item, $r.Details)) }
    }
  } elseif ($Format -eq 'csv') {
    $L.Add((ConvertTo-CsvLine 'Section', 'App', 'Version', 'Publisher', 'Change', 'Previous version', 'Date'))
    foreach ($e in $v.new)   { $L.Add((ConvertTo-CsvLine (Get-ChangeCells $e 'New since last check'))) }
    foreach ($e in $v.old)   { $L.Add((ConvertTo-CsvLine (Get-ChangeCells $e 'Earlier in the last 30 days'))) }
    foreach ($a in $v.desk)  { $L.Add((ConvertTo-CsvLine 'Desktop app', $a.name, $a.version, $a.publisher, '', '', '')) }
    foreach ($a in $v.store) { $L.Add((ConvertTo-CsvLine 'Microsoft Store app', $a.name, $a.version, $a.publisher, '', '', '')) }
  } else {
    $L.Add('# Installed apps'); $L.Add(''); $L.Add("$($v.head). Checked $today."); $L.Add('')
    $L.Add('## New since the last check'); $L.Add('')
    if ($v.first) { $L.Add('This was the first check, so there is nothing to compare yet.') }
    elseif ($v.new.Count -eq 0) { $L.Add('Nothing changed.') }
    else { foreach ($e in $v.new) { $L.Add('- ' + ((Format-Change $e $false).Trim() -replace '\s{2,}', ' ')) } }
    $L.Add(''); $L.Add('## Earlier in the last 30 days'); $L.Add('')
    if ($v.old.Count -eq 0) { $L.Add('Nothing.') }
    else { foreach ($e in $v.old) { $L.Add('- ' + ([datetime]$e.ts).ToString('yyyy-MM-dd') + ': ' + ((Format-Change $e $false).Trim() -replace '\s{2,}', ' ')) } }
    foreach ($part in @(@('Desktop apps', $v.desk), @('Microsoft Store apps', $v.store))) {
      if (@($part[1]).Count -eq 0) { continue }
      $L.Add(''); $L.Add("## $($part[0]) ($(@($part[1]).Count))"); $L.Add('')
      $L.Add('| App | Version |'); $L.Add('|---|---|')
      foreach ($a in $part[1]) { $L.Add((ConvertTo-MdRow $a.name, $a.version)) }
    }
  }
  ($L -join $nl) + $nl
}
function Save-View($v, [string]$Path, [string]$Format, [string]$ScreenText) {
  $text = Get-Export $v $Format $ScreenText
  # Spreadsheet programs need the byte-order mark to read accented names in a CSV correctly.
  [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($Format -eq 'csv')))
}

function Test-AutoRun {
  # Asks Task Scheduler directly. Starting schtasks.exe for this took about a second.
  try {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    [void]$svc.GetFolder('\').GetTask($TaskName)
    $true
  } catch { $false }
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  try {
    # Sharp text on high-DPI screens. Must run before the first window is created.
    # This borrows WinForms' own declaration of user32 SetProcessDPIAware; declaring it again
    # with Add-Type would compile C# at every start and cost about 100 ms.
    $dpi = [System.Windows.Forms.Form].Assembly.GetType('System.Windows.Forms.SafeNativeMethods').GetMethod('SetProcessDPIAware', [System.Reflection.BindingFlags]'NonPublic,Public,Static')
    if ($dpi) { [void]$dpi.Invoke($null, @()) }
  } catch { }
  try {
    # The first font in a process costs Windows about 0.3 s (more with many fonts installed).
    # Start that now on a second thread so it overlaps with building the window below.
    # Pure .NET delegate: no PowerShell code runs off the main thread.
    $warm = [Delegate]::CreateDelegate([Func[System.Drawing.Font]], [System.Drawing.SystemFonts].GetProperty('MessageBoxFont').GetGetMethod())
    [void]$warm.BeginInvoke($null, $null)
  } catch { }
  $autoRun = Test-AutoRun      # done here so it overlaps with the font warm-up
  [System.Windows.Forms.Application]::EnableVisualStyles()

  # ---- window --------------------------------------------------------------------
  $form = New-Object System.Windows.Forms.Form
  $form.SuspendLayout()
  $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
  $form.Text          = 'PC AppLog'
  $form.ClientSize    = New-Object System.Drawing.Size(940, 560)
  $form.MinimumSize   = New-Object System.Drawing.Size(700, 420)
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

  $txt = New-Object System.Windows.Forms.TextBox
  $txt.Multiline  = $true
  $txt.ReadOnly   = $true
  $txt.WordWrap   = $false
  $txt.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
  $txt.Dock       = [System.Windows.Forms.DockStyle]::Fill
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
  $btnSave = New-Button 'Save to file...'
  $btnSave.Enabled = $false            # nothing to save until My PC or My apps has run
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

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 100

  # ---- running a tool without freezing the window ----------------------------------
  function Set-Busy([bool]$On, [string]$Msg) {
    foreach ($c in $btnSpecs, $btnApps, $chkAuto) { $c.Enabled = -not $On }
    $form.UseWaitCursor = $On
    $status.Text = $Msg
  }
  function Show-Text([string]$Text, $View = $null) {
    # Drop the "Saved: C:\Users\<name>\..." lines: people paste this text into chats and forums.
    $Text = $Text -replace '(?m)^(Saved|Log|Logs): .*$', ''
    $txt.Text = ($Text.Trim() -replace "`r?`n", "`r`n")
    $txt.SelectionStart = 0
    $txt.SelectionLength = 0
    # $View is the page as data (for Save to file). Messages and errors have none.
    $script:view = $View
    $btnSave.Enabled = [bool]$View
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
      if ($code -eq 0) {
        $script:view = Get-SpecsData $txt.Text     # rows are read back from the text on screen
        $btnSave.Enabled = $true
        $status.Text = 'Done. Copy it to the clipboard or save it to a file.'
      } else {
        $status.Text = 'Finished with an error.'
      }
    }
  })
  $btnApps.Add_Click({
    Start-Tool 'AppLog.ps1' @('-Json') 'Checking your apps...' {
      param($text, $code)
      $r = $null
      try { $r = $text | ConvertFrom-Json } catch { }
      if ($r -and $r.status -eq 'ok') {
        $d = Get-AppsData $r
        Show-Text (Format-AppsText $d) $d
        $n = $d.new.Count
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
  function New-SaveDialog($v) {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title    = 'Save to file'
    $dlg.Filter   = 'Plain text (*.txt)|*.txt|Markdown, for notes and forums (*.md)|*.md|Spreadsheet, CSV (*.csv)|*.csv|JSON, for other programs (*.json)|*.json'
    $dlg.FileName = "$($v.name) $((Get-Date).ToString('yyyy-MM-dd'))"
    $dlg
  }
  function Get-SaveFormat([string]$FileName, [int]$FilterIndex) {
    # The ending the person typed wins; otherwise the type picked in the list (1 = first).
    $formats = @('txt', 'md', 'csv', 'json')
    $fmt = [IO.Path]::GetExtension($FileName).TrimStart('.').ToLowerInvariant()
    if ($formats -notcontains $fmt) { $fmt = $formats[$FilterIndex - 1] }
    $fmt
  }
  $btnSave.Add_Click({
    if (-not $script:view) { return }
    $dlg = New-SaveDialog $script:view
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
      Save-View $script:view $dlg.FileName (Get-SaveFormat $dlg.FileName $dlg.FilterIndex) $txt.Text
      $status.Text = "Saved $([IO.Path]::GetFileName($dlg.FileName))"
    } catch {
      $status.Text = "Could not save: $($_.Exception.Message)"
    }
  })
  $btnLogs.Add_Click({
    if (-not (Test-Path -LiteralPath $logsPath)) { New-Item -ItemType Directory -Force -Path $logsPath | Out-Null }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $logsPath)
  })

  $chkAuto.Checked = $autoRun
  # Fonts last: everything above ran while the font warm-up was working in the background.
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
  $txt.Font  = New-Object System.Drawing.Font('Consolas', 10)
  $form.ResumeLayout($false)
  $form.PerformLayout()
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
} finally {
  # Start.bat hides the console window it runs in. After a double-click that console is a
  # throwaway, and its title is the path of cmd.exe. If someone typed Start.bat in their own
  # terminal instead, the title is something else: show that terminal again.
  if (-not $TestHook) {
    try {
      if ([Console]::Title -ne $env:ComSpec) {
        Add-Type -Namespace PCAppLog -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);'
        [void][PCAppLog.Con]::ShowWindow([PCAppLog.Con]::GetConsoleWindow(), 5)
      }
    } catch { }
  }
}
