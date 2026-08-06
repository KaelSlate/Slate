# Crops a full-screen OBS recording down to the demo frame, so OBS itself needs
# no canvas or transform fiddling - record the whole screen and cut it here.
#
# ASCII only: a BOM-less .ps1 is read as ANSI by PowerShell 5.1, which mangles
# any non-ASCII byte and breaks the parser.
#
# Look at the framing first (instant, writes two PNGs next to the video):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\demo_crop.ps1 -Peek
#
# Happy with it? Cut the video:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\demo_crop.ps1
#
# Frame sitting wrong? Nudge one number and peek again:
#   ... -Peek -Y 240

param(
  # Video to cut. Empty = newest .mp4 on the Desktop.
  [string]$Source = '',

  # The crop rectangle, in real screen pixels. 1024x576 is 16:9 (what Twitter
  # shows largest) and leaves the pill about 59% of the frame width - big enough
  # to read the text it typed. Both numbers MUST stay even: H.264 cannot encode
  # an odd width or height.
  [int]$W = 1024,
  [int]$H = 576,
  [int]$X = 171,
  [int]$Y = 192,

  # Which second to sample for -Peek. Empty = 70% into the clip, which usually
  # lands on the pill with the phrase already typed.
  [double]$At = -1,

  # Only write the two preview PNGs and stop.
  [switch]$Peek,

  # Keep the whole recording instead of trimming to the measured performance.
  [switch]$NoTrim,

  # Upscale the finished clip before upload. X hands out bitrate by resolution
  # tier, so a 800x450 file lands in a low tier and gets squeezed harder than it
  # needs to be. Lanczos keeps the hard edges of UI text honest.
  #   -Scale 720   -> 1280x720      -Scale 1080 -> 1920x1080     0 = native
  [ValidateSet(0, 720, 1080)]
  [int]$Scale = 0,

  # 17 is visually lossless for screen content. Twitter re-encodes anyway, so
  # going lower buys nothing but disk.
  [int]$Crf = 17
)

$ErrorActionPreference = 'Stop'

# --- ffmpeg -----------------------------------------------------------------
# Never trust PATH here: winget drops its shims in a folder that an already-open
# terminal has never heard of, so look in the known places ourselves.
function Find-Tool([string]$exe) {
  $onPath = (Get-Command $exe -ErrorAction SilentlyContinue).Source
  if ($onPath) { return $onPath }

  $candidates = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\$exe.exe",
    "$env:ProgramFiles\ShareX\$exe.exe",
    "$env:ProgramFiles\ffmpeg\bin\$exe.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

  $pkgRoot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
  if (Test-Path $pkgRoot) {
    $hit = Get-ChildItem $pkgRoot -Filter "$exe.exe" -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

$ff = Find-Tool 'ffmpeg'
if (-not $ff) {
  Write-Host ''
  Write-Host 'ffmpeg not found anywhere. Install it, then run this again:' -ForegroundColor Yellow
  Write-Host ''
  Write-Host '    winget install Gyan.FFmpeg' -ForegroundColor Cyan
  Write-Host ''
  exit 1
}
$fp = Find-Tool 'ffprobe'
Write-Host ("ffmpeg : {0}" -f $ff) -ForegroundColor DarkGray

# --- pick the video ---------------------------------------------------------
if (-not $Source) {
  $roots = @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Videos")
  $newest = $roots | Where-Object { Test-Path $_ } |
            ForEach-Object { Get-ChildItem $_ -Filter *.mp4 -ErrorAction SilentlyContinue } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { Write-Host 'No .mp4 found on the Desktop or in Videos.' -ForegroundColor Red; exit 1 }
  $Source = $newest.FullName
}
if (-not (Test-Path $Source)) { Write-Host "Not found: $Source" -ForegroundColor Red; exit 1 }
$src = Get-Item $Source

# --- duration ---------------------------------------------------------------
$dur = 0.0
if ($fp) {
  $raw = & $fp -v error -show_entries format=duration -of csv=p=0 -- "$($src.FullName)" 2>$null
  [double]::TryParse(($raw -replace ',', '.'), [ref]$dur) | Out-Null
}
# --- timing left behind by demo_perform.ps1 ---------------------------------
# It knows exactly where in the file the scene sits, so the clip can be trimmed
# to the performance instead of keeping whatever dead air the hotkey left.
$trimStart = -1.0
$trimDur   = -1.0
$take = Join-Path $PSScriptRoot '.last_take.txt'
if ((Test-Path $take) -and -not $NoTrim) {
  $kv = @{}
  foreach ($line in Get-Content $take) {
    if ($line -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] }
  }
  $age = [DateTimeOffset]::Now.ToUnixTimeSeconds() - [int64]$kv['stamp']
  if ($age -lt 3600 -and $kv['durMs']) {
    # A little margin at each end absorbs the unknown lag between the hotkey
    # and OBS's first written frame. Both ends are rest frames anyway.
    $trimStart = [math]::Max(0, ([double]$kv['startMs'] - 250) / 1000.0)
    $trimDur   = ([double]$kv['durMs'] + 500) / 1000.0
    Write-Host ("trim   : from {0:N2}s for {1:N2}s  (measured by demo_perform)" -f $trimStart, $trimDur) -ForegroundColor DarkGray
  }
}

if ($At -lt 0) {
  $At = if ($trimStart -ge 0) { [math]::Round($trimStart + $trimDur * 0.72, 2) }
        elseif ($dur -gt 0.6) { [math]::Round($dur * 0.7, 2) }
        else { 0.3 }
}

Write-Host ''
Write-Host ("source : {0}  ({1:N2} MB, {2:N1}s)" -f $src.Name, ($src.Length / 1MB), $dur)
Write-Host ("crop   : {0}x{1} at x={2} y={3}" -f $W, $H, $X, $Y)

if (($W % 2) -ne 0 -or ($H % 2) -ne 0) {
  Write-Host 'Width and height must both be even for H.264.' -ForegroundColor Red
  exit 1
}

$dir  = $src.DirectoryName
$stem = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)

# --- peek: see the framing before spending time on a re-encode --------------
if ($Peek) {
  $boxPng  = Join-Path $dir "$stem`_peek_frame.png"
  $cropPng = Join-Path $dir "$stem`_peek_crop.png"

  # Same reason as the real cut: -ss after -i so the sampled frame is the one asked for.
  & $ff -y -v error -i "$($src.FullName)" -ss $At -frames:v 1 `
        -vf "drawbox=x=$X`:y=$Y`:w=$W`:h=$H`:color=yellow@0.9:t=4" "$boxPng"
  & $ff -y -v error -i "$($src.FullName)" -ss $At -frames:v 1 `
        -vf "crop=$W`:$H`:$X`:$Y" "$cropPng"

  Write-Host ''
  Write-Host ("sampled at {0}s" -f $At)
  Write-Host 'Open both and compare:' -ForegroundColor Green
  Write-Host ("  whole screen, crop outlined : {0}" -f $boxPng)
  Write-Host ("  what the crop will look like: {0}" -f $cropPng)
  Write-Host ''
  Write-Host 'Pill too low or cut off? Nudge -Y (smaller = frame moves up).'
  Write-Host 'Off to one side? Nudge -X (smaller = frame moves left).'
  Write-Host ''
  exit 0
}

# --- the real cut -----------------------------------------------------------
# Audio is dropped on purpose: OBS captures desktop sound, and a silent clip
# both avoids publishing whatever was playing and loops cleanly on Twitter.
$out = Join-Path $dir "$stem`_demo.mp4"

Write-Host 'cutting...'
# -ss goes AFTER -i on purpose. Before -i it is a keyframe seek, and OBS only
# writes a keyframe every 2 seconds - so the cut landed on the previous keyframe
# and left up to two seconds of dead air at the head. After -i it is exact.
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$ffArgs = @('-y', '-v', 'error', '-stats', '-i', $src.FullName)
if ($trimStart -ge 0) { $ffArgs += @('-ss', $trimStart.ToString($inv)) }
if ($trimDur -gt 0)   { $ffArgs += @('-t',  $trimDur.ToString($inv)) }
$filter = "crop=$W`:$H`:$X`:$Y"
$outW = $W; $outH = $H
if ($Scale -gt 0) {
  $outH = $Scale
  $outW = [int][math]::Round(($W / [double]$H) * $Scale / 2.0) * 2   # keep it even
  $filter += ",scale=$outW`:$outH`:flags=lanczos"
  Write-Host ("scale  : {0}x{1} -> {2}x{3} (lanczos)" -f $W, $H, $outW, $outH) -ForegroundColor DarkGray
}

$ffArgs += @(
  '-vf', $filter,
  '-c:v', 'libx264', '-preset', 'slow', '-crf', "$Crf", '-pix_fmt', 'yuv420p',
  '-movflags', '+faststart', '-an', $out
)
& $ff @ffArgs

if (-not (Test-Path $out)) { Write-Host 'ffmpeg produced nothing.' -ForegroundColor Red; exit 1 }
$o = Get-Item $out

Write-Host ''
Write-Host ('Done: {0}' -f $o.FullName) -ForegroundColor Green
Write-Host ('{0}x{1}, {2:N2} MB - drop this straight into Twitter.' -f $outW, $outH, ($o.Length / 1MB))
Write-Host ''
