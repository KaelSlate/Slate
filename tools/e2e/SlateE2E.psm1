# SlateE2E.psm1 - shared Win32 helpers for the Slate window-morph e2e matrix.
# PowerShell 5.1. Run scripts as: powershell -NoProfile -File ... (never -EncodedCommand).

$ErrorActionPreference = 'Stop'

if (-not ('SlateE2E.Native' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace SlateE2E {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X, Y; }

  [StructLayout(LayoutKind.Sequential)]
  public struct WINDOWPLACEMENT {
    public int length, flags, showCmd;
    public POINT minPosition, maxPosition;
    public RECT normalPosition;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFO {
    public int cbSize;
    public RECT rcMonitor, rcWork;
    public int dwFlags;
  }

  public static class Native {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);
  }
}
'@
}

[void][SlateE2E.Native]::SetProcessDPIAware()
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$script:SummonCtrl = $false   # remembered fallback: Ctrl+Alt+Space instead of Alt+Space

function Get-SlateHwnd {
  [SlateE2E.Native]::FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW', 'Slate')
}

function Get-LayeredAlpha([IntPtr]$h) {
  $k = [uint32]0; $a = [byte]0; $fl = [uint32]0
  if ([SlateE2E.Native]::GetLayeredWindowAttributes($h, [ref]$k, [ref]$a, [ref]$fl)) {
    if (($fl -band 2) -ne 0) { return [int]$a }   # LWA_ALPHA in effect
  }
  return 255
}

function Get-WinState([IntPtr]$h) {
  $r = New-Object SlateE2E.RECT
  [void][SlateE2E.Native]::GetWindowRect($h, [ref]$r)
  $cloak = 0
  [void][SlateE2E.Native]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
  [pscustomobject]@{
    Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom
    Visible = [SlateE2E.Native]::IsWindowVisible($h)
    Iconic  = [SlateE2E.Native]::IsIconic($h)
    Zoomed  = [SlateE2E.Native]::IsZoomed($h)
    Cloaked = ($cloak -ne 0)
    Topmost = (([SlateE2E.Native]::GetWindowLong($h, -20) -band 0x8) -ne 0)
    Foreground = ([SlateE2E.Native]::GetForegroundWindow() -eq $h)
    Alpha = (Get-LayeredAlpha $h)
  }
}

function Get-WorkArea {
  $pt = New-Object SlateE2E.POINT
  $pt.X = 200; $pt.Y = 200
  $mon = [SlateE2E.Native]::MonitorFromPoint($pt, 2)
  $mi = New-Object SlateE2E.MONITORINFO
  $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][SlateE2E.MONITORINFO])
  [void][SlateE2E.Native]::GetMonitorInfoW($mon, [ref]$mi)
  $mi.rcWork
}

function Test-RectNear([IntPtr]$h, $rect, [int]$tol = 3) {
  $r = New-Object SlateE2E.RECT
  [void][SlateE2E.Native]::GetWindowRect($h, [ref]$r)
  (([math]::Abs($r.Left - $rect.Left) -lt $tol) -and
   ([math]::Abs($r.Top - $rect.Top) -lt $tol) -and
   ([math]::Abs($r.Right - $rect.Right) -lt $tol) -and
   ([math]::Abs($r.Bottom - $rect.Bottom) -lt $tol))
}

function Test-SampleRectNear($s, $rect, [int]$tol = 3) {
  (([math]::Abs($s.Left - $rect.Left) -lt $tol) -and
   ([math]::Abs($s.Top - $rect.Top) -lt $tol) -and
   ([math]::Abs($s.Right - $rect.Right) -lt $tol) -and
   ([math]::Abs($s.Bottom - $rect.Bottom) -lt $tol))
}

function Wait-Until([scriptblock]$cond, [int]$timeoutMs = 3000, [int]$intervalMs = 25) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    if (& $cond) { return $true }
    Start-Sleep -Milliseconds $intervalMs
  }
  return (& $cond)
}

function Send-Key([byte]$vk, [bool]$up) {
  $flags = 0
  if ($up) { $flags = 2 }
  [SlateE2E.Native]::keybd_event($vk, 0, $flags, [UIntPtr]::Zero)
}

function Send-Chord([bool]$withCtrl) {
  if ($withCtrl) { Send-Key 0x11 $false; Start-Sleep -Milliseconds 20 }
  Send-Key 0x12 $false; Start-Sleep -Milliseconds 20   # Alt down
  Send-Key 0x20 $false; Start-Sleep -Milliseconds 20   # Space down
  Send-Key 0x20 $true;  Start-Sleep -Milliseconds 20
  Send-Key 0x12 $true
  if ($withCtrl) { Start-Sleep -Milliseconds 20; Send-Key 0x11 $true }
}

function Send-Escape {
  Send-Key 0x1B $false; Start-Sleep -Milliseconds 20; Send-Key 0x1B $true
}

# The summon chord with whatever modifier calibration Send-Summon learned.
function Send-SummonChord {
  Send-Chord $script:SummonCtrl
}

function Test-PillUp([IntPtr]$h) {
  $wa = Get-WorkArea
  $s = Get-WinState $h
  ($s.Visible -and $s.Topmost -and (Test-SampleRectNear $s $wa))
}

# Summon the pill; auto-falls back to Ctrl+Alt+Space (hotkey fallback chord).
function Send-Summon([IntPtr]$h) {
  $wa = Get-WorkArea
  $pt = New-Object SlateE2E.POINT
  [void][SlateE2E.Native]::SetCursorPos(
    [int](($wa.Left + $wa.Right) / 2), [int](($wa.Top + $wa.Bottom) / 2))
  Send-Chord $script:SummonCtrl
  if (Wait-Until { Test-PillUp $h } 1500) { return $true }
  if (-not $script:SummonCtrl) {
    Send-Escape                                # close a stray system menu
    Start-Sleep -Milliseconds 150
    Send-Chord $true
    if (Wait-Until { Test-PillUp $h } 1500) { $script:SummonCtrl = $true; return $true }
  }
  return $false
}

# Alt-tap earns "last input" for our thread, then SetForegroundWindow sticks.
function Set-ForegroundReliable([IntPtr]$h) {
  for ($i = 0; $i -lt 4; $i++) {
    if ([SlateE2E.Native]::GetForegroundWindow() -eq $h) { return $true }
    Send-Key 0x12 $false; Send-Key 0x12 $true
    [void][SlateE2E.Native]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 120
  }
  ([SlateE2E.Native]::GetForegroundWindow() -eq $h)
}

# True when $a sits above $b in the z-order (walk down from $a, hit $b).
function Test-AboveOf([IntPtr]$a, [IntPtr]$b) {
  $cur = $a
  for ($i = 0; $i -lt 256; $i++) {
    $cur = [SlateE2E.Native]::GetWindow($cur, 2)  # GW_HWNDNEXT
    if ($cur -eq [IntPtr]::Zero) { return $false }
    if ($cur -eq $b) { return $true }
  }
  return $false
}

function Hide-SlateToTray([IntPtr]$h) {
  [void][SlateE2E.Native]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
}

function Open-SlateViaShowRequest([IntPtr]$h) {
  $msg = [SlateE2E.Native]::RegisterWindowMessageW('Slate.ShowRequested')
  [void][SlateE2E.Native]::PostMessageW($h, $msg, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Request-SlateQuit([IntPtr]$h) {
  $msg = [SlateE2E.Native]::RegisterWindowMessageW('Slate.QuitForHandover')
  [void][SlateE2E.Native]::PostMessageW($h, $msg, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-Placement([IntPtr]$h) {
  $p = New-Object SlateE2E.WINDOWPLACEMENT
  $p.length = [Runtime.InteropServices.Marshal]::SizeOf([type][SlateE2E.WINDOWPLACEMENT])
  [void][SlateE2E.Native]::GetWindowPlacement($h, [ref]$p)
  $p
}

# --- pixel truth (the Win32 flags can all be green while the RENDER is wrong:
# --- round 8 shipped a pill shrunk into the corner past 24 green rect asserts) ---

function Get-ScreenBitmap {
  $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
  $g.Dispose()
  $bmp
}

# Headless agent sessions render a blank virtual screen - detect and skip.
function Test-BitmapUniform($bmp) {
  $first = $bmp.GetPixel(10, 10)
  for ($x = 0; $x -lt 5; $x++) {
    for ($y = 0; $y -lt 5; $y++) {
      $p = $bmp.GetPixel([int]($bmp.Width * ($x + 0.5) / 5), [int]($bmp.Height * ($y + 0.5) / 5))
      if ([math]::Abs($p.R - $first.R) -gt 6 -or [math]::Abs($p.G - $first.G) -gt 6 -or [math]::Abs($p.B - $first.B) -gt 6) {
        return $false
      }
    }
  }
  return $true
}

# Mean absolute RGB difference between two same-size crops (2px sampling).
function Get-CropMAD($a, $b) {
  $sum = 0.0; $n = 0
  for ($x = 0; $x -lt $a.Width; $x += 2) {
    for ($y = 0; $y -lt $a.Height; $y += 2) {
      $pa = $a.GetPixel($x, $y); $pb = $b.GetPixel($x, $y)
      $sum += ([math]::Abs($pa.R - $pb.R) + [math]::Abs($pa.G - $pb.G) + [math]::Abs($pa.B - $pb.B)) / 3.0
      $n++
    }
  }
  if ($n -eq 0) { return 255 }
  $sum / $n
}

# High-frequency state sampler in a background runspace (~2-4 ms per sample).
function Start-Sampler([IntPtr]$slate, [IntPtr]$notepad) {
  $data = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  $flag = [Hashtable]::Synchronized(@{ stop = $false })
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript({
    param($slate, $notepad, $data, $flag)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $flag.stop) {
      $r = New-Object SlateE2E.RECT
      [void][SlateE2E.Native]::GetWindowRect($slate, [ref]$r)
      $cloak = 0
      [void][SlateE2E.Native]::DwmGetWindowAttribute($slate, 14, [ref]$cloak, 4)
      $alpha = 255
      $lk = [uint32]0; $la = [byte]0; $lf = [uint32]0
      if ([SlateE2E.Native]::GetLayeredWindowAttributes($slate, [ref]$lk, [ref]$la, [ref]$lf)) {
        if (($lf -band 2) -ne 0) { $alpha = [int]$la }
      }
      $above = $false
      if ($notepad -ne [IntPtr]::Zero) {
        $cur = $slate
        for ($i = 0; $i -lt 256; $i++) {
          $cur = [SlateE2E.Native]::GetWindow($cur, 2)
          if ($cur -eq [IntPtr]::Zero) { break }
          if ($cur -eq $notepad) { $above = $true; break }
        }
      }
      [void]$data.Add([pscustomobject]@{
        T = $sw.ElapsedMilliseconds
        Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom
        Visible = [SlateE2E.Native]::IsWindowVisible($slate)
        Iconic  = [SlateE2E.Native]::IsIconic($slate)
        Zoomed  = [SlateE2E.Native]::IsZoomed($slate)
        Cloaked = ($cloak -ne 0)
        Topmost = (([SlateE2E.Native]::GetWindowLong($slate, -20) -band 0x8) -ne 0)
        Foreground = ([SlateE2E.Native]::GetForegroundWindow() -eq $slate)
        AboveNotepad = $above
        Alpha = $alpha
      })
      [Threading.Thread]::Sleep(2)
    }
  })
  [void]$ps.AddArgument($slate).AddArgument($notepad).AddArgument($data).AddArgument($flag)
  $handle = $ps.BeginInvoke()
  [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $handle; Data = $data; Flag = $flag }
}

function Stop-Sampler($s) {
  $s.Flag.stop = $true
  try { [void]$s.PS.EndInvoke($s.Handle) } catch {}
  $s.PS.Dispose(); $s.RS.Close(); $s.RS.Dispose()
  @($s.Data)
}

# --- separate pill window (v1.0.6+) ---

function Get-PillHwnd {
  [SlateE2E.Native]::FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW', 'SlatePill')
}

function Test-PillVisible {
  $h = Get-PillHwnd
  ($h -ne [IntPtr]::Zero) -and [SlateE2E.Native]::IsWindowVisible($h)
}

# Fire the capture hotkey; the pill is a SEPARATE window now, so success =
# the SlatePill window becomes visible (not the main window morphing).
function Send-PillHotkey {
  $wa = Get-WorkArea
  $pt = New-Object SlateE2E.POINT
  [void][SlateE2E.Native]::SetCursorPos(
    [int](($wa.Left + $wa.Right) / 2), [int](($wa.Top + $wa.Bottom) / 2))
  Send-Chord $script:SummonCtrl
  if (Wait-Until { Test-PillVisible } 1500) { return $true }
  if (-not $script:SummonCtrl) {
    Send-Chord $true
    if (Wait-Until { Test-PillVisible } 1500) { $script:SummonCtrl = $true; return $true }
  }
  return $false
}

Export-ModuleMember -Function *
