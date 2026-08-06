# Composes the horizontal demo recording into a 1080x1920 vertical YouTube Short.
#
# The Short is built from the RAW screen recording, not from the finished 800x450
# clip - that way the footage is scaled exactly once instead of twice.
#
# ASCII only: a BOM-less .ps1 is read as ANSI by PowerShell 5.1, which mangles
# any non-ASCII byte and breaks the parser. Keep the text lines ASCII too.
#
# Look at the composition first (instant, writes one PNG next to the video):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\short_vertical.ps1 -Peek
#
# Happy with it? Render:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\short_vertical.ps1

param(
  # Recording to compose. Empty = newest .mp4 in Videos, then Desktop.
  # This wants the FULL-SCREEN capture, not the already-cropped 800x450 clip.
  [string]$Source = '',

  # The same crop rectangle demo_crop.ps1 uses. Both W and H must stay even.
  [int]$W = 800,
  [int]$H = 450,
  [int]$X = 283,
  [int]$Y = 314,

  # How wide the footage sits inside the 1080 frame. Ignored unless -Flat is set:
  # the card look derives its width from -Inset instead.
  [int]$VideoWidth = 1080,

  # The card. Footage sits inset from the edges with rounded corners, a soft drop
  # shadow and an ambient glow behind it, so it reads as an object in a space
  # rather than a rectangle pasted onto a fill. That difference is most of what
  # separates a considered frame from a placeholder one.
  [int]$Inset  = 44,
  [int]$Radius = 30,

  # Go back to the plain treatment: flat fill, square corners, no shadow.
  [switch]$Flat,

  # Where the middle of the footage lands vertically. 960 is dead centre; sitting
  # a little above it leaves room for the title and channel row YouTube paints
  # over the bottom of every Short.
  [int]$CenterY = 900,

  # One line above the footage and one below. Keep both ASCII, and keep colons
  # out of them - drawtext treats a colon as an option separator.
  [string]$TopText    = 'Alt+Space, anywhere in Windows',
  [string]$BottomText = 'Slate for Windows. Fully offline.',
  [int]$TopSize    = 54,
  [int]$BottomSize = 38,
  [int]$TopGap     = 190,   # px from the footage up to the top line
  [int]$BottomGap  = 110,   # px from the footage down to the bottom line

  # How many times the clip plays inside the file. The demo runs under 6s, and a
  # single pass is barely enough to understand it - the first pass reads as "what
  # is this", the second as "oh, I see". YouTube loops on top of this anyway.
  [int]$Loops = 2,

  # Trim to the performance. demo_choreo/demo_perform leave a note saying exactly
  # where in the file the scene starts, which is what removes the second and a half
  # of OBS warmup at the head. Without this the Short opens on a motionless cursor.
  [switch]$NoTrim,
  [double]$TrimStart = -1,   # seconds, overrides the measured value
  [double]$TrimDur   = -1,

  # Only write the composed still and stop.
  [switch]$Peek,

  # Which second to sample for -Peek. Empty = 72% in, which lands on the payoff.
  [double]$At = -1,

  [int]$Crf = 18
)

$ErrorActionPreference = 'Stop'

# The app's own palette, so the frame reads as an extension of the product
# rather than a black box someone dropped a video into.
$BG_HEX   = '15110D'   # AppTheme.background, deep warm graphite
$FG_TOP   = '0.80'     # AppTheme.textPrimary
$FG_BOT   = '0.50'     # AppTheme.textSecondary

# --- ffmpeg -----------------------------------------------------------------
# Never trust PATH: winget drops its shims in a folder an already-open terminal
# has never heard of.
function Find-Tool([string]$exe) {
  $onPath = (Get-Command $exe -ErrorAction SilentlyContinue).Source
  if ($onPath) { return $onPath }
  $candidates = @(
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\$exe.exe",
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
  Write-Host 'ffmpeg not found. Install it, then run this again:' -ForegroundColor Yellow
  Write-Host '    winget install Gyan.FFmpeg' -ForegroundColor Cyan
  exit 1
}
$fp = Find-Tool 'ffprobe'

# --- font -------------------------------------------------------------------
# drawtext wants a forward-slash path with the drive colon escaped, or it reads
# the colon as the start of the next filter option.
$fontFile = @(
  "$env:WINDIR\Fonts\seguisb.ttf",   # Segoe UI Semibold
  "$env:WINDIR\Fonts\segoeui.ttf",
  "$env:WINDIR\Fonts\arial.ttf"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $fontFile) { Write-Host 'No usable font found in the Windows font folder.' -ForegroundColor Red; exit 1 }
$fontArg = $fontFile.Replace('\', '/').Replace(':', '\:')

# --- pick the recording -----------------------------------------------------
if (-not $Source) {
  $roots = @("$env:USERPROFILE\Videos", "$env:USERPROFILE\Desktop")
  $newest = $roots | Where-Object { Test-Path $_ } |
            ForEach-Object { Get-ChildItem $_ -Filter *.mp4 -ErrorAction SilentlyContinue } |
            Where-Object { $_.Name -notmatch '_short|_demo' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { Write-Host 'No .mp4 found in Videos or on the Desktop.' -ForegroundColor Red; exit 1 }
  $Source = $newest.FullName
}
if (-not (Test-Path $Source)) { Write-Host "Not found: $Source" -ForegroundColor Red; exit 1 }
$src = Get-Item $Source

# --- geometry ---------------------------------------------------------------
if (($W % 2) -ne 0 -or ($H % 2) -ne 0) {
  Write-Host 'Crop width and height must both be even for H.264.' -ForegroundColor Red
  exit 1
}

# Two different files can legitimately land here: the raw full-screen capture,
# which still needs the crop, and the finished 800x450 clip, which is already
# framed. Measure the input and decide, instead of failing inside ffmpeg with
# "Invalid too big or non positive size for width/height".
$inW = 0; $inH = 0
if ($fp) {
  $wh = & $fp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 -- "$($src.FullName)" 2>$null
  if ("$wh" -match '(\d+)\s*,\s*(\d+)') { $inW = [int]$Matches[1]; $inH = [int]$Matches[2] }
}
$doCrop = $true
if ($inW -gt 0) {
  if (($X + $W) -gt $inW -or ($Y + $H) -gt $inH) {
    # The crop rectangle does not fit - this is the already-framed clip.
    $doCrop = $false
    $W = $inW; $H = $inH
  } elseif ($inW -eq $W -and $inH -eq $H -and $X -eq 0 -and $Y -eq 0) {
    $doCrop = $false
  }
}

$outW = if ($Flat) { $VideoWidth } else { 1080 - 2 * $Inset }
$outH = [int][math]::Round(($H / [double]$W) * $outW / 2.0) * 2         # even
$padY = [int][math]::Round(($CenterY - $outH / 2.0) / 2.0) * 2          # even
if ($padY -lt 0) { Write-Host 'CenterY is too small - the footage would run off the top.' -ForegroundColor Red; exit 1 }
if (($padY + $outH) -gt 1920) { Write-Host 'CenterY is too large - the footage would run off the bottom.' -ForegroundColor Red; exit 1 }

$padX  = [int](( 1080 - $outW ) / 2)
$topY  = $padY - $TopGap
$botY  = $padY + $outH + $BottomGap
if ($topY -lt 40) { Write-Host 'TopGap leaves no room above the footage.' -ForegroundColor Yellow }

# --- duration ---------------------------------------------------------------
$dur = 0.0
if ($fp) {
  $raw = & $fp -v error -show_entries format=duration -of csv=p=0 -- "$($src.FullName)" 2>$null
  [double]::TryParse(($raw -replace ',', '.'), [ref]$dur) | Out-Null
}
# --- where the performance actually sits in the file ------------------------
$take = Join-Path $PSScriptRoot '.last_take.txt'
if ((Test-Path $take) -and -not $NoTrim -and $TrimStart -lt 0) {
  $kv = @{}
  foreach ($line in Get-Content $take) { if ($line -match '^(\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } }
  $age = [DateTimeOffset]::Now.ToUnixTimeSeconds() - [int64]$kv['stamp']
  if ($age -lt 3600 -and $kv['durMs']) {
    # A little margin at each end absorbs the unknown lag between the hotkey and
    # OBS's first written frame. Both ends are rest frames anyway.
    $TrimStart = [math]::Max(0, ([double]$kv['startMs'] - 250) / 1000.0)
    $TrimDur   = ([double]$kv['durMs'] + 500) / 1000.0
  }
}
$doTrim = ($TrimStart -ge 0 -and -not $NoTrim)

if ($At -lt 0) {
  $At = if ($doTrim -and $TrimDur -gt 0) { [math]::Round($TrimStart + $TrimDur * 0.72, 2) }
        elseif ($dur -gt 0.6) { [math]::Round($dur * 0.72, 2) }
        else { 0.3 }
}

Write-Host ''
Write-Host ("source : {0}  ({1:N1}s)" -f $src.Name, $dur)
if ($doCrop) {
  Write-Host ("crop   : {0}x{1} at x={2} y={3}" -f $W, $H, $X, $Y)
} else {
  Write-Host ("crop   : none - input is already framed at {0}x{1}" -f $W, $H)
}
Write-Host ("frame  : 1080x1920, footage {0}x{1} at y={2}" -f $outW, $outH, $padY)
if ($doTrim) {
  Write-Host ("trim   : from {0:N2}s for {1:N2}s" -f $TrimStart, $TrimDur) -ForegroundColor DarkGray
} else {
  Write-Host 'trim   : none - the whole recording goes in, warmup and all' -ForegroundColor Yellow
}
Write-Host ("font   : {0}" -f [System.IO.Path]::GetFileName($fontFile))

# --- the filter chain -------------------------------------------------------
# crop -> scale -> pad onto the 1080x1920 canvas -> two text lines.
# Single quotes around each text value protect the commas from being read as
# filter separators.
function Text-Layer([string]$txt, [int]$size, [string]$alpha, [int]$y, [string]$tag) {
  if (-not $txt) { return '' }
  # The text goes through a file rather than inline. drawtext's quoting rules
  # make an apostrophe genuinely unsafe to pass in text=: escaping it either
  # swallows the character ("Didn't" -> "Didnt") or spills the filter options
  # into the drawn string. textfile= sidesteps the parser entirely, and it
  # accepts UTF-8, so non-ASCII lines work too.
  $p = Join-Path $env:TEMP ("slate_short_text_{0}.txt" -f $tag)
  [System.IO.File]::WriteAllText($p, $txt, (New-Object System.Text.UTF8Encoding($false)))
  $arg = $p.Replace('\', '/').Replace(':', '\:')
  return ",drawtext=fontfile='$fontArg':textfile='$arg':fontcolor=white@$alpha" +
         ":fontsize=$size" + ':x=(w-text_w)/2' + ":y=$y"
}

$textChain = (Text-Layer $TopText    $TopSize    $FG_TOP $topY 'top') +
             (Text-Layer $BottomText $BottomSize $FG_BOT $botY 'bot')

$cut = ''
if ($doCrop) { $cut = "crop=$W`:$H`:$X`:$Y," }

# --- the plates -------------------------------------------------------------
# The background and the corner mask are painted once with System.Drawing rather
# than fought for in filter syntax: a radial brush and a rounded path are three
# lines here and a nightmare in ffmpeg expressions.
function New-RoundedPath([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc(($x + $w - $d), $y, $d, $d, 270, 90)
  $p.AddArc(($x + $w - $d), ($y + $h - $d), $d, $d, 0, 90)
  $p.AddArc($x, ($y + $h - $d), $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

if ($Flat) {
  $filter  = $cut + "scale=$outW`:$outH`:flags=lanczos"
  $filter += ",pad=1080`:1920`:$padX`:$padY`:0x$BG_HEX"
  $filter += $textChain
  $vfArgs  = @('-vf', $filter)
  $extraIn = @()
} else {
  Add-Type -AssemblyName System.Drawing
  $bgPng   = Join-Path $env:TEMP 'slate_short_bg.png'
  $maskPng = Join-Path $env:TEMP 'slate_short_mask.png'

  $bg = New-Object System.Drawing.Bitmap(1080, 1920)
  $g  = [System.Drawing.Graphics]::FromImage($bg)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.ColorTranslator]::FromHtml("#$BG_HEX"))

  # Ambient light behind the card. Without it the fill reads as dead paper.
  $cx = $padX + $outW / 2.0
  $cy = $padY + $outH / 2.0
  $rad = 820
  $glow = New-Object System.Drawing.Drawing2D.GraphicsPath
  $glow.AddEllipse(($cx - $rad), ($cy - $rad), ($rad * 2), ($rad * 2))
  $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
  $pgb.CenterColor = [System.Drawing.ColorTranslator]::FromHtml('#2C2219')
  $pgb.SurroundColors = @([System.Drawing.ColorTranslator]::FromHtml("#$BG_HEX"))
  $g.FillPath($pgb, $glow)

  # Drop shadow, faked as concentric rounded rects at low alpha. System.Drawing
  # has no blur, but thirty stacked outlines give the same falloff for free.
  for ($i = 30; $i -ge 1; $i--) {
    $br = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(3, 0, 0, 0))
    $sp = New-RoundedPath ($padX - $i) ($padY - $i + 22) ($outW + 2*$i) ($outH + 2*$i) ($Radius + $i)
    $g.FillPath($br, $sp)
    $sp.Dispose(); $br.Dispose()
  }
  $bg.Save($bgPng, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bg.Dispose()

  $mk  = New-Object System.Drawing.Bitmap($outW, $outH)
  $g2  = [System.Drawing.Graphics]::FromImage($mk)
  $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g2.Clear([System.Drawing.Color]::Black)
  $rp = New-RoundedPath 0 0 $outW $outH $Radius
  $g2.FillPath([System.Drawing.Brushes]::White, $rp)
  $mk.Save($maskPng, [System.Drawing.Imaging.ImageFormat]::Png)
  $rp.Dispose(); $g2.Dispose(); $mk.Dispose()

  # -framerate 60 is load-bearing. A looped still defaults to 25fps, and since the
  # background is the MAIN input of the overlay it dictates the rate of the whole
  # composite - the 60fps capture would be resampled down to 25 and then padded
  # back up with duplicate frames. All the smoothness of the take, thrown away by
  # a default on a static image.
  $extraIn = @('-loop', '1', '-framerate', '60', '-i', $bgPng,
               '-loop', '1', '-framerate', '60', '-i', $maskPng)
  $fc  = "[0:v]$cut" + "scale=$outW`:$outH`:flags=lanczos,format=rgba[fg];"
  $fc += "[2:v]format=gray[mk];[fg][mk]alphamerge[card];"
  $fc += "[1:v][card]overlay=$padX`:$padY[c];[c]null$textChain[out]"
  $vfArgs = @('-filter_complex', $fc, '-map', '[out]')
}

$dir  = $src.DirectoryName
$stem = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)

# --- peek: see the composition before spending time on a render -------------
if ($Peek) {
  $png = Join-Path $dir "$stem`_short_peek.png"
  # -ss after -i so the sampled frame is the one asked for: before -i it is a
  # keyframe seek, and OBS only writes a keyframe every two seconds.
  $peekArgs = @('-y', '-v', 'error', '-i', $src.FullName) + $extraIn +
              @('-ss', "$At", '-frames:v', '1') + $vfArgs + @($png)
  & $ff @peekArgs
  if (-not (Test-Path $png)) { Write-Host 'ffmpeg produced nothing.' -ForegroundColor Red; exit 1 }
  Write-Host ''
  Write-Host ("sampled at {0}s" -f $At)
  Write-Host ('Open this: {0}' -f $png) -ForegroundColor Green
  Write-Host ''
  Write-Host 'Footage sitting too low? Lower -CenterY.  Text crowding it? Raise -TopGap.'
  Write-Host 'Want native-sharp pixels instead of the upscale? -VideoWidth 800'
  Write-Host ''
  exit 0
}

# --- render -----------------------------------------------------------------
$out = Join-Path $dir "$stem`_short.mp4"
$extra = [math]::Max(0, $Loops - 1)
$clipLen = if ($doTrim -and $TrimDur -gt 0) { $TrimDur } else { $dur }
$inv = [System.Globalization.CultureInfo]::InvariantCulture

Write-Host ("loops  : {0} passes ({1:N1}s total)" -f $Loops, ($clipLen * $Loops))
Write-Host 'rendering...'

# Two passes, because the trim cannot ride along with -stream_loop: looping happens
# on the INPUT, so -ss/-t would be measured against the already-looped stream and
# everything after the first cycle would be thrown away. Cut one clean cycle, then
# repeat the cut.
$one = Join-Path $env:TEMP 'slate_short_cycle.mp4'
$p1 = @('-y', '-v', 'error', '-stats', '-i', $src.FullName) + $extraIn
if ($doTrim) {
  # -ss goes AFTER -i deliberately. Before it, it is a keyframe seek, and OBS only
  # writes a keyframe every two seconds - the cut would land on the previous one
  # and leave the dead air it was supposed to remove.
  $p1 += @('-ss', $TrimStart.ToString('0.###', $inv))
  if ($TrimDur -gt 0) { $p1 += @('-t', $TrimDur.ToString('0.###', $inv)) }
}
$p1 += $vfArgs
# -shortest matters here: the background and mask are looped stills that never
# end on their own, so without it the encode would run forever.
$p1 += @('-c:v', 'libx264', '-preset', 'slow', '-crf', "$Crf",
         '-pix_fmt', 'yuv420p', '-r', '60', '-an', '-shortest', $one)
& $ff @p1
if (-not (Test-Path $one)) { Write-Host 'ffmpeg produced nothing.' -ForegroundColor Red; exit 1 }

# Pass two repeats the finished cycle by stream copy, so the loops cost nothing
# in quality and nothing in time.
if ($extra -gt 0) {
  & $ff -y -v error -fflags '+genpts' -stream_loop $extra -i $one -c copy -movflags '+faststart' $out
} else {
  & $ff -y -v error -i $one -c copy -movflags '+faststart' $out
}

if (-not (Test-Path $out)) { Write-Host 'ffmpeg produced nothing.' -ForegroundColor Red; exit 1 }
$o = Get-Item $out

Write-Host ''
Write-Host ('Done: {0}' -f $o.FullName) -ForegroundColor Green
Write-Host ('1080x1920, {0:N2} MB - upload this straight to YouTube Shorts.' -f ($o.Length / 1MB))
Write-Host ''
