# pill_flash.ps1 - does the screen FLASH when the pill is summoned?
#
# The bug: ~1 summon in 10, the whole work area goes light for a single frame at
# the moment the pill appears. A one-frame event is invisible to the two-shot
# method of pill_pixels.ps1, so this samples continuously instead.
#
# Method:
#   1. One GDI DIB, reused: BitBlt a full-width strip taken at 1/3 of the work
#      area height, every ~2 ms, into a ring of frames + mean luminance.
#      1/3 height on purpose - the capsule lives near the BOTTOM, so the pill
#      itself never registers as a flash. Only the full-screen layer does.
#   2. Baseline = median luminance BEFORE the hotkey.
#   3. Summon, keep sampling ~500 ms, Escape.
#   4. A healthy summon makes the strip DARKER (the scrim is black at 10%).
#      A flash is the opposite sign: luminance ABOVE baseline. That sign
#      difference is the whole test - no fragile absolute threshold.
#   5. Every flash is written out as PNG. The COLOUR of that frame settles the
#      cause: white = uninitialised DWM redirection surface, graphite = the
#      window class brush, a visible capsule = a stale last frame.
#
# Usage: powershell -NoProfile -File tools\e2e\pill_flash.ps1 [-Trials 40] [-OutDir .]

param(
  [int]$Trials = 40,
  [double]$Threshold = 6.0,   # luma points above baseline that count as a flash
  [string]$OutDir = 'tools\e2e\_flash',
  [int]$StripHeight = 16,
  # Idle before each summon. The flash favours a pill that has sat hidden for a
  # while (3 of the first 4 caught landed on trial 1), so this raises the rate
  # and makes a clean run mean something.
  [int]$IdleMs = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.CompilerOptions = '/unsafe'
[void]$cp.ReferencedAssemblies.Add('System.dll')
[void]$cp.ReferencedAssemblies.Add('System.Drawing.dll')

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class FlashCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
    public int biSize, biWidth, biHeight; public short biPlanes, biBitCount;
    public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }

  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint f);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr h, ref MONITORINFO mi);
  [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);
  [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr obj);
  [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern bool BitBlt(IntPtr d, int dx, int dy, int w, int h, IntPtr s, int sx, int sy, uint rop);

  const byte VK_MENU = 0x12, VK_SPACE = 0x20, VK_ESCAPE = 0x1B;
  const uint KEYUP = 0x0002, SRCCOPY = 0x00CC0020;

  static IntPtr screenDC, memDC, dib, bits, oldObj;
  static int sx, sy, sw, sh, strideBytes;
  static byte[][] frames;
  static double[] luma;
  static double[] atMs;
  public static int Count;
  public static int SummonIndex;

  public static IntPtr Pill() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "SlatePill"); }
  public static bool PillVisible() { IntPtr h = Pill(); return h != IntPtr.Zero && IsWindowVisible(h); }
  public static void Summon() {
    keybd_event(VK_MENU, 0, 0, IntPtr.Zero); keybd_event(VK_SPACE, 0, 0, IntPtr.Zero);
    keybd_event(VK_SPACE, 0, KEYUP, IntPtr.Zero); keybd_event(VK_MENU, 0, KEYUP, IntPtr.Zero);
  }
  public static void Escape() {
    keybd_event(VK_ESCAPE, 0, 0, IntPtr.Zero); keybd_event(VK_ESCAPE, 0, KEYUP, IntPtr.Zero);
  }

  public static RECT CursorWork() {
    POINT p; GetCursorPos(out p);
    MONITORINFO mi = new MONITORINFO();
    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    GetMonitorInfoW(MonitorFromPoint(p, 2), ref mi);
    return mi.rcWork;
  }

  /// One DC + one top-down DIB for the whole run: allocating per sample would
  /// cost more than the capture.
  public static void Init(int x, int y, int w, int h, int capacity) {
    SetProcessDPIAware();
    sx = x; sy = y; sw = w; sh = h; strideBytes = w * 4;
    screenDC = GetDC(IntPtr.Zero);
    memDC = CreateCompatibleDC(screenDC);
    BITMAPINFOHEADER bi = new BITMAPINFOHEADER();
    bi.biSize = Marshal.SizeOf(typeof(BITMAPINFOHEADER));
    bi.biWidth = w; bi.biHeight = -h;  // negative = top-down
    bi.biPlanes = 1; bi.biBitCount = 32; bi.biCompression = 0;
    dib = CreateDIBSection(screenDC, ref bi, 0, out bits, IntPtr.Zero, 0);
    oldObj = SelectObject(memDC, dib);
    frames = new byte[capacity][];
    for (int i = 0; i < capacity; i++) frames[i] = new byte[strideBytes * h];
    luma = new double[capacity];
    atMs = new double[capacity];
  }

  public static void Dispose() {
    if (memDC != IntPtr.Zero) { SelectObject(memDC, oldObj); DeleteDC(memDC); }
    if (dib != IntPtr.Zero) DeleteObject(dib);
    if (screenDC != IntPtr.Zero) ReleaseDC(IntPtr.Zero, screenDC);
    memDC = dib = screenDC = IntPtr.Zero;
  }

  static double Grab(int slot) {
    BitBlt(memDC, 0, 0, sw, sh, screenDC, sx, sy, SRCCOPY);
    double sum = 0;
    unsafe {
      byte* p = (byte*)bits;
      for (int i = 0; i < strideBytes * sh; i += 4) sum += p[i] + p[i + 1] + p[i + 2];
    }
    Marshal.Copy(bits, frames[slot], 0, strideBytes * sh);
    return sum / (sw * sh * 3.0);
  }

  /// Sample preMs, fire the hotkey, keep sampling postMs. Paced at stepMs so a
  /// single 60 Hz frame cannot slip between two samples.
  public static void RunTrial(int preMs, int postMs, double stepMs) {
    Stopwatch sw2 = Stopwatch.StartNew();
    Count = 0; SummonIndex = -1;
    double next = 0;
    bool fired = false;
    while (true) {
      double now = sw2.Elapsed.TotalMilliseconds;
      if (!fired && now >= preMs) { Summon(); SummonIndex = Count; fired = true; }
      if (now >= preMs + postMs) break;
      if (Count >= luma.Length) break;
      if (now >= next) {
        luma[Count] = Grab(Count);
        atMs[Count] = now;
        Count++;
        next = now + stepMs;
      }
    }
  }

  public static double Luma(int i) { return luma[i]; }
  public static double At(int i) { return atMs[i]; }

  public static void SaveFrame(int i, string path) {
    GCHandle gh = GCHandle.Alloc(frames[i], GCHandleType.Pinned);
    try {
      using (Bitmap bmp = new Bitmap(sw, sh, strideBytes, PixelFormat.Format32bppRgb, gh.AddrOfPinnedObject()))
        bmp.Save(path, ImageFormat.Png);
    } finally { gh.Free(); }
  }

  /// Mean channel values of one sample - "is it white or is it graphite".
  public static double[] Channels(int i) {
    byte[] f = frames[i];
    double b = 0, g = 0, r = 0;
    for (int k = 0; k < f.Length; k += 4) { b += f[k]; g += f[k + 1]; r += f[k + 2]; }
    double n = f.Length / 4.0;
    return new double[] { r / n, g / n, b / n };
  }
}
'@ -CompilerParameters $cp

if (-not [FlashCap]::Pill()) { Write-Host 'FAIL: pill window not found (is Slate running?)'; exit 1 }
if ([FlashCap]::PillVisible()) { [FlashCap]::Escape(); Start-Sleep -Milliseconds 600 }

$work = [FlashCap]::CursorWork()
$W = $work.right - $work.left
$H = $work.bottom - $work.top
$stripY = $work.top + [int]($H / 3)

if (-not (Test-Path $OutDir)) { [void](New-Item -ItemType Directory -Force $OutDir) }

$preMs = 120
$postMs = 500
$stepMs = 2.0
$capacity = [int](($preMs + $postMs) / $stepMs) + 64

[FlashCap]::Init($work.left, $stripY, $W, $StripHeight, $capacity)

Write-Host ("work area   : {0}x{1} at {2},{3}" -f $W, $H, $work.left, $work.top)
Write-Host ("sample strip: {0}x{1} at y={2}   (1/3 down - above the capsule)" -f $W, $StripHeight, $stripY)
Write-Host ("trials      : {0}, ~{1} samples each at {2} ms" -f $Trials, $capacity, $stepMs)
Write-Host ''

$flashes = 0
$rows = @()

for ($t = 1; $t -le $Trials; $t++) {
  if ($IdleMs -gt 0) { Start-Sleep -Milliseconds $IdleMs }
  [FlashCap]::RunTrial($preMs, $postMs, $stepMs)
  $n = [FlashCap]::Count
  $fireIdx = [FlashCap]::SummonIndex

  # Baseline = median of the pre-hotkey samples.
  $pre = @()
  for ($i = 0; $i -lt $fireIdx; $i++) { $pre += [FlashCap]::Luma($i) }
  $sorted = $pre | Sort-Object
  $baseline = $sorted[[int]($sorted.Count / 2)]

  # Only the SHOW window counts. The bug lives between ShowWindow and Flutter's
  # first frame (measured +38..+101 ms); a rise later than this is some other
  # app repainting, and one such false alarm already cost a re-run.
  $windowEndMs = 250
  $maxUp = -999.0; $maxUpIdx = -1; $maxDown = 0.0; $appearMs = -1.0
  for ($i = $fireIdx; $i -lt $n; $i++) {
    $at = [FlashCap]::At($i) - $preMs
    $d = [FlashCap]::Luma($i) - $baseline
    if ($at -le $windowEndMs -and $d -gt $maxUp) { $maxUp = $d; $maxUpIdx = $i }
    if ($d -lt $maxDown) { $maxDown = $d }
    # First sample the scrim darkens = the pill is on screen. This is the
    # summon's real latency, and it must not grow when the fix lands.
    if ($appearMs -lt 0 -and $d -le -1.5) { $appearMs = [FlashCap]::At($i) - $preMs }
  }

  $hit = $maxUp -ge $Threshold
  if ($hit) {
    $flashes++
    $png = Join-Path $OutDir ("flash_t{0:d2}.png" -f $t)
    [FlashCap]::SaveFrame($maxUpIdx, $png)
    $prevIdx = [Math]::Max($fireIdx - 1, 0)
    [FlashCap]::SaveFrame($prevIdx, (Join-Path $OutDir ("flash_t{0:d2}_before.png" -f $t)))
    # The signature: the class brush is added, so the rise is WARM and matches
    # AppTheme.background — +21,+17,+13. Anything else is another window.
    $ch = [FlashCap]::Channels($maxUpIdx)
    $chB = [FlashCap]::Channels($prevIdx)
    $dR = $ch[0] - $chB[0]; $dG = $ch[1] - $chB[1]; $dB = $ch[2] - $chB[2]
    $dur = 0
    for ($i = $fireIdx; $i -lt $n; $i++) {
      if (([FlashCap]::Luma($i) - $baseline) -ge ($maxUp / 2)) { $dur++ }
    }
    $ms = [FlashCap]::At($maxUpIdx) - $preMs
    Write-Host ("trial {0,2}: FLASH  +{1,5:N1} luma at +{2,4:N0} ms  ~{3:N0} ms  delta R+{4:N0} G+{5:N0} B+{6:N0}  -> {7}" -f `
      $t, $maxUp, $ms, ($dur * $stepMs), $dR, $dG, $dB, (Split-Path $png -Leaf))
  } else {
    Write-Host ("trial {0,2}: ok     up {1,6:N1} / down {2,6:N1}   appeared at +{3,4:N0} ms" -f $t, $maxUp, $maxDown, $appearMs)
  }

  $rows += [pscustomobject]@{ Trial = $t; Up = $maxUp; Down = $maxDown; Appear = $appearMs; Flash = $hit }

  [FlashCap]::Escape()
  Start-Sleep -Milliseconds 450
  for ($k = 0; $k -lt 20 -and [FlashCap]::PillVisible(); $k++) {
    [FlashCap]::Escape(); Start-Sleep -Milliseconds 100
  }
}

[FlashCap]::Dispose()

$ups = ($rows | ForEach-Object { $_.Up } | Measure-Object -Maximum -Average)
$app = ($rows | Where-Object { $_.Appear -ge 0 } | ForEach-Object { $_.Appear } | Measure-Object -Maximum -Average)
Write-Host ''
Write-Host ("FLASHES : {0} / {1}" -f $flashes, $Trials)
Write-Host ("max up  : {0:N1} luma   avg up: {1:N1}   (threshold {2:N1})" -f $ups.Maximum, $ups.Average, $Threshold)
Write-Host ("latency : avg {0:N0} ms   worst {1:N0} ms  (hotkey -> pill on screen)" -f $app.Average, $app.Maximum)
if ($flashes -gt 0) {
  Write-Host ("frames  : {0}" -f (Resolve-Path $OutDir))
  Write-Host '  LOOK at them. Near-white => uninitialised DWM redirection surface.'
  Write-Host '  Warm graphite => the window class brush. A visible capsule => stale last frame.'
  exit 1
}
Write-Host 'CLEAN - no summon raised the screen above baseline.'
exit 0
