# Performs the Slate demo as a choreographed scene: the pill springs in on camera,
# the phrase is typed on a fixed clock, and the cursor travels on an eased curve
# instead of by hand.
#
# The cursor is the whole point. A hand-moved mouse jerks, overshoots and pauses
# in the wrong places, and that single thing is most of what makes a screen
# recording read as amateur. Here every move accelerates, decelerates and settles.
#
# ASCII only: a BOM-less .ps1 is read as ANSI by PowerShell 5.1, which mangles
# any non-ASCII byte and breaks the parser.
#
# 1. Find the coordinates you need (hover, read, Ctrl+C to stop):
#      powershell -NoProfile -ExecutionPolicy Bypass -File tools\demo_choreo.ps1 -Probe
#
# 2. Watch the cursor walk the path, with no typing, clicking or recording:
#      ... -Calibrate -BlockX 640 -BlockY 430 -DropX 900 -DropY 430
#
# 3. Shoot it:
#      ... -RecKey Ctrl+Alt+F12 -BlockX 640 -BlockY 430 -DropX 900 -DropY 430
#
# Then crop as usual: tools\demo_crop.ps1 -Peek

param(
  # Seconds of dead air before the scene starts. Click the window you want in
  # frame, then take your hands off everything.
  [int]$LeadIn = 8,

  # OBS start/stop hotkey, bound to the same key so it toggles. Empty = you do it.
  # A bare F-key is a bad idea: VS Code owns F9 and F12.
  [string]$RecKey = '',
  [int]$ObsWarmup = 1500,

  # The phrase, split at every point where the destination chip changes.
  # Default lands the task on TODAY on purpose - the drag beat can only work if
  # the new task is actually visible on the day you are looking at. Record before
  # 18:00 or the chip rolls it to tomorrow and the block never appears.
  [string[]]$Chunks = @('gym', ' at 6pm'),

  # Where the cursor sits when the shot opens. Left at 0 it is derived from the
  # block: a short reach up and to the left. Far enough that the approach reads as
  # a real move, close enough that it looks like someone already working here
  # rather than a pointer flying in from off screen.
  #
  # The cursor is placed here BEFORE the recording starts, so getting there is
  # never on camera. The old version parked in a corner and then dragged itself
  # back across the whole screen, which was a pointless trip and it opened the
  # clip with the cursor moving away from the subject.
  [int]$StartX = 0,
  [int]$StartY = 0,

  # The task block once it has landed on the timeline. Find it with -Probe.
  # Leave at 0 and the drag beat is skipped entirely.
  [int]$BlockX = 0,
  [int]$BlockY = 0,

  # Where to drag it. Leave at 0 and the drag beat is skipped.
  [int]$DropX = 0,
  [int]$DropY = 0,

  # Rest frames. The clip loops, so head and tail merge into one pause between
  # cycles - together they should read as a single breath.
  [int]$RestHead = 400,
  [int]$RestTail = 550,

  # How long the pill's spring needs before typing may start. The spring is now
  # ON CAMERA, so this also decides how much of it the viewer gets to see.
  [int]$PillSettle = 620,

  # Typing speed and its jitter. ~100ms reads as confident rather than robotic.
  [int]$KeyDelay = 100,
  [int]$KeyJitter = 20,

  # The beat held before each word that changes the chip.
  [int]$Beat = 300,

  # How long the resolved chip sits still before Enter. Never shorten this.
  [int]$Payoff = 950,

  # How long the task needs to land and finish animating after Enter.
  [int]$LandSettle = 800,

  # Cursor choreography, all milliseconds. The whole gesture now runs about 1.15s
  # against the 2.3s it used to take. A person reaching for something on screen and
  # moving it does it in roughly a second - slower than that stops reading as a
  # person and starts reading as a demo being performed at you.
  [int]$ReachMs  = 460,    # travel to the block. Tuned for a ~580px crossing.
  [int]$SettleMs = 90,     # land on it before pressing. A beat, not a hover.
  [int]$GripMs   = 130,    # press, then let the grab register before moving

  # Deliberately cross the drag threshold before the real travel begins. Gesture
  # recognisers ignore movement under a few pixels of slop, and a curve that eases
  # out of the start as gently as this one can sit inside that slop long enough to
  # be read as a click. A short decisive nudge first removes all doubt.
  [int]$SlopPx = 16,
  [int]$SlopMs = 70,

  # How far each path bows off the straight line, in pixels. A straight line is
  # the giveaway of synthetic motion: a hand always arcs, and "arcs" is one of the
  # oldest principles of animation for exactly that reason. The bow also decides
  # which side of the screen the cursor travels along, so it is what keeps the
  # approach from cutting through the other tasks.
  #
  # Flip the sign to bow the other way. -Calibrate draws the path so you can see
  # which side it picked before committing to a take.
  # +90 was measured, not guessed: it puts the control point level with the target
  # row, so the cursor climbs to the right height out in the empty columns and
  # enters the day horizontally instead of cutting up through its neighbours.
  # 60..150 is the safe band for this layout; 180 starts clipping the task above.
  [double]$ReachArc = 90,
  [double]$DragArc  = 30,

  [int]$DragMs   = 300,    # carry it. Short on purpose - a person moves fast here.
  [int]$HoldMs   = 140,    # sit still so the snap reads before letting go
  [int]$AfterMs  = 520,    # stay put and let the result be seen

  # Shoot only the drag: no hotkey, no typing, no Enter. One idea per clip beats
  # a clip that creates a task and then immediately moves it, which reads as a
  # pointless action and muddies both ideas.
  [switch]$SkipCapture,

  # Print the cursor position in a loop and exit. Ctrl+C to stop.
  [switch]$Probe,

  # Walk the path with no typing, no clicking and no recording.
  [switch]$Calibrate
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

# Everything goes through SendInput on purpose.
#
# SetCursorPos moves the pointer WITHOUT passing through the input queue, while
# button events go THROUGH it. An app therefore receives the movement and the
# press by two different routes with no ordering guarantee between them, and a
# drag falls apart: the press lands, the moves arrive out of band, and the
# gesture is read as a click. SendInput puts moves and buttons into the same
# ordered stream, exactly where real hardware input goes.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SlateInput {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData;
    public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT { public uint type; public MOUSEINPUT mi; }
  public static class Native {
    public const uint INPUT_MOUSE = 0;
    public const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004;
    public const uint ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int  GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    // SendInput takes absolute coordinates normalised to 0..65535 across the
    // whole virtual desktop, not pixels - hence the conversion.
    public static void MoveTo(int x, int y) {
      int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
      int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
      if (vw < 2) vw = 2;
      if (vh < 2) vh = 2;
      INPUT[] inp = new INPUT[1];
      inp[0].type = INPUT_MOUSE;
      inp[0].mi.dx = (int)Math.Round((x - vx) * 65535.0 / (vw - 1));
      inp[0].mi.dy = (int)Math.Round((y - vy) * 65535.0 / (vh - 1));
      inp[0].mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
      SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Button(uint flag) {
      INPUT[] inp = new INPUT[1];
      inp[0].type = INPUT_MOUSE;
      inp[0].mi.dwFlags = flag;
      SendInput(1, inp, Marshal.SizeOf(typeof(INPUT)));
    }
  }
}
'@

$KEYUP = 0x02

$VK = @{
  Alt = 0x12; Ctrl = 0x11; Control = 0x11; Shift = 0x10
  Space = 0x20; Return = 0x0D; ScrollLock = 0x91; Pause = 0x13
  Insert = 0x2D; Home = 0x24; End = 0x23
}
1..12 | ForEach-Object { $VK["F$_"] = 0x6F + $_ }   # F1 = 0x70 .. F12 = 0x7B

# --- cursor -----------------------------------------------------------------
function Get-Cursor {
  $p = New-Object SlateInput.POINT
  [void][SlateInput.Native]::GetCursorPos([ref]$p)
  return $p
}

# Motion curves, written the way a designer writes them: a cubic bezier given by
# its two control points, exactly like CSS cubic-bezier() or a keyframe handle.
#
# REACH is deliberately asymmetric - quick out of the gate, then a long
# deceleration into the target. That is the profile a hand actually makes going
# for something: it accelerates over roughly the first third and brakes the rest
# of the way. The symmetric ease-in-out this replaced started slow, and a slow
# start is exactly what reads as hesitant rather than deliberate.
$CURVE_REACH = @(0.32, 0.00, 0.12, 1.00)
# CARRY is softer at both ends. You are holding something, not swatting it.
$CURVE_CARRY = @(0.40, 0.00, 0.20, 1.00)

# Cubic bezier easing with P0=(0,0) and P3=(1,1). The curve gives x as a function
# of its own parameter, so the parameter has to be solved for before y can be
# read: Newton first, clamped, with the loop bailing out if the derivative goes
# flat. Eight iterations is far more than this ever needs.
function Ease([double]$t, [double[]]$c) {
  if ($t -le 0) { return 0.0 }
  if ($t -ge 1) { return 1.0 }
  $x1 = $c[0]; $y1 = $c[1]; $x2 = $c[2]; $y2 = $c[3]
  $u = $t
  for ($i = 0; $i -lt 8; $i++) {
    $mu = 1.0 - $u
    $x  = 3.0*$mu*$mu*$u*$x1 + 3.0*$mu*$u*$u*$x2 + $u*$u*$u
    $d  = $x - $t
    if ([math]::Abs($d) -lt 1e-6) { break }
    $dx = 3.0*$mu*$mu*$x1 + 6.0*$mu*$u*($x2-$x1) + 3.0*$u*$u*(1.0-$x2)
    if ([math]::Abs($dx) -lt 1e-6) { break }
    $u = $u - $d / $dx
    if ($u -lt 0.0) { $u = 0.0 } elseif ($u -gt 1.0) { $u = 1.0 }
  }
  $mu = 1.0 - $u
  return 3.0*$mu*$mu*$u*$y1 + 3.0*$mu*$u*$u*$y2 + $u*$u*$u
}

# Position is computed from REAL elapsed time, not from the step index. PowerShell
# cannot sleep accurately in single milliseconds, so driving it off the clock keeps
# the motion on the intended curve even when the sleeps come back uneven.
function Move-Cursor([int]$toX, [int]$toY, [int]$ms, [double[]]$curve, [double]$arc = 0) {
  if (-not $curve) { $curve = $CURVE_REACH }
  $from = Get-Cursor
  $ax = [double]$from.X; $ay = [double]$from.Y
  $dx = $toX - $ax;      $dy = $toY - $ay
  $len = [math]::Sqrt($dx*$dx + $dy*$dy)

  # Control point of a quadratic bezier: the midpoint of the straight line,
  # pushed out along its perpendicular. Easing shapes the SPEED along the path;
  # this shapes the PATH itself.
  $cx = $ax + $dx / 2.0
  $cy = $ay + $dy / 2.0
  if ($len -gt 1.0 -and $arc -ne 0.0) {
    $cx = $cx - ($dy / $len) * $arc
    $cy = $cy + ($dx / $len) * $arc
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.ElapsedMilliseconds -lt $ms) {
    $s = Ease ($sw.ElapsedMilliseconds / [double]$ms) $curve
    $m = 1.0 - $s
    $x = [int][math]::Round($m*$m*$ax + 2.0*$m*$s*$cx + $s*$s*$toX)
    $y = [int][math]::Round($m*$m*$ay + 2.0*$m*$s*$cy + $s*$s*$toY)
    [SlateInput.Native]::MoveTo($x, $y)
    Log-Path $x $y
    Start-Sleep -Milliseconds 8
  }
  [SlateInput.Native]::MoveTo($toX, $toY)   # land exactly
  Log-Path $toX $toY
  $sw.Stop()
}

# Put the cursor somewhere with no animation at all. Used only before the camera
# is rolling, so the trip to the opening position never appears in the clip.
function Set-Cursor([int]$x, [int]$y) { [SlateInput.Native]::MoveTo($x, $y) }

function Mouse-Down { [SlateInput.Native]::Button([SlateInput.Native]::LEFTDOWN) }
function Mouse-Up   { [SlateInput.Native]::Button([SlateInput.Native]::LEFTUP) }

# --- keyboard ---------------------------------------------------------------
function Key-Down([byte]$vk) { [SlateInput.Native]::keybd_event($vk, 0, 0,      [UIntPtr]::Zero) }
function Key-Up  ([byte]$vk) { [SlateInput.Native]::keybd_event($vk, 0, $KEYUP, [UIntPtr]::Zero) }

function Send-Tap([byte]$vk) { Key-Down $vk; Start-Sleep -Milliseconds 55; Key-Up $vk }

function Send-Chord([byte]$mod, [byte]$vk) {
  Key-Down $mod; Start-Sleep -Milliseconds 30
  Key-Down $vk;  Start-Sleep -Milliseconds 45
  Key-Up   $vk;  Start-Sleep -Milliseconds 30
  Key-Up   $mod
}

# Accepts "F12", "ScrollLock" or "Ctrl+Alt+F12". Modifiers go down in order and
# come back up in reverse, the way a hand does it.
function Send-Hotkey([string]$spec) {
  # @() is load-bearing: a one-element pipeline collapses to a bare string, and
  # then $parts[-1] would hand back its last CHARACTER instead of the key name.
  $parts = @($spec.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $main  = $parts[-1]
  $mods  = if ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] } else { @() }
  foreach ($p in $parts) { if (-not $VK.ContainsKey($p)) { throw "Unknown key '$p' in hotkey '$spec'." } }
  foreach ($m in $mods) { Key-Down $VK[$m]; Start-Sleep -Milliseconds 25 }
  Key-Down $VK[$main];   Start-Sleep -Milliseconds 55
  Key-Up   $VK[$main];   Start-Sleep -Milliseconds 25
  for ($i = $mods.Count - 1; $i -ge 0; $i--) { Key-Up $VK[$mods[$i]]; Start-Sleep -Milliseconds 20 }
}

# --- the beat log -----------------------------------------------------------
# Every event is stamped against the same stopwatch that drives the scene, so the
# soundtrack can later be built from the exact same clock the performance ran on.
$script:sw     = $null
$script:beats  = New-Object System.Collections.Generic.List[string]
function Mark([string]$kind) {
  if ($script:sw) { $script:beats.Add(('{0}:{1}' -f $kind, $script:sw.ElapsedMilliseconds)) }
}

# Every cursor position this script sets, stamped against the scene clock. This is
# what makes a drawn-on pointer possible later: the exact path is known because we
# are the ones who drew it. A hand-held take cannot be given one - there is nothing
# to read the trajectory from.
$script:path = New-Object System.Collections.Generic.List[string]
function Log-Path([int]$x, [int]$y) {
  if ($script:sw) { $script:path.Add(('{0},{1},{2}' -f $script:sw.ElapsedMilliseconds, $x, $y)) }
}

# SendKeys is safe for this phrase: only lowercase letters, digits and spaces,
# none of the characters it treats as syntax (+ ^ % ~ ( ) { } [ ]).
function Type-Chunk([string]$text) {
  foreach ($ch in $text.ToCharArray()) {
    [System.Windows.Forms.SendKeys]::SendWait([string]$ch)
    Mark 'key'
    $wait = $KeyDelay + (Get-Random -Minimum (-$KeyJitter) -Maximum $KeyJitter)
    if ($wait -lt 40) { $wait = 40 }
    Start-Sleep -Milliseconds $wait
  }
}

# --- probe ------------------------------------------------------------------
if ($Probe) {
  Write-Host ''
  Write-Host 'Hover over the thing you need and read the numbers. Ctrl+C to stop.' -ForegroundColor Cyan
  Write-Host 'These are physical screen pixels, the same space the script sets.' -ForegroundColor DarkGray
  Write-Host ''
  while ($true) {
    $p = Get-Cursor
    Write-Host ("`r  X = {0,5}   Y = {1,5}   " -f $p.X, $p.Y) -NoNewline
    Start-Sleep -Milliseconds 250
  }
}

$doDrag = ($BlockX -gt 0 -and $BlockY -gt 0 -and $DropX -gt 0 -and $DropY -gt 0)

# A short reach up and to the left of the block, unless told otherwise.
if ($doDrag) {
  if ($StartX -le 0) { $StartX = [math]::Max(8, $BlockX - 200) }
  if ($StartY -le 0) { $StartY = [math]::Max(8, $BlockY - 140) }
}

# --- calibrate --------------------------------------------------------------
if ($Calibrate) {
  Write-Host ''
  Write-Host 'Calibration walk: no typing, no clicks, no recording.' -ForegroundColor Yellow
  if (-not $doDrag) {
    Write-Host 'BlockX/BlockY/DropX/DropY are not all set, so there is no path to walk.' -ForegroundColor Red
    Write-Host 'Find them with -Probe first.'
    exit 1
  }
  Write-Host ("opens at {0},{1}" -f $StartX, $StartY) -ForegroundColor DarkGray
  Write-Host '3'; Start-Sleep -Seconds 1
  Write-Host '2'; Start-Sleep -Seconds 1
  Write-Host '1'; Start-Sleep -Seconds 1
  Set-Cursor $StartX $StartY
  Start-Sleep -Milliseconds 400
  Write-Host ("reach... (arc {0})" -f $ReachArc)
  Move-Cursor $BlockX $BlockY $ReachMs $CURVE_REACH $ReachArc
  Start-Sleep -Milliseconds ($SettleMs + $GripMs)
  Write-Host ("carry... (arc {0})" -f $DragArc)
  Move-Cursor $DropX $DropY $DragMs $CURVE_CARRY $DragArc
  Start-Sleep -Milliseconds $HoldMs
  Write-Host ''
  Write-Host 'Landed where it should have? Then shoot it with -RecKey.' -ForegroundColor Green
  Write-Host 'Missed? Adjust the numbers and walk it again.' -ForegroundColor Green
  Write-Host ''
  exit 0
}

# --- announce ---------------------------------------------------------------
Write-Host ''
Write-Host 'Slate choreographed demo' -ForegroundColor Yellow
Write-Host '------------------------'
Write-Host ("lead-in    : {0}s" -f $LeadIn)
Write-Host ("phrase     : {0}" -f $(if ($SkipCapture) { 'SKIPPED (drag-only clip)' } else { $Chunks -join '' }))
Write-Host ("drag beat  : {0}" -f $(if ($doDrag) { "$BlockX,$BlockY -> $DropX,$DropY" } else { 'SKIPPED (no coordinates)' }))
Write-Host ("obs hotkey : {0}" -f $(if ($RecKey) { $RecKey } else { '(you start/stop it yourself)' }))
if ($RecKey -and $RecKey -notmatch '\+') {
  Write-Host 'WARNING: a bare key is risky - VS Code owns F9 and F12. Prefer Ctrl+Alt+F12.' -ForegroundColor Red
}
# Fail on a typo now, not eight seconds from now with the recording already rolling.
if ($RecKey) {
  foreach ($p in ($RecKey.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if (-not $VK.ContainsKey($p)) {
      Write-Host ("Unknown key '{0}' in -RecKey '{1}'." -f $p, $RecKey) -ForegroundColor Red
      Write-Host ('Known: {0}' -f (($VK.Keys | Sort-Object) -join ', '))
      exit 1
    }
  }
}
Write-Host ''
Write-Host 'Now: click the window you want in frame, then'
Write-Host 'TAKE YOUR HANDS OFF THE KEYBOARD AND THE MOUSE.' -ForegroundColor Cyan
Write-Host ''

for ($i = $LeadIn; $i -gt 0; $i--) { Write-Host ("  {0}" -f $i); Start-Sleep -Seconds 1 }

# Place the cursor before rolling, with no animation: the trip to the opening
# position must never appear in the clip.
if ($doDrag) { Set-Cursor $StartX $StartY; Start-Sleep -Milliseconds 250 }

# --- the scene --------------------------------------------------------------
$script:sw = [System.Diagnostics.Stopwatch]::StartNew()

if ($RecKey) {
  Send-Hotkey $RecKey
  Start-Sleep -Milliseconds $ObsWarmup     # let OBS actually open the file
}

$clipStart = $script:sw.ElapsedMilliseconds
Mark 'start'
# Seed the path with where the cursor already is, so a drawn pointer knows where
# to sit through the opening rest frames, when nothing is moving it.
$p0 = Get-Cursor
Log-Path $p0.X $p0.Y

Start-Sleep -Milliseconds $RestHead        # rest frame (matches the tail)

if (-not $SkipCapture) {
  # Beat 1 - the pill springs in ON CAMERA. The old take began with it already up,
  # which threw away the best piece of motion the product has.
  Mark 'summon'
  Send-Chord $VK.Alt $VK.Space
  Start-Sleep -Milliseconds $PillSettle

  # Beat 2 - the phrase, with a held beat wherever the chip changes.
  for ($i = 0; $i -lt $Chunks.Count; $i++) {
    Type-Chunk $Chunks[$i]
    if ($i -lt $Chunks.Count - 1) { Mark 'chip'; Start-Sleep -Milliseconds $Beat }
  }
  Mark 'chip'
  Start-Sleep -Milliseconds $Payoff        # hold on the resolved chip

  # Beat 3 - it lands.
  Mark 'enter'
  Send-Tap $VK.Return
  Start-Sleep -Milliseconds $LandSettle
}

# Beat 4 - direct manipulation. The cursor glides in, takes the block, carries it
# to another hour and sets it down.
if ($doDrag) {
  Mark 'reach'
  Move-Cursor $BlockX $BlockY $ReachMs $CURVE_REACH $ReachArc
  Start-Sleep -Milliseconds $SettleMs      # land on it, one beat, then take it
  Mark 'grab'
  Mouse-Down
  Start-Sleep -Milliseconds $GripMs
  $nx = $BlockX + [math]::Sign($DropX - $BlockX) * $SlopPx
  $ny = $BlockY + [math]::Sign($DropY - $BlockY) * $SlopPx
  Move-Cursor $nx $ny $SlopMs $CURVE_CARRY 0   # break the slop dead straight
  Move-Cursor $DropX $DropY $DragMs $CURVE_CARRY $DragArc
  Start-Sleep -Milliseconds $HoldMs        # let the snap read before letting go
  Mark 'drop'
  Mouse-Up
  # No trip back to a corner. Stillness after the action is the right ending:
  # the cursor stays where it put the thing, and the result is what you look at.
  Start-Sleep -Milliseconds $AfterMs
}

Start-Sleep -Milliseconds $RestTail        # rest frame closes the loop
$clipEnd = $script:sw.ElapsedMilliseconds
Mark 'end'

if ($RecKey) {
  Start-Sleep -Milliseconds 500            # never toggle mid-transition
  Send-Hotkey $RecKey
}
$script:sw.Stop()

# --- hand the timing on --------------------------------------------------------
# demo_crop.ps1 reads stamp/startMs/durMs to trim. The beats line is for the
# soundtrack: every keystroke, every chip change and every landing, stamped
# against the same clock that performed them.
$take = Join-Path $PSScriptRoot '.last_take.txt'
@(
  "stamp=$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
  "startMs=$clipStart"
  "durMs=$($clipEnd - $clipStart)"
  "reckey=$RecKey"
  "beats=$($script:beats -join ',')"
) | Set-Content -Path $take -Encoding ASCII

# The cursor trajectory goes in its own file - it is hundreds of lines, and it has
# a different consumer than the beat list.
$pathFile = Join-Path $PSScriptRoot '.last_path.txt'
$script:path | Set-Content -Path $pathFile -Encoding ASCII

Write-Host ''
Write-Host ('Scene runs {0:N1}s, starting {1:N1}s into the recording.' -f (($clipEnd - $clipStart) / 1000.0), ($clipStart / 1000.0)) -ForegroundColor Green
Write-Host ('{0} beats logged for the soundtrack.' -f $script:beats.Count) -ForegroundColor DarkGray
if (-not $RecKey) { Write-Host 'Stop the recording now.' -ForegroundColor Cyan }
Write-Host 'Next: tools\demo_crop.ps1 -Peek'
Write-Host ''
