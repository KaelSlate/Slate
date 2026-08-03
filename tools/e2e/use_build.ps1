# use_build.ps1 - make a given slate.exe the live instance (tray + hotkey only).
#
# Single-instance handover (main.cpp) does the swap: the new process asks the
# running one to quit cleanly (Rust flush + tray removal), waits, then takes over.
# Used to put a freshly built binary under the e2e harnesses and, afterwards, to
# put the user's INSTALLED build back.
#
# Usage: powershell -NoProfile -File tools\e2e\use_build.ps1 -Exe <path to slate.exe>

param(
  [Parameter(Mandatory = $true)][string]$Exe
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string n);
}
'@

$full = (Resolve-Path $Exe).Path
Write-Host ("before : {0}" -f ((Get-Process slate -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) $($_.Path)" }) -join ' | '))

Start-Process -FilePath $full -ArgumentList '--hidden'

$pill = [IntPtr]::Zero
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 500
  $pill = [W]::FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW', 'SlatePill')
  if ($pill -ne [IntPtr]::Zero) { break }
}

Write-Host ("after  : {0}" -f ((Get-Process slate -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Id) $($_.Path)" }) -join ' | '))
Write-Host ("pill hwnd: {0}" -f $pill)
if ($pill -eq [IntPtr]::Zero) { Write-Host 'FAIL: pill window never appeared'; exit 1 }
Write-Host 'OK'
exit 0
