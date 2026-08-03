# view_shot.ps1 - raise the main window and photograph WEEK and MONTH.
#
# For judging paint-level work (the weekend band) by eye. Real composited
# pixels off the screen, not PrintWindow: what the user sees is the point.
# 'V' toggles WEEK <-> MONTH (pulse_layer.dart).
#
# Usage: powershell -NoProfile -File tools\e2e\view_shot.ps1 [-OutDir tools\e2e\_views]

param(
  [string]$OutDir = 'tools\e2e\_views',
  [int]$SettleMs = 1200
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class Shot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern uint RegisterWindowMessageW(string s);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

  public static IntPtr Slate() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "Slate"); }
  public static IntPtr Pill() { return FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", "SlatePill"); }
  public static void ShowRequest() {
    PostMessageW(Slate(), RegisterWindowMessageW("Slate.ShowRequested"), IntPtr.Zero, IntPtr.Zero);
  }
  public static void Key(byte vk) {
    keybd_event(vk, 0, 0, IntPtr.Zero); keybd_event(vk, 0, 0x0002, IntPtr.Zero);
  }
  public static void Save(string path) {
    RECT r; GetWindowRect(Slate(), out r);
    int w = r.right - r.left, h = r.bottom - r.top;
    using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb)) {
      using (Graphics g = Graphics.FromImage(bmp))
        g.CopyFromScreen(r.left, r.top, 0, 0, bmp.Size, CopyPixelOperation.SourceCopy);
      bmp.Save(path, ImageFormat.Png);
    }
  }
}
'@ -ReferencedAssemblies 'System.Drawing'

if (-not [Shot]::Slate()) { Write-Host 'FAIL: Slate window not found'; exit 1 }
if (-not (Test-Path $OutDir)) { [void](New-Item -ItemType Directory -Force $OutDir) }

# A capture pill left open would swallow the view key.
if ([Shot]::IsWindowVisible([Shot]::Pill())) { [Shot]::Key(0x1B); Start-Sleep -Milliseconds 700 }

[Shot]::ShowRequest()
for ($i = 0; $i -lt 40 -and -not [Shot]::IsWindowVisible([Shot]::Slate()); $i++) { Start-Sleep -Milliseconds 200 }
[void][Shot]::SetForegroundWindow([Shot]::Slate())
Start-Sleep -Milliseconds $SettleMs

$a = Join-Path $OutDir 'view_a.png'
[Shot]::Save($a)

[Shot]::Key(0x56)   # 'V' — toggles WEEK <-> MONTH
Start-Sleep -Milliseconds $SettleMs
$b = Join-Path $OutDir 'view_b.png'
[Shot]::Save($b)

Write-Host ("saved: {0}" -f $a)
Write-Host ("saved: {0}" -f $b)
Write-Host 'LOOK at them: the Sat+Sun region must read as recessed, never coloured.'
exit 0
