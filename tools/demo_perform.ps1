# Performs the Slate capture demo with frame-exact timing so nobody has to
# hand-play it. Run it, keep your hands off the keyboard, and record.
#
# ASCII only on purpose: a BOM-less .ps1 is read as ANSI by PowerShell 5.1,
# which corrupts any non-ASCII character and breaks the parser.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\demo_perform.ps1 -RecKey ScrollLock
#
# Use ScrollLock (or Pause) for the OBS hotkey, NOT F9: VS Code binds F9 to
# "toggle breakpoint", so it both fights for the key and drops a red dot into
# the frame. Nothing on Windows uses ScrollLock.
#
# Tune the numbers below; every value is milliseconds.

param(
  # Seconds of dead air before the performance starts. Use it to hit the shot:
  # click the window you want in frame and get your hands off the keys.
  [int]$LeadIn = 8,

  # OBS "Start Recording" AND "Stop Recording" hotkey, bound to the SAME key so
  # it toggles. Empty = you start and stop the recording yourself.
  #
  # Chords work: 'Ctrl+Alt+F12' is the safe default pick. A bare F-key is a bad
  # idea (VS Code owns F9 for breakpoints, F12 for go-to-definition), and
  # ScrollLock/Pause do not exist on compact keyboards at all.
  [string]$RecKey = '',

  # How long OBS needs to actually open the file after the hotkey. Too short and
  # the first frames are lost, or the stop press lands mid-transition.
  [int]$ObsWarmup = 1500,

  # The rest frames at head and tail. The clip LOOPS, so these two merge into a
  # single pause between cycles - together they should read as one short breath,
  # not as dead air. 350 + 450 = 0.8s between repeats.
  [int]$RestHead = 350,
  [int]$RestTail = 450,

  # How long the pill's spring animation needs before typing may start.
  [int]$PillSettle = 500,

  # Per-character typing speed and its jitter. ~100ms reads as confident.
  [int]$KeyDelay = 100,
  [int]$KeyJitter = 20,

  # The beat held before each word that changes the destination chip.
  [int]$Beat = 300,

  # The money frame: how long "-> Tomorrow 18:00" sits still before Enter.
  # The one value never to shorten - it is the whole point of the clip.
  [int]$Payoff = 1000
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace Slate -Name Kb -MemberDefinition @'
  [DllImport("user32.dll")]
  public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@

$VK = @{
  Alt        = 0x12
  Ctrl       = 0x11
  Control    = 0x11
  Shift      = 0x10
  Space      = 0x20
  Return     = 0x0D
  ScrollLock = 0x91
  Pause      = 0x13
  Insert     = 0x2D
  Home       = 0x24
  End        = 0x23
}
1..12 | ForEach-Object { $VK["F$_"] = 0x6F + $_ }   # F1 = 0x70 .. F12 = 0x7B
$KEYUP = 0x02

function Key-Down([byte]$vk) { [Slate.Kb]::keybd_event($vk, 0, 0,      [UIntPtr]::Zero) }
function Key-Up  ([byte]$vk) { [Slate.Kb]::keybd_event($vk, 0, $KEYUP, [UIntPtr]::Zero) }

function Send-Tap([byte]$vk) {
  Key-Down $vk; Start-Sleep -Milliseconds 55; Key-Up $vk
}

function Send-Chord([byte]$mod, [byte]$vk) {
  Key-Down $mod; Start-Sleep -Milliseconds 30
  Key-Down $vk;  Start-Sleep -Milliseconds 45
  Key-Up   $vk;  Start-Sleep -Milliseconds 30
  Key-Up   $mod
}

# Sends anything written as "F12", "ScrollLock" or "Ctrl+Alt+F12".
# Modifiers go down in order and come back up in reverse, the way a hand does it.
function Send-Hotkey([string]$spec) {
  # @() is load-bearing: a one-element pipeline collapses to a bare string, and
  # then $parts[-1] would hand back its last CHARACTER instead of the key name.
  $parts = @($spec.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $main  = $parts[-1]
  $mods  = if ($parts.Count -gt 1) { $parts[0..($parts.Count - 2)] } else { @() }

  foreach ($p in $parts) {
    if (-not $VK.ContainsKey($p)) { throw "Unknown key '$p' in hotkey '$spec'." }
  }

  foreach ($m in $mods) { Key-Down $VK[$m]; Start-Sleep -Milliseconds 25 }
  Key-Down $VK[$main];   Start-Sleep -Milliseconds 55
  Key-Up   $VK[$main];   Start-Sleep -Milliseconds 25
  for ($i = $mods.Count - 1; $i -ge 0; $i--) { Key-Up $VK[$mods[$i]]; Start-Sleep -Milliseconds 20 }
}

# Types one chunk a character at a time. SendKeys is safe here because the
# phrase holds only lowercase letters, digits and spaces - none of the
# characters SendKeys treats as syntax (+ ^ % ~ ( ) { } [ ]).
function Type-Chunk([string]$text) {
  foreach ($ch in $text.ToCharArray()) {
    [System.Windows.Forms.SendKeys]::SendWait([string]$ch)
    $wait = $KeyDelay + (Get-Random -Minimum (-$KeyJitter) -Maximum $KeyJitter)
    if ($wait -lt 40) { $wait = 40 }
    Start-Sleep -Milliseconds $wait
  }
}

# The phrase, split at every point where the destination chip changes.
# Chip reads:  "gym" -> Inbox    "tomorrow" -> Tomorrow    "6pm" -> Tomorrow 18:00
$chunks = @('gym', ' tomorrow', ' at 6pm')

Write-Host ''
Write-Host 'Slate demo performance' -ForegroundColor Yellow
Write-Host '----------------------'
Write-Host ("lead-in    : {0}s" -f $LeadIn)
Write-Host ("phrase     : {0}" -f ($chunks -join ''))
Write-Host ("obs hotkey : {0}" -f $(if ($RecKey) { $RecKey } else { '(you start/stop it yourself)' }))
if ($RecKey -and $RecKey -notmatch '\+') {
  Write-Host "WARNING: a bare key is risky - VS Code owns F9 and F12. Prefer Ctrl+Alt+F12." -ForegroundColor Red
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
Write-Host 'TAKE YOUR HANDS OFF THE KEYBOARD.' -ForegroundColor Cyan
Write-Host ''

for ($i = $LeadIn; $i -gt 0; $i--) {
  Write-Host ("  {0}" -f $i)
  Start-Sleep -Seconds 1
}

# --- the performance -------------------------------------------------------
# The stopwatch starts the instant the recording hotkey goes out, so we can
# tell the crop script exactly where in the file the scene sits.
$sw = [System.Diagnostics.Stopwatch]::StartNew()

if ($RecKey) {
  Send-Hotkey $RecKey
  Start-Sleep -Milliseconds $ObsWarmup      # let OBS actually open the file
}

$clipStart = $sw.ElapsedMilliseconds

Start-Sleep -Milliseconds $RestHead          # rest frame (matches the tail)

Send-Chord $VK.Alt $VK.Space                 # Alt+Space: the pill flies up
Start-Sleep -Milliseconds $PillSettle        # let its spring finish

for ($i = 0; $i -lt $chunks.Count; $i++) {
  Type-Chunk $chunks[$i]
  if ($i -lt $chunks.Count - 1) { Start-Sleep -Milliseconds $Beat }
}

Start-Sleep -Milliseconds $Payoff            # hold on "-> Tomorrow 18:00"
Send-Tap $VK.Return                          # it lands; the pill dismisses
Start-Sleep -Milliseconds $RestTail          # rest frame closes the loop

$clipEnd = $sw.ElapsedMilliseconds

if ($RecKey) {
  Start-Sleep -Milliseconds 500               # never toggle mid-transition
  Send-Hotkey $RecKey
}
$sw.Stop()

# --- hand the timing to the crop script ------------------------------------
$take = Join-Path $PSScriptRoot '.last_take.txt'
@(
  "stamp=$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
  "startMs=$clipStart"
  "durMs=$($clipEnd - $clipStart)"
  "reckey=$RecKey"
) | Set-Content -Path $take -Encoding ASCII

Write-Host ''
Write-Host ('Scene runs {0:N1}s, starting {1:N1}s into the recording.' -f (($clipEnd - $clipStart) / 1000.0), ($clipStart / 1000.0)) -ForegroundColor Green
if (-not $RecKey) { Write-Host 'Stop the recording now.' -ForegroundColor Cyan }
Write-Host 'Next: tools\demo_crop.ps1 -Peek'
Write-Host ''
