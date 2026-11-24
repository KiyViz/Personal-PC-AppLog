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

function Test-Exports([string]$Label, [string]$Schema, [int]$Rows) {
  # Save the page in every format and read each file back the way its target program would.
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('applog-export-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir | Out-Null
  try {
    foreach ($f in 'txt', 'md', 'csv', 'json') { Save-View $script:view (Join-Path $dir "out.$f") $f $txt.Text }
    Check "$Label saves as TXT"      ([IO.File]::ReadAllText((Join-Path $dir 'out.txt')).Trim() -eq $txt.Text.Trim())
    $md = [IO.File]::ReadAllText((Join-Path $dir 'out.md'))
    Check "$Label saves as Markdown" ($md -match '(?m)^# \S' -and $md -match '(?m)^\|---\|---\|\r?$')
    $csv = @(Import-Csv -LiteralPath (Join-Path $dir 'out.csv'))
    Check "$Label saves as CSV ($($csv.Count) rows)" ($csv.Count -eq $Rows -and $Rows -gt 0)
    $b = [IO.File]::ReadAllBytes((Join-Path $dir 'out.csv'))
    Check "$Label CSV opens cleanly in a spreadsheet (has BOM)" ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    $j = $null; try { $j = Get-Content -LiteralPath (Join-Path $dir 'out.json') -Raw | ConvertFrom-Json } catch { }
    Check "$Label saves as JSON"     ($j -and $j.schema -eq $Schema)
  } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}

Wait-Idle
Check 'window opens with the welcome text' ($txt.Text -match 'Pick a button')
Check 'Save to file is off until there is a result' (-not $btnSave.Enabled)
Check 'CSV cells cannot run as formulas'   ((ConvertTo-CsvLine '=1+1', 'a"b', 'ok') -eq '"''=1+1","a""b","ok"')
Check 'Markdown cells keep their pipes'    ((ConvertTo-MdRow 'a|b', 'c') -eq '| a\|b | c |')
Save-Shot 'welcome'

$btnApps.PerformClick(); Wait-Idle
Check 'My apps shows the count'            ($txt.Text -match '^\d+ apps installed')
Check 'My apps shows both change sections' ($txt.Text -match 'NEW SINCE YOUR LAST CHECK' -and $txt.Text -match 'EARLIER IN THE LAST 30 DAYS')
Check 'My apps lists the installed apps'   ($txt.Text -match '(?m)^DESKTOP APPS \(\d+\)\r?$')
# Echo the top of the page (everything above the full list) so Smoke.ps1 can read it.
foreach ($line in ($txt.Text -split "`r?`n")) { if ($line -like 'DESKTOP APPS*') { break }; "      | $line" }
Save-Shot 'my-apps'
$v = $script:view
Check 'Save to file is on after My apps'   ($btnSave.Enabled -and $v.kind -eq 'apps')
$dlg = New-SaveDialog $v
Check 'Save dialog offers four file types' (($dlg.Filter -split '\|').Count -eq 8 -and $dlg.FileName -like 'My apps 20*')
$dlg.Dispose()
Check 'typed ending decides the file type' ((Get-SaveFormat 'C:\x\list.CSV' 1) -eq 'csv' -and (Get-SaveFormat 'C:\x\list.md' 4) -eq 'md')
Check 'otherwise the picked type decides'  ((Get-SaveFormat 'C:\x\list' 3) -eq 'csv' -and (Get-SaveFormat 'C:\x\v1.2 notes' 2) -eq 'md')
Test-Exports 'My apps' 'applog/1' ($v.new.Count + $v.old.Count + $v.desk.Count + $v.store.Count)

$btnSpecs.PerformClick(); Wait-Idle
Check 'My PC shows the summary'            ($txt.Text -match '(?m)^OS\s+\S' -and $txt.Text -match '(?m)^CPU\s+\S')
Check 'My PC starts with Worth knowing'    ($txt.Text -match '^WORTH KNOWING\r?\n  \S')
$demo = "WORTH KNOWING`r`n  ! Disk X reports trouble. Back`r`n    it up now.`r`n  - Drive C: is 91% full.`r`n`r`nOS       Windows 11`r`nMonitors connected but not in use: TV`r`n`r`n1 spec change(s) since last run:`r`n  ~ gpu[0].driver: 1 -> 2"
$rows = @((Get-SpecsData $demo).rows | ForEach-Object { "$($_.Item)=$($_.Details)" }) -join ' ; '
Check 'notes and specs read back as rows'  ($rows -eq 'Needs attention=Disk X reports trouble. Back it up now. ; Worth knowing=Drive C: is 91% full. ; OS=Windows 11 ; Monitors=connected but not in use: TV ; Changed since last run=gpu[0].driver: 1 -> 2')
Check 'no folder paths in the copied text' ($txt.Text -notmatch '(?m)^(Saved|Log): ')
Check 'buttons are enabled again'          ($btnSpecs.Enabled -and $btnApps.Enabled -and -not $script:job)
Save-Shot 'my-pc'
$v = $script:view
Check 'Save to file is on after My PC'     ($btnSave.Enabled -and $v.kind -eq 'pc' -and $v.rows.Count -ge 5)
Test-Exports 'My PC' 'pcspecs/1' $v.rows.Count

if ($back) { $back.Close(); $back.Dispose() }
