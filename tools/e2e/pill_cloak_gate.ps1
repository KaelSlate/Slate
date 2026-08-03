# pill_cloak_gate.ps1 - is the pill window CLOAKED for the whole vulnerable gap?
#
# pill_flash.ps1 measures the symptom, and the symptom is a coin flip (~4% of
# summons), so a clean run there is weak evidence on its own. This measures the
# INVARIANT instead, and that is deterministic:
#
#   from the moment the window becomes visible until Flutter has painted it,
#   the window must be cloaked - DWM then composites nothing at all, so the
#   class brush GDI leaves at alpha 0 can never be added to the desktop.
#
# Every summon must show a stretch of visible+cloaked, then uncloak. On a build
# WITHOUT the fix this fails on the first summon: cloaked is never set.
#
# Usage: powershell -NoProfile -File tools\e2e\pill_cloak_gate.ps1 [-Trials 12]

param(
  [int]$Trials = 12,
  [int]$MaxCloakMs = 250   # the 150 ms belt in pill_window.cpp, plus slack
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public class Gate {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

  const byte VK_MENU = 0x12, VK_SPACE = 0x20, VK_ESCAPE = 0x1B;
  const uint KEYUP = 0x0002;
  const int DWMWA_CLOAKED = 14;

  public static IntPtr Pill() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "SlatePill"); }
  public static bool Visible() { IntPtr h = Pill(); return h != IntPtr.Zero && IsWindowVisible(h); }
  public static bool Cloaked() {
    IntPtr h = Pill();
    if (h == IntPtr.Zero) return false;
    int v;
    if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out v, sizeof(int)) != 0) return false;
    return v != 0;
  }
  public static void Summon() {
    keybd_event(VK_MENU, 0, 0, IntPtr.Zero); keybd_event(VK_SPACE, 0, 0, IntPtr.Zero);
    keybd_event(VK_SPACE, 0, KEYUP, IntPtr.Zero); keybd_event(VK_MENU, 0, KEYUP, IntPtr.Zero);
  }
  public static void Escape() {
    keybd_event(VK_ESCAPE, 0, 0, IntPtr.Zero); keybd_event(VK_ESCAPE, 0, KEYUP, IntPtr.Zero);
  }

  public static double CloakedMs;      // visible AND cloaked
  public static double NakedBeforeMs;  // visible and NOT cloaked before any cloak was seen
  public static bool SawGate;

  /// Poll visible/cloaked from just before the hotkey until well past the show.
  public static void Watch(int windowMs) {
    Stopwatch sw = Stopwatch.StartNew();
    CloakedMs = 0; NakedBeforeMs = 0; SawGate = false;
    bool cloakSeen = false;
    double last = 0;
    Summon();
    while (sw.Elapsed.TotalMilliseconds < windowMs) {
      double now = sw.Elapsed.TotalMilliseconds;
      double dt = now - last; last = now;
      if (Visible()) {
        if (Cloaked()) { CloakedMs += dt; cloakSeen = true; SawGate = true; }
        else if (!cloakSeen) { NakedBeforeMs += dt; }
      }
    }
  }
}
'@

if (-not [Gate]::Pill()) { Write-Host 'FAIL: pill window not found (is Slate running?)'; exit 1 }
if ([Gate]::Visible()) { [Gate]::Escape(); Start-Sleep -Milliseconds 600 }

$fails = New-Object Collections.Generic.List[string]

for ($t = 1; $t -le $Trials; $t++) {
  [Gate]::Watch(400)
  $cloaked = [Gate]::CloakedMs
  $naked = [Gate]::NakedBeforeMs
  $gate = [Gate]::SawGate

  $verdict = 'PASS'
  if (-not $gate) { $verdict = 'FAIL'; $fails.Add("trial ${t}: window was shown UNCLOAKED - the gate never engaged") }
  elseif ($cloaked -gt $MaxCloakMs) { $verdict = 'FAIL'; $fails.Add("trial ${t}: cloaked ${cloaked} ms > ${MaxCloakMs} ms belt") }
  elseif ($naked -gt 4) { $verdict = 'FAIL'; $fails.Add("trial ${t}: ${naked} ms visible+uncloaked BEFORE the gate") }

  Write-Host ("trial {0,2}: {1}   cloaked {2,6:N1} ms   naked-before {3,5:N1} ms" -f $t, $verdict, $cloaked, $naked)

  [Gate]::Escape()
  Start-Sleep -Milliseconds 450
  for ($k = 0; $k -lt 20 -and [Gate]::Visible(); $k++) { [Gate]::Escape(); Start-Sleep -Milliseconds 100 }
}

Write-Host ''
if ($fails.Count -gt 0) {
  Write-Host ("GATE FAIL - {0} of {1} summons" -f $fails.Count, $Trials)
  $fails | Select-Object -First 6 | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Host ("GATE PASS - all {0} summons were composited only after Flutter painted" -f $Trials)
exit 0
