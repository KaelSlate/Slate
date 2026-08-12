# notify_show.ps1 - raise a reminder card on the running Slate, and ring it.
#
# This is the "let me look at it" tool. notify_probe.ps1 is the "prove it does
# not eat the desktop" tool; it asserts three OS-level invariants and prints a
# verdict, which is noise when all you want is to see the card and hear the
# chime.
#
# Requires a running Slate (the deployed one, not a fresh build sitting in
# build\windows). Usage:
#   powershell -NoProfile -File tools\e2e\notify_show.ps1          # one task
#   powershell -NoProfile -File tools\e2e\notify_show.ps1 -Rows 3  # a stack
#
# ASCII only, no BOM: PS 5.1 reads a BOM-less .ps1 as ANSI and the parser dies
# on anything above 0x7F.

param(
  [ValidateRange(1, 3)]
  [int]$Rows = 1
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class NotifyShow {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindowW(string cls, string name);

  // CharSet.Unicode is load-bearing. The ANSI entry point resolves to a
  // different message id, and the post lands somewhere harmless and silent.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern uint RegisterWindowMessageW(string name);

  [DllImport("user32.dll")]
  public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
}
'@

$hwnd = [NotifyShow]::FindWindowW('FLUTTER_RUNNER_WIN32_WINDOW', 'Slate')
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Output 'Slate is not running - start it first.'
  exit 1
}

$msg = [NotifyShow]::RegisterWindowMessageW('Slate.NotifyProbe')
if ($msg -eq 0) {
  Write-Output 'RegisterWindowMessage failed.'
  exit 1
}

[void][NotifyShow]::PostMessageW($hwnd, $msg, [IntPtr]$Rows, [IntPtr]::Zero)
Write-Output ("Card raised: {0} row(s). Chime: reminder.wav at 0.60." -f $Rows)
