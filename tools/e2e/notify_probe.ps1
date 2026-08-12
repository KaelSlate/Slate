# notify_probe.ps1 - does the reminder card behave, or does it eat the desktop?
#
# Three invariants, all deterministic, none of them "looks fine on a screenshot":
#
#   1. CLICK-THROUGH. Outside the card this window must not exist for the mouse.
#      HTTRANSPARENT could never do this (it only forwards a hit test to windows
#      of the SAME THREAD, so a click could never reach another process), which
#      is why the card is carved out with SetWindowRgn instead. This is the test
#      that proves the region actually clips a Flutter DXGI child surface - the
#      one real unknown in the whole feature.
#
#   2. NO FOCUS THEFT. The foreground window must be the same before and after.
#      A card that steals the caret mid-sentence is worse than no card.
#
#   3. CLOAK GATE. The window must never be visible-and-uncloaked before Dart
#      has painted, or DWM adds the class brush to the desktop (the screen-lift
#      bug the pill already paid for).
#
# Requires a running Slate. Usage:
#   powershell -NoProfile -File tools\e2e\notify_probe.ps1 [-Rows 1] [-Shot]

param(
  [int]$Rows = 1,
  [switch]$Shot
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public class Notify {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string n);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr hrgn);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr hrgn, out RECT r);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

  const uint GA_ROOT = 2;
  const int DWMWA_CLOAKED = 14;

  public static IntPtr AppWindow() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "Slate"); }
  public static IntPtr Card() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "SlateNotify"); }

  public static bool Cloaked(IntPtr h) {
    int v;
    if (h == IntPtr.Zero) return false;
    if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out v, sizeof(int)) != 0) return false;
    return v != 0;
  }

  public static void Probe(int rows) {
    IntPtr m = AppWindow();
    if (m == IntPtr.Zero) throw new Exception("main Slate window not found");
    uint msg = RegisterWindowMessageW("Slate.NotifyProbe");
    PostMessageW(m, msg, (IntPtr)rows, IntPtr.Zero);
  }

  /// Screen-space box of the window's REGION - i.e. the part that still exists.
  public static bool RegionBox(IntPtr h, out RECT box) {
    box = new RECT();
    RECT wr;
    if (!GetWindowRect(h, out wr)) return false;
    IntPtr rgn = CreateRectRgn(0, 0, 1, 1);
    int kind = GetWindowRgn(h, rgn);
    bool ok = false;
    if (kind != 0) {
      RECT rb;
      if (GetRgnBox(rgn, out rb) != 0) {
        box.L = wr.L + rb.L; box.T = wr.T + rb.T;
        box.R = wr.L + rb.R; box.B = wr.T + rb.B;
        ok = true;
      }
    }
    DeleteObject(rgn);
    return ok;
  }

  /// Which top-level window owns this screen pixel?
  public static IntPtr RootAt(int x, int y) {
    POINT p; p.X = x; p.Y = y;
    IntPtr h = WindowFromPoint(p);
    if (h == IntPtr.Zero) return IntPtr.Zero;
    return GetAncestor(h, GA_ROOT);
  }

  /// Poll for the naked window (visible and NOT cloaked before first paint).
  public static bool SawNaked;
  public static bool SawGate;
  public static void Watch(int ms) {
    SawNaked = false; SawGate = false;
    var sw = System.Diagnostics.Stopwatch.StartNew();
    bool paintedYet = false;
    while (sw.ElapsedMilliseconds < ms) {
      IntPtr h = Card();
      if (h != IntPtr.Zero && IsWindowVisible(h)) {
        bool c = Cloaked(h);
        if (c) { SawGate = true; }
        else if (!SawGate) { SawNaked = true; }
        else { paintedYet = true; }
      }
      if (paintedYet) break;
      System.Threading.Thread.Sleep(2);
    }
  }

  public static void Shot(string path, RECT r) {
    int w = r.R - r.L, h = r.B - r.T;
    if (w <= 0 || h <= 0) return;
    using (var bmp = new Bitmap(w, h))
    using (var g = Graphics.FromImage(bmp)) {
      g.CopyFromScreen(r.L, r.T, 0, 0, new Size(w, h));
      bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
  }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms

function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failed = $true }
function Pass($msg) { Write-Host "PASS: $msg" -ForegroundColor Green }

$script:failed = $false

$main = [Notify]::AppWindow()
if ($main -eq [IntPtr]::Zero) {
  Write-Host "Slate is not running. Start it, then run this again." -ForegroundColor Yellow
  exit 2
}

$fgBefore = [Notify]::GetForegroundWindow()

# Probe, then poll straight away: Watch returns as soon as the window has been
# seen uncloaked after the gate, or after its timeout.
[Notify]::Probe($Rows)
[Notify]::Watch(1500)
Start-Sleep -Milliseconds 400

$card = [Notify]::Card()
if ($card -eq [IntPtr]::Zero) { Fail "SlateNotify window does not exist"; exit 1 }
if (-not [Notify]::IsWindowVisible($card)) {
  Write-Host "Card is not visible. Windows may be suppressing it (Focus Assist," -ForegroundColor Yellow
  Write-Host "full screen, locked). That is correct behaviour - retry when idle." -ForegroundColor Yellow
  exit 2
}

# ---- 2. focus ----------------------------------------------------------------
$fgAfter = [Notify]::GetForegroundWindow()
if ($fgAfter -eq $card) { Fail "card took the foreground" }
elseif ($fgAfter -ne $fgBefore) { Fail "foreground changed ($fgBefore -> $fgAfter)" }
else { Pass "no focus theft" }

# ---- 1. click-through --------------------------------------------------------
$box = New-Object Notify+RECT
if (-not [Notify]::RegionBox($card, [ref]$box)) {
  Fail "window has NO region - every pixel of the work area is eating clicks"
} else {
  $w = $box.R - $box.L
  $h = $box.B - $box.T
  Write-Host ("region: {0},{1} {2}x{3}" -f $box.L, $box.T, $w, $h)

  $cx = [int](($box.L + $box.R) / 2)
  $cy = [int](($box.T + $box.B) / 2)
  $inside = [Notify]::RootAt($cx, $cy)
  if ($inside -eq $card) { Pass "the card itself is clickable" }
  else { Fail "centre of the card does not belong to SlateNotify" }

  # 200 px above the region: inside the window, outside the card.
  $ay = $box.T - 200
  if ($ay -lt 10) { $ay = 10 }
  $above = [Notify]::RootAt($cx, $ay)
  if ($above -eq $card) {
    Fail "pixels ABOVE the card still belong to the window - clicks are eaten"
  } else {
    Pass "clicks pass through above the card"
  }

  # Far left on the same row as the card - the widest part of the work area.
  $side = [Notify]::RootAt(40, $cy)
  if ($side -eq $card) { Fail "pixels beside the card are eaten" }
  else { Pass "clicks pass through beside the card" }

  if ($Shot) {
    $dir = Join-Path $PSScriptRoot '_notify'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $pad = New-Object Notify+RECT
    $pad.L = [Math]::Max(0, $box.L - 60); $pad.T = [Math]::Max(0, $box.T - 60)
    $pad.R = $box.R + 60; $pad.B = $box.B + 60
    $file = Join-Path $dir ("card_{0}rows.png" -f $Rows)
    [Notify]::Shot($file, $pad)
    Write-Host "shot: $file"
  }
}

# ---- 3. cloak gate -----------------------------------------------------------
if ([Notify]::SawNaked) { Fail "window was visible and UNCLOAKED before paint" }
elseif ([Notify]::SawGate) { Pass "cloak gate held" }
else { Write-Host "NOTE: gate not sampled (card came up faster than the poll)" }

if ($script:failed) { exit 1 }
Write-Host "ALL PASS" -ForegroundColor Green
exit 0
