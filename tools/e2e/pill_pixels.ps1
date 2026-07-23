# pill_pixels.ps1 - does the pill actually LOOK right on screen?
#
# Win32 rects are not proof. In v1.0.3 the matrix passed 12/12 while the pill was
# visibly stretched: a window can hold a perfect rect and still present a stale,
# stretched DWM surface. So this measures PIXELS, off the real screen.
#
# Method:
#   1. Minimise everything (Win+D) so the backdrop is static wallpaper. Without
#      this, a live editor repainting between the two frames swamps the diff.
#   2. Screenshot, summon the pill, screenshot again.
#   3. Diff the frames and take the COLUMN/ROW energy profile. The pill's scrim
#      raises the whole frame by a flat baseline; the capsule is a sharp peak on
#      top of it. Reading the peak's edges beats any fixed threshold, which is
#      hopeless when the capsule is dark-on-dark.
#   4. A healthy pill: ~600 px wide, centred on the work area, bottom edge ~48 px
#      above the window bottom (pill_window.dart).
#
# The captured frame is written out as PNG so a human (or an agent that can read
# images) can just LOOK at it - the final word on a rendering bug.
#
# Usage: powershell -NoProfile -File tools\e2e\pill_pixels.ps1 [-Out shot.png]

param(
  [string]$Out,
  [int]$SettleMs = 900,
  [switch]$NoDesktopClear
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# /unsafe for the pointer walk over the two frames; ReferencedAssemblies is a
# read-only collection, so it has to be filled, not assigned.
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.CompilerOptions = '/unsafe'
[void]$cp.ReferencedAssemblies.Add('System.dll')
[void]$cp.ReferencedAssemblies.Add('System.Drawing.dll')

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class PillPix {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }

  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint f);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr h, ref MONITORINFO mi);

  const byte VK_MENU = 0x12, VK_SPACE = 0x20, VK_ESCAPE = 0x1B, VK_LWIN = 0x5B, VK_D = 0x44;
  const uint KEYUP = 0x0002;

  public static IntPtr Pill() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "SlatePill"); }
  public static bool PillVisible() { IntPtr h = Pill(); return h != IntPtr.Zero && IsWindowVisible(h); }

  public static void Summon() {
    keybd_event(VK_MENU, 0, 0, IntPtr.Zero);
    keybd_event(VK_SPACE, 0, 0, IntPtr.Zero);
    keybd_event(VK_SPACE, 0, KEYUP, IntPtr.Zero);
    keybd_event(VK_MENU, 0, KEYUP, IntPtr.Zero);
  }
  public static void Escape() {
    keybd_event(VK_ESCAPE, 0, 0, IntPtr.Zero);
    keybd_event(VK_ESCAPE, 0, KEYUP, IntPtr.Zero);
  }
  /// Win+D - toggles "show desktop"; called again it restores the windows.
  public static void ToggleDesktop() {
    keybd_event(VK_LWIN, 0, 0, IntPtr.Zero);
    keybd_event(VK_D, 0, 0, IntPtr.Zero);
    keybd_event(VK_D, 0, KEYUP, IntPtr.Zero);
    keybd_event(VK_LWIN, 0, KEYUP, IntPtr.Zero);
  }

  public static RECT CursorWork() {
    POINT p; GetCursorPos(out p);
    MONITORINFO mi = new MONITORINFO();
    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    GetMonitorInfoW(MonitorFromPoint(p, 2), ref mi);
    return mi.rcWork;
  }

  public static Bitmap Grab(RECT r) {
    Bitmap bmp = new Bitmap(r.right - r.left, r.bottom - r.top, PixelFormat.Format32bppRgb);
    using (Graphics g = Graphics.FromImage(bmp))
      g.CopyFromScreen(r.left, r.top, 0, 0, bmp.Size, CopyPixelOperation.SourceCopy);
    return bmp;
  }

  /// Column/row energy profile of |a-b|, then the extent of the dominant peak
  /// above the flat scrim baseline. Returns {x0,x1,y0,y1,totalEnergy,peakRatio}.
  public static double[] PeakBox(Bitmap a, Bitmap b) {
    int w = Math.Min(a.Width, b.Width), h = Math.Min(a.Height, b.Height);
    Rectangle rc = new Rectangle(0, 0, w, h);
    BitmapData da = a.LockBits(rc, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
    BitmapData db = b.LockBits(rc, ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
    double[] col = new double[w];
    double[] row = new double[h];
    double total = 0;
    unsafe {
      for (int y = 0; y < h; y++) {
        byte* pa = (byte*)da.Scan0 + (long)y * da.Stride;
        byte* pb = (byte*)db.Scan0 + (long)y * db.Stride;
        for (int x = 0; x < w; x++) {
          int i = x * 4;
          int d = Math.Abs(pa[i] - pb[i]) + Math.Abs(pa[i+1] - pb[i+1]) + Math.Abs(pa[i+2] - pb[i+2]);
          col[x] += d; row[y] += d; total += d;
        }
      }
    }
    a.UnlockBits(da); b.UnlockBits(db);

    double[] cx = Extent(col);
    double[] cy = Extent(row);
    return new double[] { cx[0], cx[1], cy[0], cy[1], total, Math.Min(cx[2], cy[2]) };
  }

  /// Extent of the dominant peak: baseline = median, edges where the signal
  /// falls back under 35% of the peak height. Third value = peak/baseline ratio,
  /// i.e. how much the capsule stands out from the flat scrim.
  static double[] Extent(double[] p) {
    double[] sorted = (double[])p.Clone();
    Array.Sort(sorted);
    double baseline = sorted[sorted.Length / 2];
    double max = 0; int argmax = 0;
    for (int i = 0; i < p.Length; i++) if (p[i] > max) { max = p[i]; argmax = i; }
    double peak = max - baseline;
    if (peak <= 0) return new double[] { -1, -1, 0 };
    double cut = baseline + 0.35 * peak;
    int lo = argmax, hi = argmax;
    while (lo > 0 && p[lo - 1] > cut) lo--;
    while (hi < p.Length - 1 && p[hi + 1] > cut) hi++;
    double ratio = baseline > 1 ? max / baseline : 999;
    return new double[] { lo, hi + 1, ratio };
  }
}
'@ -CompilerParameters $cp

if (-not [PillPix]::Pill()) { Write-Host 'FAIL: pill window not found (is Slate running?)'; exit 1 }
if ([PillPix]::PillVisible()) { [PillPix]::Escape(); Start-Sleep -Milliseconds 600 }

$work = [PillPix]::CursorWork()
$W = $work.right - $work.left
$H = $work.bottom - $work.top

# Static backdrop, then two frames with NOTHING printed in between.
if (-not $NoDesktopClear) { [PillPix]::ToggleDesktop(); Start-Sleep -Milliseconds 1200 }

$before = [PillPix]::Grab($work)
[PillPix]::Summon()
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  if ([PillPix]::PillVisible()) { $ok = $true; break }
  Start-Sleep -Milliseconds 50
}
if ($ok) { Start-Sleep -Milliseconds $SettleMs }
$after = [PillPix]::Grab($work)

$pr = New-Object PillPix+RECT
[void][PillPix]::GetWindowRect([PillPix]::Pill(), [ref]$pr)

if ($Out) {
  $dir = Split-Path $Out -Parent
  if ($dir -and -not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Force $dir) }
  $after.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
}

[PillPix]::Escape()
Start-Sleep -Milliseconds 400
if (-not $NoDesktopClear) { [PillPix]::ToggleDesktop(); Start-Sleep -Milliseconds 800 }

Write-Host ("work area      : {0},{1}-{2},{3} [{4}x{5}]" -f $work.left, $work.top, $work.right, $work.bottom, $W, $H)
Write-Host ("pill window    : {0},{1}-{2},{3} [{4}x{5}]" -f $pr.left, $pr.top, $pr.right, $pr.bottom, ($pr.right-$pr.left), ($pr.bottom-$pr.top))
if ($Out) { Write-Host ("frame saved    : {0}" -f $Out) }
if (-not $ok) { $before.Dispose(); $after.Dispose(); Write-Host 'FAIL: pill never became visible'; exit 1 }

$box = [PillPix]::PeakBox($before, $after)
$before.Dispose(); $after.Dispose()

$x0 = [int]$box[0]; $x1 = [int]$box[1]; $y0 = [int]$box[2]; $y1 = [int]$box[3]
if ($x0 -lt 0) { Write-Host 'FAIL: no pill signal in the frame at all'; exit 1 }

$bw = $x1 - $x0
$centre = [int](($x0 + $x1) / 2)
$bottomGap = $H - $y1

Write-Host ''
Write-Host ("capsule box    : x {0}..{1} (w {2}), y {3}..{4} (h {5})" -f $x0, $x1, $bw, $y0, $y1, ($y1 - $y0))
Write-Host ("centre X       : {0}   (work-area centre {1})" -f $centre, [int]($W / 2))
Write-Host ("gap below      : {0} px   (expected ~48)" -f $bottomGap)
Write-Host ("peak/baseline  : {0:N1}   (how far the capsule stands out of the scrim)" -f $box[5])
Write-Host ''

# WHAT IS ASSERTED, AND WHY SO LITTLE.
# The capsule profile above is printed, never asserted. It was tried and it
# lied in both directions on 2026-07-23: it FAILED a perfectly good pill (the
# right half of an empty capsule barely differs from the scrim, so the column
# profile only finds the text side) and it can pass junk when the pill paints
# nothing at all. A check that cries wolf is worse than no check.
# So the machine asserts only what it can actually know:
#   - the pill became visible at all
#   - its window matches the work area it was summoned onto (Win32 truth)
# and it always writes the frame. Whether the capsule LOOKS right is a human
# (or image-reading agent) call on that PNG - that is the lesson of v1.0.3,
# where 12/12 green rects shipped a visibly stretched pill.
$fails = New-Object Collections.Generic.List[string]
$pw = $pr.right - $pr.left
$ph = $pr.bottom - $pr.top
if ($pw -ne $W -or $ph -ne $H) {
  $fails.Add("pill window ${pw}x${ph} but work area ${W}x${H}")
}

if ($fails.Count -gt 0) {
  Write-Host 'CHECK FAIL'
  $fails | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
Write-Host 'CHECK PASS - pill came up and fills the work area'
Write-Host '  now LOOK at the frame: the capsule must be a ~600 px band, centred,'
Write-Host '  sitting ~48 px above the bottom. Rects alone shipped a broken 1.0.3.'
exit 0
