# run_matrix.ps1 - Slate SEPARATE-PILL-WINDOW regression matrix (v1.0.6+).
# Usage: powershell -NoProfile -File tools\e2e\run_matrix.ps1 [-Exe path] [-Scenario P1,P4]
#
# The pill is its own always-on-top window now, independent of the main window,
# so the whole rounds 1-8 morph matrix is retired. The invariant these check:
# the MAIN window is never touched, and the pill shows/hides instantly over
# whatever app is in front, from any main-window state.

param(
  # The freshly built binary. The old default pointed at Releases\slate_v1.0.6,
  # which the retention rule deletes — the matrix could not start at all.
  [string]$Exe = (Join-Path $PSScriptRoot '..\..\build\windows\x64\runner\Release\slate.exe'),
  [string[]]$Scenario
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SlateE2E.psm1') -Force

$Exe = (Resolve-Path $Exe).Path
$R0 = [pscustomobject]@{ Left = 150; Top = 80; Right = 1150; Bottom = 700 }
$script:slate = [IntPtr]::Zero
$script:notepad = [IntPtr]::Zero

function Refresh-Slate { $script:slate = Get-SlateHwnd; $script:slate }

function Wait-SlateWindow([int]$timeoutMs = 20000) {
  [void](Wait-Until { $h = Refresh-Slate; ($h -ne [IntPtr]::Zero) -and (Get-WinState $h).Visible } $timeoutMs 100)
  Refresh-Slate
}

function Reset-MainWindowed {
  $h = Refresh-Slate
  if ($h -eq [IntPtr]::Zero) { throw 'Slate main window not found' }
  if (-not (Get-WinState $h).Visible) {
    Open-SlateViaShowRequest $h
    [void](Wait-Until { (Get-WinState $script:slate).Visible } 5000)
  }
  [void][SlateE2E.Native]::ShowWindow($h, 9)  # SW_RESTORE
  Start-Sleep -Milliseconds 200
  [void][SlateE2E.Native]::SetWindowPos($h, [IntPtr]::Zero, $R0.Left, $R0.Top,
    ($R0.Right - $R0.Left), ($R0.Bottom - $R0.Top), 0x14)
  Start-Sleep -Milliseconds 200
}

function Fmt($s) { "vis=$($s.Visible) icon=$($s.Iconic) zoom=$($s.Zoomed) rect=($($s.Left),$($s.Top),$($s.Right),$($s.Bottom))" }

# The pill window should cover the cursor monitor work area.
function Assert-PillAtWorkArea($f) {
  $wa = Get-WorkArea
  $r = [pscustomobject]@{ Left = $wa.Left; Top = $wa.Top; Right = $wa.Right; Bottom = $wa.Bottom }
  if (-not (Test-RectNear (Get-PillHwnd) $r 4)) {
    $f.Add("pill not at work area (pill: $(Fmt (Get-WinState (Get-PillHwnd))))")
  }
}

# ---------- scenarios ----------

# Pill summons + dismisses cleanly and the MAIN window is byte-identical after.
function Test-MainUntouched($f, $label) {
  $before = Get-WinState $script:slate
  if (-not (Send-PillHotkey)) { $f.Add("$label summon: pill never showed"); return }
  Assert-PillAtWorkArea $f
  Start-Sleep -Milliseconds 300
  $during = Get-WinState $script:slate
  if (-not (Test-SampleRectNear $during $before 3) -or ($during.Zoomed -ne $before.Zoomed) -or ($during.Iconic -ne $before.Iconic)) {
    $f.Add("$label MAIN WINDOW MOVED during pill (before: $(Fmt $before) / during: $(Fmt $during))")
  }
  Send-Escape
  if (-not (Wait-Until { -not (Test-PillVisible) } 4000)) { $f.Add("$label dismiss: pill still visible after Esc") }
  Start-Sleep -Milliseconds 200
  $after = Get-WinState $script:slate
  if (-not (Test-SampleRectNear $after $before 3) -or ($after.Zoomed -ne $before.Zoomed) -or ($after.Iconic -ne $before.Iconic)) {
    $f.Add("$label MAIN WINDOW CHANGED after pill (before: $(Fmt $before) / after: $(Fmt $after))")
  }
}

function Scenario-P1 {  # main tray-hidden
  $f = New-Object Collections.Generic.List[string]
  Reset-MainWindowed
  Hide-SlateToTray $script:slate
  [void](Wait-Until { -not (Get-WinState $script:slate).Visible } 4000)
  if (-not (Set-ForegroundReliable $script:notepad)) { $f.Add('setup: notepad focus') }
  if (-not (Send-PillHotkey)) { $f.Add('summon: pill never showed from tray-hidden') }
  Assert-PillAtWorkArea $f
  Send-Escape
  if (-not (Wait-Until { -not (Test-PillVisible) } 4000)) { $f.Add('dismiss: pill still visible') }
  if ((Get-WinState $script:slate).Visible) { $f.Add('main window got shown by the pill') }
  $f
}

function Scenario-P2 { $f = New-Object Collections.Generic.List[string]; Reset-MainWindowed; [void](Set-ForegroundReliable $script:slate); Test-MainUntouched $f 'windowed-focused'; $f }

function Scenario-P3 {  # main maximized
  $f = New-Object Collections.Generic.List[string]
  Reset-MainWindowed
  [void][SlateE2E.Native]::ShowWindow($script:slate, 3)
  Start-Sleep -Milliseconds 300
  [void](Set-ForegroundReliable $script:slate)
  Test-MainUntouched $f 'maximized'
  if (-not (Get-WinState $script:slate).Zoomed) { $f.Add('main not maximized at end') }
  $f
}

function Scenario-P4 {  # behind Notepad -> focus returns to Notepad
  $f = New-Object Collections.Generic.List[string]
  Reset-MainWindowed
  if (-not (Set-ForegroundReliable $script:notepad)) { $f.Add('setup: notepad focus') }
  if (-not (Send-PillHotkey)) { $f.Add('summon: pill never showed behind Notepad') }
  Assert-PillAtWorkArea $f
  Send-Escape
  if (-not (Wait-Until { -not (Test-PillVisible) } 4000)) { $f.Add('dismiss: pill still visible') }
  if (-not (Wait-Until { [SlateE2E.Native]::GetForegroundWindow() -eq $script:notepad } 2500)) {
    $f.Add('dismiss: focus did not return to Notepad')
  }
  $f
}

function Scenario-P5 {  # toggle: hotkey again dismisses
  $f = New-Object Collections.Generic.List[string]
  Reset-MainWindowed
  [void](Set-ForegroundReliable $script:notepad)
  if (-not (Send-PillHotkey)) { $f.Add('summon failed'); return $f }
  Start-Sleep -Milliseconds 300
  Send-SummonChord  # second press = toggle off
  if (-not (Wait-Until { -not (Test-PillVisible) } 3000)) { $f.Add('toggle: pill did not dismiss on repeat hotkey') }
  $f
}

function Scenario-P6 {  # open main -> foreground + above Notepad (bug 2)
  $f = New-Object Collections.Generic.List[string]
  Reset-MainWindowed
  Hide-SlateToTray $script:slate
  [void](Wait-Until { -not (Get-WinState $script:slate).Visible } 4000)
  [void](Set-ForegroundReliable $script:notepad)
  Open-SlateViaShowRequest $script:slate
  if (-not (Wait-Until { (Get-WinState $script:slate).Visible } 5000)) { $f.Add('open: main not visible') }
  if (-not (Wait-Until { (Get-WinState $script:slate).Foreground } 2500)) { $f.Add('open: main not foreground (bug 2)') }
  if (-not (Test-AboveOf $script:slate $script:notepad)) { $f.Add('open: main under Notepad (bug 2)') }
  $f
}

function Scenario-P7 {  # newest-wins handover
  $f = New-Object Collections.Generic.List[string]
  $old = @(Get-Process slate -ErrorAction SilentlyContinue)
  if ($old.Count -eq 0) { $f.Add('setup: no running instance'); return $f }
  Start-Process $Exe | Out-Null
  $oldIds = $old | ForEach-Object { $_.Id }
  if (-not (Wait-Until { (@(Get-Process slate -ErrorAction SilentlyContinue | Where-Object { $oldIds -contains $_.Id })).Count -eq 0 } 6000 200)) {
    $f.Add('handover: old instance alive after 6s')
  }
  Start-Sleep -Milliseconds 1500
  if ((Get-Process slate -ErrorAction SilentlyContinue).Count -eq 0) { $f.Add('handover: no instance after') }
  $f
}

# ---------- orchestration ----------

Write-Host "Slate pill-window matrix - exe: $Exe"
Write-Host "Drives the real desktop (~1 min): Slate + Notepad, global hotkeys."

$notepadProc = Start-Process notepad -PassThru
[void](Wait-Until { $notepadProc.Refresh(); $notepadProc.MainWindowHandle -ne [IntPtr]::Zero } 5000 100)
$script:notepad = $notepadProc.MainWindowHandle
[void][SlateE2E.Native]::SetWindowPos($script:notepad, [IntPtr]::Zero, 120, 120, 900, 520, 0x14)

Start-Process $Exe | Out-Null
$h = Wait-SlateWindow 30000
if ($h -eq [IntPtr]::Zero) {
  # maybe launched --hidden by a prior run; poke it open
  Start-Process $Exe | Out-Null
  $h = Wait-SlateWindow 20000
}
Start-Sleep -Milliseconds 1500

$scenarios = [ordered]@{
  P1 = { Scenario-P1 }; P2 = { Scenario-P2 }; P3 = { Scenario-P3 }; P4 = { Scenario-P4 }
  P5 = { Scenario-P5 }; P6 = { Scenario-P6 }; P7 = { Scenario-P7 }
}

$results = [ordered]@{}
foreach ($name in $scenarios.Keys) {
  if ($Scenario -and ($Scenario -notcontains $name)) { continue }
  Write-Host ("--- {0} ---" -f $name)
  try { $fails = @(& $scenarios[$name]) } catch { $fails = @("crashed: $($_.Exception.Message)") }
  $results[$name] = $fails
  if ($fails.Count -eq 0) { Write-Host "$name PASS" } else { Write-Host "$name FAIL"; $fails | ForEach-Object { Write-Host "  - $_" } }
}

try { Stop-Process -Id $notepadProc.Id -Force -Confirm:$false } catch {}
Write-Host ''
Write-Host '==== SUMMARY ===='
$failCount = 0
foreach ($name in $results.Keys) {
  $status = if ($results[$name].Count -gt 0) { $failCount++; 'FAIL' } else { 'PASS' }
  Write-Host ("{0,-4} {1}" -f $name, $status)
}
if ($failCount -gt 0) { Write-Host "$failCount scenario(s) failed"; exit 1 }
Write-Host 'All scenarios passed'
exit 0
