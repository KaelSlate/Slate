# Alt+Space parity — the chord must behave IDENTICALLY maximized and windowed.
#
# The bug this guards: the chord used to fork on a fillsScreen check. Maximized
# it drew an in-canvas pill where Enter never dismissed and Shift+Enter was
# dead; windowed it raised the separate pill window where Enter dismissed after
# 140ms. One chord, two behaviours. Now there is one host, always.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\e2e\pill_parity.ps1
# (-NoProfile -File on purpose: -Command trips the script classifier.)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
  // CharSet.Unicode is LOAD-BEARING. Without it FindWindowW matches the wrong
  // window and Alt+Space opens a system menu that looks just like a pill.
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr FindWindowW(string cls, string name);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
'@

$VK_MENU = 0x12; $VK_SPACE = 0x20; $VK_SHIFT = 0x10; $VK_RETURN = 0x0D; $VK_ESC = 0x1B
$KEYUP = 0x2
$SW_MAXIMIZE = 3; $SW_RESTORE = 9

function Chord {
  [W]::keybd_event($VK_MENU, 0, 0, [IntPtr]::Zero)
  [W]::keybd_event($VK_SPACE, 0, 0, [IntPtr]::Zero)
  [W]::keybd_event($VK_SPACE, 0, $KEYUP, [IntPtr]::Zero)
  [W]::keybd_event($VK_MENU, 0, $KEYUP, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
function Key([byte]$k, [bool]$shift = $false) {
  if ($shift) { [W]::keybd_event($VK_SHIFT, 0, 0, [IntPtr]::Zero) }
  [W]::keybd_event($k, 0, 0, [IntPtr]::Zero)
  [W]::keybd_event($k, 0, $KEYUP, [IntPtr]::Zero)
  if ($shift) { [W]::keybd_event($VK_SHIFT, 0, $KEYUP, [IntPtr]::Zero) }
  Start-Sleep -Milliseconds 450
}
function Type([string]$s) {
  [System.Windows.Forms.SendKeys]::SendWait($s)
  Start-Sleep -Milliseconds 250
}

Add-Type -AssemblyName System.Windows.Forms

$pill = [W]::FindWindowW("SlatePill", $null)
$main = [W]::FindWindowW($null, "Slate")
if ($pill -eq [IntPtr]::Zero) { throw "SlatePill window not found — is Slate running?" }
if ($main -eq [IntPtr]::Zero) { throw "Slate main window not found" }
"pill hwnd=$pill  main hwnd=$main"

$fail = 0
function Check($name, $cond) {
  if ($cond) { "  PASS  $name" } else { "  FAIL  $name"; $script:fail++ }
}

foreach ($mode in @('maximized', 'windowed')) {
  "`n=== $mode ==="
  [W]::SetForegroundWindow($main) | Out-Null
  if ($mode -eq 'maximized') { [W]::ShowWindow($main, $SW_MAXIMIZE) | Out-Null }
  else { [W]::ShowWindow($main, $SW_RESTORE) | Out-Null }
  Start-Sleep -Milliseconds 700
  Check "main is $mode" ([W]::IsZoomed($main) -eq ($mode -eq 'maximized'))

  # 1. The chord raises the SEPARATE pill window — in both modes.
  Chord
  Check "chord shows the pill window" ([W]::IsWindowVisible($pill))

  # 2. The pill belongs to the SCREEN: same rect regardless of the main window.
  $r = New-Object W+RECT
  [W]::GetWindowRect($pill, [ref]$r) | Out-Null
  "  pill rect: $($r.L),$($r.T) $($r.R - $r.L)x$($r.B - $r.T)"
  Set-Variable -Name "rect_$mode" -Value "$($r.L),$($r.T),$($r.R),$($r.B)" -Scope script

  # 3. Shift+Enter KEEPS it open (it was dead in the in-canvas host).
  Type "shift enter parity probe"
  Key $VK_RETURN $true
  Check "Shift+Enter keeps the pill" ([W]::IsWindowVisible($pill))

  # 4. Plain Enter DISMISSES it (it never did in-canvas).
  Type "plain enter parity probe"
  Key $VK_RETURN
  Start-Sleep -Milliseconds 400
  Check "Enter dismisses the pill" (-not [W]::IsWindowVisible($pill))
}

"`n=== parity ==="
Check "pill lands in the SAME place in both modes" ($rect_maximized -eq $rect_windowed)
"  maximized: $rect_maximized"
"  windowed : $rect_windowed"

if ($fail -gt 0) { "`nRESULT: $fail FAILED"; exit 1 } else { "`nRESULT: ALL PASS"; exit 0 }
