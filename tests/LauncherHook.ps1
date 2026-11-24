# Runs INSIDE app\Launcher.ps1 (dot-sourced by -TestHook) after the window is built and shown
# off-screen. It presses each read-only button and checks what the window shows.
# It can use the launcher's variables: $form, $txt, $btnSpecs, $btnApps, $script:job, $script:fail.
#
# If the environment variable PCAPPLOG_SHOTS names a folder, the window is also moved on-screen
# and real screenshots are saved there (see tests\Make-Screenshots.ps1).

function Wait-Idle {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  do { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 } while ($script:job -and $sw.Elapsed.TotalSeconds -lt 90)
}
function Check([string]$Name, $Ok) { if ($Ok) { "ok    $Name" } else { "FAIL  $Name"; $script:fail++ } }

$shots = $env:PCAPPLOG_SHOTS
$back  = $null
if ($shots) {
  Add-Type -Namespace PCAppLogTest -Name Dwm -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT rect, int size);
'@
  # A plain white sheet behind the window, so nothing from the real desktop is in the picture.
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Location = New-Object System.Drawing.Point(($area.X + 120), ($area.Y + 80))
  $back = New-Object System.Windows.Forms.Form
  $back.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $back.BackColor       = [System.Drawing.Color]::White
  $back.ShowInTaskbar   = $false
  $back.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
  $back.Bounds          = New-Object System.Drawing.Rectangle(($form.Left - 60), ($form.Top - 60), ($form.Width + 120), ($form.Height + 120))
  $back.TopMost         = $true
  $back.Show()
  $form.TopMost = $true         # both are topmost; the one raised last is in front
  $form.BringToFront()
  $form.Activate()
}
function Save-Shot([string]$Name) {
  if (-not $shots) { return }
  $txt.SelectionLength = 0
  $form.ActiveControl = $null
  foreach ($i in 1..12) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
  $r = New-Object PCAppLogTest.Dwm+RECT
  [void][PCAppLogTest.Dwm]::DwmGetWindowAttribute($form.Handle, 9, [ref]$r, 16)   # 9 = visible frame bounds
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp.Save((Join-Path $shots "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  "shot  $Name.png ($w x $h)"
}

Wait-Idle
Check 'window opens with the welcome text' ($txt.Text -match 'Pick a button')
Save-Shot 'welcome'

$btnApps.PerformClick(); Wait-Idle
Check 'My apps shows the count'            ($txt.Text -match '^\d+ apps installed')
Check 'My apps shows both change sections' ($txt.Text -match 'NEW SINCE YOUR LAST CHECK' -and $txt.Text -match 'EARLIER IN THE LAST 30 DAYS')
Check 'My apps lists the installed apps'   ($txt.Text -match '(?m)^DESKTOP APPS \(\d+\)\r?$')
# Echo the top of the page (everything above the full list) so Smoke.ps1 can read it.
foreach ($line in ($txt.Text -split "`r?`n")) { if ($line -like 'DESKTOP APPS*') { break }; "      | $line" }
Save-Shot 'my-apps'

$btnSpecs.PerformClick(); Wait-Idle
Check 'My PC shows the summary'            ($txt.Text -match '(?m)^OS\s+\S' -and $txt.Text -match '(?m)^CPU\s+\S')
Check 'no folder paths in the copied text' ($txt.Text -notmatch '(?m)^(Saved|Log): ')
Check 'buttons are enabled again'          ($btnSpecs.Enabled -and $btnApps.Enabled -and -not $script:job)
Save-Shot 'my-pc'

if ($back) { $back.Close(); $back.Dispose() }
