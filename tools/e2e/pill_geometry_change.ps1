# pill_geometry_change.ps1 - the display moved under the pill. Does it survive?
#
# The bug this guards (2026-07-23, v1.1.5): the pill window is created ONCE,
# sized to the work area at startup, and never revisits that. ShowPill then
# resizes it right before showing it -- and a resize is only honoured by an
# engine that is actively PRESENTING. A hidden, idle engine ignores it and
# keeps the old viewport, so the pill paints into a 640x480 box inside a
# 1366x768 window: the "stretched slab in the corner" the user hit every boot.
# It never healed by itself, because the next summon asked for the same size.
#
# It fires on any post-startup geometry change. On the author's machine that is
# Parsec: the physical monitor is broken, the desktop is streamed to a laptop,
# and Parsec switches the host resolution AFTER autostart has built the pill.
# For a tester it will be a monitor hotplug, an RDP session or a DPI change.
#
# HOW THE MISMATCH IS SIMULATED - AND WHY NOT BY SWITCHING RESOLUTION:
# an earlier version of this script called ChangeDisplaySettings. On a machine
# driven through Parsec that KILLS the remote session - the user lost his
# screen entirely and had to reboot the box to get back in. Never switch
# display modes from a test here. Resizing the pill's own hidden window
# reproduces exactly the same state and touches nothing else.
#
# Usage: powershell -NoProfile -File tools\e2e\pill_geometry_change.ps1 [-Exe path]

param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\..\build\windows\x64\runner\Release\slate.exe'),
  [switch]$NoLaunch,
  [string]$OutDir = $env:TEMP
)

$ErrorActionPreference = 'Stop'
$pixels = Join-Path $PSScriptRoot 'pill_pixels.ps1'

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class Geo {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);

  public static IntPtr Pill() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "SlatePill"); }
  public static bool Visible() { IntPtr h = Pill(); return h != IntPtr.Zero && IsWindowVisible(h); }
  public static string R(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    return string.Format("{0},{1}-{2},{3} [{4}x{5}]", r.left,r.top,r.right,r.bottom,r.right-r.left,r.bottom-r.top);
  }
  /// Leave the pill sized for a screen that no longer exists - exactly the
  /// state a post-startup resolution change produces.
  public static void Mismatch(IntPtr h, int w, int hh) {
    SetWindowPos(h, IntPtr.Zero, 0, 0, w, hh, 0x0002|0x0004|0x0010); // NOMOVE|NOZORDER|NOACTIVATE
  }
}
'@

function Wait-PillDown([int]$timeoutMs = 4000) {
  # Each step ends with Esc, and the pill fades out. Starting the next step
  # before it is really down makes the next Alt+Space a TOGGLE-dismiss, which
  # produced an empty frame that looked like a rendering bug but was this
  # harness racing itself.
  $deadline = (Get-Date).AddMilliseconds($timeoutMs)
  while ((Get-Date) -lt $deadline) {
    if (-not [Geo]::Visible()) { Start-Sleep -Milliseconds 400; return $true }
    Start-Sleep -Milliseconds 100
  }
  Write-Host '    (warning: pill still up after the previous step)'
  return $false
}

function Invoke-PixelCheck($label, $shot) {
  Write-Host "--- $label ---"
  & powershell -NoProfile -ExecutionPolicy Bypass -File $pixels -Out $shot | ForEach-Object { Write-Host "    $_" }
  $ok = ($LASTEXITCODE -eq 0)
  Write-Host ("    => {0}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }))
  Write-Host ''
  [void](Wait-PillDown)
  return $ok
}

if (-not $NoLaunch) {
  Write-Host "launching $Exe --hidden (replaces any running instance)"
  Start-Process $Exe -ArgumentList '--hidden' | Out-Null
  $up = $false
  for ($i = 0; $i -lt 100; $i++) { Start-Sleep -Milliseconds 500; if ([Geo]::Pill() -ne [IntPtr]::Zero) { $up = $true; break } }
  if (-not $up) { Write-Host 'FAIL: pill window never appeared'; exit 1 }
  Start-Sleep -Seconds 3
}

$pill = [Geo]::Pill()
if ($pill -eq [IntPtr]::Zero) { Write-Host 'FAIL: no pill window (is Slate running?)'; exit 1 }
Write-Host ("screen        : {0}x{1}" -f [Geo]::GetSystemMetrics(0), [Geo]::GetSystemMetrics(1))
Write-Host ("pill at rest  : {0}" -f [Geo]::R($pill))
Write-Host ''

$results = [ordered]@{}

# G1: nothing moved - the path that always worked.
$results['G1 geometry unchanged'] = Invoke-PixelCheck 'G1: geometry unchanged' (Join-Path $OutDir 'g1_unchanged.png')

# G2: the screen grew under a hidden pill (small window, big screen) - THE bug.
[Geo]::Mismatch($pill, 640, 480)
Start-Sleep -Milliseconds 600
Write-Host ("pill shrunk to: {0}  <- stale, as after a boot-time resolution switch" -f [Geo]::R($pill))
$results['G2 pill left too small'] = Invoke-PixelCheck 'G2: window stale-small, screen large' (Join-Path $OutDir 'g2_too_small.png')

# G3: and the other direction - a window bigger than the screen it lands on.
[Geo]::Mismatch($pill, 1920, 1080)
Start-Sleep -Milliseconds 600
Write-Host ("pill grown to : {0}" -f [Geo]::R($pill))
$results['G3 pill left too big'] = Invoke-PixelCheck 'G3: window stale-big, screen small' (Join-Path $OutDir 'g3_too_big.png')

# G4: back to a stable geometry, the summon after a heal must stay clean.
$results['G4 repeat summon'] = Invoke-PixelCheck 'G4: summon again, geometry stable' (Join-Path $OutDir 'g4_repeat.png')

Write-Host '==== SUMMARY ===='
$fail = 0
foreach ($k in $results.Keys) {
  if (-not $results[$k]) { $fail++ }
  Write-Host ("{0,-24} {1}" -f $k, $(if ($results[$k]) { 'PASS' } else { 'FAIL' }))
}
Write-Host ''
Write-Host "frames written to $OutDir - LOOK at them. The machine only asserts that"
Write-Host "the pill came up and fills the work area; whether the capsule is a ~600 px"
Write-Host "band, centred, ~48 px off the bottom is a human/agent call on the PNGs."
if ($fail -gt 0) { Write-Host "$fail step(s) failed"; exit 1 }
Write-Host 'All geometry-change steps passed'
exit 0
