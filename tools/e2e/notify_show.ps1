# notify_show.ps1 - raise a reminder card on the running Slate, and ring it.
#
# This is the "let me look at it" tool. notify_probe.ps1 is the "prove it does
# not eat the desktop" tool; it asserts three OS-level invariants and prints a
# verdict, which is noise when all you want is to see the card and hear the
# chime.
#
# Requires a running Slate (the deployed one, not a fresh build sitting in
# build\windows). Usage:
#   powershell -NoProfile -File tools\e2e\notify_show.ps1           # one task
#   powershell -NoProfile -File tools\e2e\notify_show.ps1 -Rows 3   # a stack
#   powershell -NoProfile -File tools\e2e\notify_show.ps1 -Stay     # leave the
#                                                                  # pointer be
#
# ASCII only, no BOM: PS 5.1 reads a BOM-less .ps1 as ANSI and the parser dies
# on anything above 0x7F.

param(
  [ValidateRange(1, 3)]
  [int]$Rows = 1,
  [switch]$Stay
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public struct PT { public int X, Y; }

public class NotifyShow {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern IntPtr FindWindowW(string cls, string name);

  // CharSet.Unicode is load-bearing. The ANSI entry point resolves to a
  // different message id, and the post lands somewhere harmless and silent.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern uint RegisterWindowMessageW(string name);

  [DllImport("user32.dll")]
  public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);

  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out PT p);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);

  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int i);
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

# GET THE POINTER OUT OF THE WAY FIRST.
#
# The card sits at bottom CENTRE, and a pointer resting there is hovering it
# from its very first frame - which by design cancels the dismissal clock and
# holds the card until the mouse moves. Perfectly correct behaviour, and
# perfectly confusing when you ran a script and the card then refuses to leave.
#
# So unless -Stay is asked for, park the pointer well clear of the landing zone
# and put it back afterwards. Cards are 344 px wide and about 48 px up from the
# work area's bottom edge; the top-left corner is nowhere near any of that.
$restore = $null
if (-not $Stay) {
  $p = New-Object PT
  if ([NotifyShow]::GetCursorPos([ref]$p)) {
    $w = [NotifyShow]::GetSystemMetrics(0)
    $h = [NotifyShow]::GetSystemMetrics(1)
    # Only move it if it is anywhere near where the card lands: no reason to
    # yank the pointer across the screen when it was already out of the way.
    $nearX = [Math]::Abs($p.X - $w / 2) -lt 260
    $nearY = $p.Y -gt ($h - 220)
    if ($nearX -and $nearY) {
      $restore = $p
      [void][NotifyShow]::SetCursorPos(40, 40)
      Start-Sleep -Milliseconds 120
    }
  }
}

[void][NotifyShow]::PostMessageW($hwnd, $msg, [IntPtr]$Rows, [IntPtr]::Zero)
Write-Output ("Card raised: {0} row(s). Chime: reminder.wav, fired on the uncloak." -f $Rows)
if ($restore) {
  Write-Output ("Pointer parked away from the landing zone (it was at {0},{1})." -f $restore.X, $restore.Y)
  Write-Output 'It stays parked until the card has gone - hovering holds a card open.'
  # 7 s life for a plain reminder, plus the entrance and the exit.
  Start-Sleep -Milliseconds 8200
  [void][NotifyShow]::SetCursorPos($restore.X, $restore.Y)
} elseif (-not $Stay) {
  Write-Output 'Pointer was already clear of the card.'
}
Write-Output ''
Write-Output 'Reminder: hovering the card cancels its dismissal clock on purpose.'
Write-Output 'To dismiss by hand: click the X at the top-left, or swipe it aside.'
