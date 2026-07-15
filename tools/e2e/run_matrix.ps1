# run_matrix.ps1 - Slate window-morph regression matrix (rounds 1-8 distilled).
# Usage: powershell -NoProfile -File tools\e2e\run_matrix.ps1 [-Exe path] [-Scenario S1,S5]
# Drives the REAL desktop for ~2 minutes: launches Slate + Notepad, sends hotkeys.

param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\..\Releases\slate_v1.0.4\slate.exe'),
  [string[]]$Scenario
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SlateE2E.psm1') -Force

$Exe = (Resolve-Path $Exe).Path
$R0 = [pscustomobject]@{ Left = 150; Top = 80; Right = 1150; Bottom = 700 }
$script:slate = [IntPtr]::Zero
$script:notepad = [IntPtr]::Zero
$script:pillRef = $null
$script:pixelsEnabled = $true

function Refresh-Slate {
  $script:slate = Get-SlateHwnd
  $script:slate
}

function Wait-SlateWindow([int]$timeoutMs = 20000) {
  [void](Wait-Until {
    $h = Refresh-Slate
    ($h -ne [IntPtr]::Zero) -and (Get-WinState $h).Visible
  } $timeoutMs 100)
  Refresh-Slate
}

function Reset-Base {
  $h = Refresh-Slate
  if ($h -eq [IntPtr]::Zero) { throw 'Slate window not found' }
  if ((Get-WinState $h).Topmost) {
    Send-Escape
    [void](Wait-Until { -not (Get-WinState $script:slate).Topmost } 5000)
  }
  if (-not (Get-WinState $h).Visible) {
    Open-SlateViaShowRequest $h
    [void](Wait-Until { (Get-WinState $script:slate).Visible } 5000)
  }
  [void][SlateE2E.Native]::ShowWindow($h, 9)   # SW_RESTORE
  Start-Sleep -Milliseconds 200
  if ((Get-WinState $h).Zoomed) {
    [void][SlateE2E.Native]::ShowWindow($h, 9)
    Start-Sleep -Milliseconds 200
  }
  [void][SlateE2E.Native]::SetWindowPos($h, [IntPtr]::Zero,
    $R0.Left, $R0.Top, ($R0.Right - $R0.Left), ($R0.Bottom - $R0.Top), 0x14)
  Start-Sleep -Milliseconds 200
  if (-not (Test-RectNear $h $R0)) { throw "Reset-Base: rect did not land at R0" }
}

function Format-Sample($s) {
  "t=$($s.T)ms rect=($($s.Left),$($s.Top),$($s.Right),$($s.Bottom)) vis=$($s.Visible) icon=$($s.Iconic) zoom=$($s.Zoomed) cloak=$($s.Cloaked) top=$($s.Topmost) fg=$($s.Foreground) above=$($s.AboveNotepad) a=$($s.Alpha)"
}

function Add-SampleFails($fails, $bad, [string]$label, [int]$show = 2) {
  if ($bad.Count -gt 0) {
    $fails.Add("$label ($($bad.Count) samples)")
    $bad | Select-Object -First $show | ForEach-Object { $fails.Add("    " + (Format-Sample $_)) }
  }
}

# The pill's opaque interior, center-bottom of the work area. Compared across
# scenarios against the S1 reference - Win32 flags can be green while the
# render is garbage (round 8: a pill shrunk into the corner passed 24 rect asserts).
function Assert-PillPixels($f, [string]$phase) {
  if (-not $script:pixelsEnabled) { return }
  $wa = Get-WorkArea
  $rect = New-Object Drawing.Rectangle(([int](($wa.Left + $wa.Right) / 2) - 150), ($wa.Bottom - 96), 300, 36)
  $bmp = Get-ScreenBitmap
  try {
    if (Test-BitmapUniform $bmp) {
      $script:pixelsEnabled = $false
      Write-Host '  (uniform screen - headless session, pixel asserts disabled)'
      return
    }
    $crop = $bmp.Clone($rect, $bmp.PixelFormat)
    if ($null -eq $script:pillRef) { $script:pillRef = $crop; return }
    try {
      $mad = Get-CropMAD $script:pillRef $crop
      if ($mad -gt 18) {
        $f.Add("pill PIXELS wrong ($phase): MAD=$([math]::Round($mad,1)) vs S1 reference - pill missing/displaced/stale-rendered")
      }
    } finally { $crop.Dispose() }
  } finally { $bmp.Dispose() }
}

# ---------- scenarios ----------

function Scenario-S1 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  if (-not (Set-ForegroundReliable $script:slate)) { $f.Add('setup: could not focus Slate') }
  $wa = Get-WorkArea
  $smp = Start-Sampler $script:slate $script:notepad
  if (-not (Send-Summon $script:slate)) { $f.Add('summon: pill never reached work-area topmost') }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 1500)) { $f.Add('summon: Slate not foreground') }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S1 reference'
  Send-Escape
  if (-not (Wait-Until { (-not (Get-WinState $script:slate).Topmost) -and (Test-RectNear $script:slate $R0) } 5000)) {
    $f.Add("dismiss: window did not return to R0 (now: $(Format-Sample (Get-WinState $script:slate)))")
  }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 2000)) { $f.Add('dismiss: focus did not return to Slate') }
  Start-Sleep -Milliseconds 300
  $t = Stop-Sampler $smp
  Add-SampleFails $f @($t | Where-Object { -not $_.Visible }) 'window hid during a visible morph'
  $stray = @($t | Where-Object { -not ((Test-SampleRectNear $_ $R0) -or (Test-SampleRectNear $_ $wa)) })
  Add-SampleFails $f $stray 'intermediate rect seen (non-atomic morph)'
  $f
}

function Scenario-S2 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  if (-not (Set-ForegroundReliable $script:notepad)) { $f.Add('setup: could not focus Notepad') }
  $smp = Start-Sampler $script:slate $script:notepad
  if (-not (Send-Summon $script:slate)) { $f.Add('summon: pill never appeared over Notepad') }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S2 behind-Notepad'
  Send-Escape
  if (-not (Wait-Until { (-not (Get-WinState $script:slate).Topmost) -and (Test-RectNear $script:slate $R0) } 5000)) {
    $f.Add('dismiss: window did not return to R0')
  }
  if (-not (Wait-Until { [SlateE2E.Native]::GetForegroundWindow() -eq $script:notepad } 2500)) {
    $f.Add('dismiss: focus did not return to Notepad')
  }
  Start-Sleep -Milliseconds 300
  if (Test-AboveOf $script:slate $script:notepad) { $f.Add('dismiss: Slate ended ABOVE Notepad (anchor broken)') }
  $t = Stop-Sampler $smp
  $flash = @($t | Where-Object { (Test-SampleRectNear $_ $R0) -and $_.AboveNotepad })
  Add-SampleFails $f $flash 'restored Slate flashed above Notepad'
  $f
}

function Scenario-S3 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  [void][SlateE2E.Native]::ShowWindow($script:slate, 3)  # SW_MAXIMIZE
  Start-Sleep -Milliseconds 250
  if (-not (Set-ForegroundReliable $script:slate)) { $f.Add('setup: could not focus maximized Slate') }
  $smp = Start-Sampler $script:slate $script:notepad
  Send-Chord $false   # in-app path gives no pill; plain chord, no fallback probing
  Start-Sleep -Milliseconds 800
  Send-Escape
  Start-Sleep -Milliseconds 500
  $t = Stop-Sampler $smp
  Add-SampleFails $f @($t | Where-Object { -not $_.Zoomed }) 'window left maximized state during in-app capture'
  Add-SampleFails $f @($t | Where-Object { $_.Topmost }) 'window went topmost during in-app capture'
  $s = Get-WinState $script:slate
  if (-not $s.Zoomed) { $f.Add('end: not maximized') }
  if (-not $s.Foreground) { $f.Add('end: not foreground') }
  $f
}

function Scenario-S4 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  [void][SlateE2E.Native]::ShowWindow($script:slate, 3)
  Start-Sleep -Milliseconds 250
  if (-not (Set-ForegroundReliable $script:notepad)) { $f.Add('setup: could not focus Notepad') }
  $smp = Start-Sampler $script:slate $script:notepad
  if (-not (Send-Summon $script:slate)) { $f.Add('summon: pill never appeared (maximized-behind entry)') }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S4 maximized-behind'
  Send-Escape
  if (-not (Wait-Until { (Get-WinState $script:slate).Zoomed } 5000)) { $f.Add('dismiss: window not re-maximized') }
  if (-not (Wait-Until { [SlateE2E.Native]::GetForegroundWindow() -eq $script:notepad } 2500)) {
    $f.Add('dismiss: focus did not return to Notepad')
  }
  Start-Sleep -Milliseconds 300
  if (Test-AboveOf $script:slate $script:notepad) { $f.Add('dismiss: Slate ended ABOVE Notepad') }
  $t = Stop-Sampler $smp
  # alpha <=16 = effectively invisible (the restore re-maximizes at alpha 1/255 before sinking)
  $flash = @($t | Where-Object { $_.Zoomed -and $_.AboveNotepad -and ($_.Alpha -gt 16) -and (-not $_.Cloaked) })
  Add-SampleFails $f $flash 'maximized Slate flashed above Notepad during restore'
  $f
}

function Scenario-S5 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  [void][SlateE2E.Native]::ShowWindow($script:slate, 6)  # SW_MINIMIZE
  Start-Sleep -Milliseconds 350
  $smp = Start-Sampler $script:slate $script:notepad
  if (-not (Send-Summon $script:slate)) { $f.Add('summon: pill never appeared from minimized') }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S5 minimized'
  Send-Escape
  if (-not (Wait-Until { (Get-WinState $script:slate).Iconic } 5000)) { $f.Add('dismiss: window not re-minimized') }
  Start-Sleep -Milliseconds 400
  $t = Stop-Sampler $smp
  $p = Get-Placement $script:slate
  if ([math]::Abs($p.normalPosition.Left - $R0.Left) -ge 3 -or [math]::Abs($p.normalPosition.Top - $R0.Top) -ge 3) {
    $f.Add("placement rcNormal lost R0: ($($p.normalPosition.Left),$($p.normalPosition.Top))")
  }
  $flash = @($t | Where-Object { $_.Visible -and (-not $_.Cloaked) -and (-not $_.Iconic) -and ($_.Alpha -gt 16) -and (Test-SampleRectNear $_ $R0) })
  Add-SampleFails $f $flash 'uncloaked window shown at prior rect (dismiss flash)'
  $f
}

function Scenario-S6 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  [void][SlateE2E.Native]::ShowWindow($script:slate, 3)
  Start-Sleep -Milliseconds 250
  [void][SlateE2E.Native]::ShowWindow($script:slate, 6)
  Start-Sleep -Milliseconds 350
  if (-not (Send-Summon $script:slate)) {
    $f.Add("summon: pill never appeared from minimized-from-maximized (now: $(Format-Sample (Get-WinState $script:slate)))")
  }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S6 min-from-max'
  Send-Escape
  if (-not (Wait-Until { (Get-WinState $script:slate).Iconic } 5000)) { $f.Add('dismiss: window not re-minimized') }
  Start-Sleep -Milliseconds 300
  $p = Get-Placement $script:slate
  if (($p.flags -band 0x2) -eq 0) { $f.Add('placement lost WPF_RESTORETOMAXIMIZED') }
  [void][SlateE2E.Native]::ShowWindow($script:slate, 9)  # external restore
  if (-not (Wait-Until { (Get-WinState $script:slate).Zoomed } 3000)) { $f.Add('external restore did not come back maximized') }
  $f
}

function Scenario-S7 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  Hide-SlateToTray $script:slate
  if (-not (Wait-Until { -not (Get-WinState $script:slate).Visible } 4000)) { $f.Add('setup: WM_CLOSE did not hide to tray') }
  if (-not (Set-ForegroundReliable $script:notepad)) { $f.Add('setup: could not focus Notepad') }
  $smp = Start-Sampler $script:slate $script:notepad
  if (-not (Send-Summon $script:slate)) { $f.Add('summon: pill never appeared from tray-hidden') }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S7 tray-hidden (user main case)'
  Send-Escape
  if (-not (Wait-Until { -not (Get-WinState $script:slate).Visible } 5000)) { $f.Add('dismiss: window did not go back to tray') }
  Start-Sleep -Milliseconds 300
  $t = Stop-Sampler $smp
  $flash = @($t | Where-Object { $_.Visible -and (-not $_.Cloaked) -and ($_.Alpha -gt 16) -and (Test-SampleRectNear $_ $R0) })
  Add-SampleFails $f $flash 'hidden-prior window flashed at prior rect'
  Open-SlateViaShowRequest $script:slate
  if (-not (Wait-Until { (Get-WinState $script:slate).Visible -and (Test-RectNear $script:slate $R0) } 5000)) {
    $f.Add("open: window not visible at R0 (now: $(Format-Sample (Get-WinState $script:slate)))")
  }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 2500)) { $f.Add('open: Slate not foreground (bug 2)') }
  if (-not (Test-AboveOf $script:slate $script:notepad)) { $f.Add('open: Slate under Notepad (bug 2)') }
  $f
}

function Scenario-S8 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  [void][SlateE2E.Native]::ShowWindow($script:slate, 3)
  Start-Sleep -Milliseconds 250
  Hide-SlateToTray $script:slate
  if (-not (Wait-Until { -not (Get-WinState $script:slate).Visible } 4000)) { $f.Add('setup: WM_CLOSE did not hide') }
  if (-not (Send-Summon $script:slate)) {
    $f.Add("summon: pill never appeared from hidden-while-maximized (now: $(Format-Sample (Get-WinState $script:slate)))")
  }
  Start-Sleep -Milliseconds 400
  Assert-PillPixels $f 'S8 hidden-from-max'
  Send-Escape
  if (-not (Wait-Until { -not (Get-WinState $script:slate).Visible } 5000)) { $f.Add('dismiss: window did not go back to tray') }
  Open-SlateViaShowRequest $script:slate
  if (-not (Wait-Until { (Get-WinState $script:slate).Visible -and (Get-WinState $script:slate).Zoomed } 5000)) {
    $f.Add('open: window did not come back maximized')
  }
  $f
}

function Scenario-L1 {
  $f = New-Object Collections.Generic.List[string]
  Request-SlateQuit $script:slate
  if (-not (Wait-Until { @(Get-Process slate -ErrorAction SilentlyContinue).Count -eq 0 } 8000 200)) {
    $f.Add('setup: instance did not quit'); return $f
  }
  [void](Set-ForegroundReliable $script:notepad)
  Start-Process $Exe | Out-Null
  $h = Wait-SlateWindow 25000
  if ($h -eq [IntPtr]::Zero) { $f.Add('launch: window never appeared'); return $f }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 10000 100)) { $f.Add('launch: Slate not foreground (bug 2)') }
  if (-not (Test-AboveOf $script:slate $script:notepad)) { $f.Add('launch: Slate under Notepad (bug 2)') }
  Start-Sleep -Milliseconds 500
  $f
}

function Scenario-L2 {
  $f = New-Object Collections.Generic.List[string]
  $old = @(Get-Process slate -ErrorAction SilentlyContinue)
  if ($old.Count -eq 0) { $f.Add('setup: no running instance'); return $f }
  [void](Set-ForegroundReliable $script:notepad)
  Start-Process $Exe | Out-Null
  $oldIds = $old | ForEach-Object { $_.Id }
  if (-not (Wait-Until {
      $left = @(Get-Process slate -ErrorAction SilentlyContinue | Where-Object { $oldIds -contains $_.Id })
      $left.Count -eq 0
    } 6000 200)) { $f.Add('handover: old instance still alive after 6s') }
  $h = Wait-SlateWindow 25000
  if ($h -eq [IntPtr]::Zero) { $f.Add('handover: new window never appeared'); return $f }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 10000 100)) { $f.Add('handover: Slate not foreground (bug 2)') }
  if (-not (Test-AboveOf $script:slate $script:notepad)) { $f.Add('handover: Slate under Notepad (bug 2)') }
  Start-Sleep -Milliseconds 500
  $f
}

function Scenario-L3 {
  $f = New-Object Collections.Generic.List[string]
  Reset-Base
  if (-not (Set-ForegroundReliable $script:notepad)) { $f.Add('setup: could not focus Notepad') }
  if (-not (Send-Summon $script:slate)) { $f.Add('summon failed') }
  Start-Sleep -Milliseconds 300
  Send-Escape
  if (-not (Wait-Until { (-not (Get-WinState $script:slate).Topmost) -and (Test-RectNear $script:slate $R0) } 5000)) {
    $f.Add('dismiss: window did not return to R0')
  }
  [void](Wait-Until { [SlateE2E.Native]::GetForegroundWindow() -eq $script:notepad } 2500)
  Open-SlateViaShowRequest $script:slate
  if (-not (Wait-Until { (Get-WinState $script:slate).Visible } 4000)) { $f.Add('open: not visible') }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 2500)) { $f.Add('open: Slate not foreground (bug 2 core)') }
  if (-not (Test-AboveOf $script:slate $script:notepad)) { $f.Add('open: Slate under Notepad (bug 2 core)') }
  $f
}

function Scenario-SR1 {
  $f = New-Object Collections.Generic.List[string]
  for ($i = 1; $i -le 5; $i++) {
    Reset-Base
    [void](Set-ForegroundReliable $script:notepad)
    if (-not (Send-Summon $script:slate)) { $f.Add("soak S2 #${i}: summon failed"); break }
    Start-Sleep -Milliseconds 150
    Send-Escape
    if (-not (Wait-Until { (-not (Get-WinState $script:slate).Topmost) -and (Test-RectNear $script:slate $R0) } 5000)) {
      $f.Add("soak S2 #${i}: restore failed"); break
    }
  }
  for ($i = 1; $i -le 5; $i++) {
    Reset-Base
    [void][SlateE2E.Native]::ShowWindow($script:slate, 6)
    Start-Sleep -Milliseconds 300
    if (-not (Send-Summon $script:slate)) { $f.Add("soak S5 #${i}: summon failed"); break }
    Start-Sleep -Milliseconds 150
    if ($i -eq 1) { Assert-PillPixels $f "soak S5 #${i}" }
    Send-Escape
    if (-not (Wait-Until { (Get-WinState $script:slate).Iconic } 5000)) { $f.Add("soak S5 #${i}: re-minimize failed"); break }
  }
  # hotkey mid-dismiss: legal outcomes are a replayed pill (press landed during
  # restore) or a clean toggle-dismiss (press landed during the exit animation).
  # Illegal: a zombie - neither pill nor a healthy window at R0.
  Reset-Base
  [void](Set-ForegroundReliable $script:slate)
  if (Send-Summon $script:slate) {
    Send-Escape
    Start-Sleep -Milliseconds 60
    Send-SummonChord
    Start-Sleep -Milliseconds 1500
    if (Test-PillUp $script:slate) {
      Send-Escape
      if (-not (Wait-Until { (-not (Get-WinState $script:slate).Topmost) -and (Test-RectNear $script:slate $R0) } 5000)) {
        $f.Add('replayed pill did not dismiss cleanly')
      }
    } elseif (-not (Wait-Until { (-not (Get-WinState $script:slate).Topmost) -and (Test-RectNear $script:slate $R0) -and (Get-WinState $script:slate).Visible } 5000)) {
      $f.Add("mid-dismiss hotkey left a zombie (now: $(Format-Sample (Get-WinState $script:slate)))")
    }
  } else { $f.Add('replay setup: first summon failed') }
  $f
}

# ---------- orchestration ----------

Write-Host "Slate e2e matrix - exe: $Exe"
Write-Host "This run drives the real desktop (~2 min): Slate + Notepad windows, global hotkeys."

$notepadProc = Start-Process notepad -PassThru
[void](Wait-Until { $notepadProc.Refresh(); $notepadProc.MainWindowHandle -ne [IntPtr]::Zero } 5000 100)
$script:notepad = $notepadProc.MainWindowHandle
[void][SlateE2E.Native]::SetWindowPos($script:notepad, [IntPtr]::Zero, 120, 120, 900, 520, 0x14)

Start-Process $Exe | Out-Null   # newest-wins handover replaces any running instance
$h = Wait-SlateWindow 30000
if ($h -eq [IntPtr]::Zero) { Write-Host 'FATAL: Slate window never appeared'; exit 2 }
Start-Sleep -Milliseconds 1500  # let engine + hotkey registration settle

$scenarios = [ordered]@{
  S1 = { Scenario-S1 }; S2 = { Scenario-S2 }; S3 = { Scenario-S3 }; S4 = { Scenario-S4 }
  S5 = { Scenario-S5 }; S6 = { Scenario-S6 }; S7 = { Scenario-S7 }; S8 = { Scenario-S8 }
  L1 = { Scenario-L1 }; L2 = { Scenario-L2 }; L3 = { Scenario-L3 }; SR1 = { Scenario-SR1 }
}

$results = [ordered]@{}
foreach ($name in $scenarios.Keys) {
  if ($Scenario -and ($Scenario -notcontains $name)) { continue }
  Write-Host ("--- {0} ---" -f $name)
  try {
    $fails = @(& $scenarios[$name])
  } catch {
    $fails = @("scenario crashed: $($_.Exception.Message)")
  }
  $results[$name] = $fails
  if ($fails.Count -eq 0) { Write-Host "$name PASS" }
  else { Write-Host "$name FAIL"; $fails | ForEach-Object { Write-Host "  - $_" } }
}

# cleanup: leave the deployed instance resident in the tray, close Notepad
try {
  Reset-Base
  Hide-SlateToTray $script:slate
} catch {}
try { Stop-Process -Id $notepadProc.Id -Force -Confirm:$false } catch {}

Write-Host ''
Write-Host '==== SUMMARY ===='
$failCount = 0
foreach ($name in $results.Keys) {
  $status = 'PASS'
  if ($results[$name].Count -gt 0) { $status = 'FAIL'; $failCount++ }
  Write-Host ("{0,-5} {1}" -f $name, $status)
}
if ($failCount -gt 0) { Write-Host "$failCount scenario(s) failed"; exit 1 }
Write-Host 'All scenarios passed'
exit 0
