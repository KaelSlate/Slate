# Composes a hand-shot recording into a 1080x1920 Short WITHOUT letterboxing.
#
# The other script (short_vertical.ps1) puts the footage in a card and writes a
# line above and below it. That format exists because a horizontal capture cannot
# fill a vertical frame. When the action happens to be confined to a tall region
# of the screen - two day columns, the pill, a single pane - it does not apply:
# crop that region at 9:16 and the app fills the phone, which is what every
# reference product film actually does.
#
# Two ways this gets used:
#   1. Finished Short - text and a hold baked in, upload as is.
#   2. Clean plate for CapCut - no text, no hold, handles on both ends, so the
#      cut and the typography happen by hand downstream. That is what -Plate does.
#
# ASCII only: a BOM-less .ps1 is read as ANSI by PowerShell 5.1, which mangles any
# non-ASCII byte and breaks the parser.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\short_fullbleed.ps1 -Plate
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\short_fullbleed.ps1 -Peek

param(
  [string]$Source = 'C:\Users\levpo\Desktop\2026-08-03 17-31-29.mp4',
  [string]$Out    = '',

  # The performance, in seconds into the source file. Cut on the first frame of
  # purposeful motion - a cursor sitting still for half a second is dead footage.
  [double]$In  = 34.30,
  [double]$Dur = 1.85,

  # The 9:16 window into the 1364x768 capture. 432x768 is exactly 9:16, so the
  # scale to 1080x1920 carries no distortion at all. x=0 keeps the window edge and
  # the wordmark; 432 reaches just past TUE, leaving a sliver of WED that reads as
  # "the week continues" rather than as a cut.
  [int]$CropW = 432,
  [int]$CropH = 768,
  [int]$CropX = 0,
  [int]$CropY = 0,

  # Margin around the footage, in output pixels, and how hard the corners are
  # rounded. 0 = edge to edge. A small inset plus a radius reads as a panel rather
  # than as video pasted into a hole, without shrinking the picture enough to
  # matter. The margin is filled with the app's own background colour.
  [int]$Inset  = 0,
  [int]$Radius = 46,

  # Freeze on the last frame while the text reveals. Legitimate only because the
  # cursor is already at rest by then - freezing mid-motion is instantly visible.
  [double]$Hold = 2.80,

  # Two lines, revealed one after the other. The picture already shows the drag,
  # so the words must not narrate it - they say what the picture cannot.
  # Empty strings drop the text layer, and with it the scrim it sits on.
  [string]$Line1 = "Didn't get to it today?",
  [string]$Line2 = 'Just move it.',
  [int]$Size1 = 68,
  [int]$Size2 = 46,
  # Below the last task card, above the row YouTube paints over every Short. Text
  # crossing a UI element reads as a mistake even when it stays legible.
  [int]$Y1    = 1420,
  [int]$Y2    = 1526,

  # Clean plate for hand editing: no text, no hold, no fades, rounded corners, and
  # a handle either side of the action so the cut can be placed downstream.
  [switch]$Plate,
  [double]$Handle = 0.35,

  [switch]$Peek,
  [double]$At = -1,      # second to sample for -Peek; default lands mid-drag
  [int]$Crf = 17
)

$ErrorActionPreference = 'Stop'

$OUT_W = 1080
$OUT_H = 1920
$FPS   = 60
$BG_HEX = '15110D'     # AppTheme.background, deep warm graphite

if ($Plate) {
  $Line1 = ''; $Line2 = ''
  $Hold  = 0
  $In    = $In - $Handle
  $Dur   = $Dur + 2 * $Handle
  if ($Inset -le 0) { $Inset = 32 }
  if (-not $Out) { $Out = 'C:\Users\levpo\Desktop\slate_short_02_clean.mp4' }
}
if (-not $Out) { $Out = 'C:\Users\levpo\Desktop\slate_short_02_moveday.mp4' }

$hasText = [bool]($Line1 -or $Line2)

# Output-relative timeline. Everything downstream derives from these.
$tScrim   = $Dur + 0.15
$tLine1   = $Dur + 0.35
$tLine2   = $Dur + 0.85
$tTotal   = $Dur + $Hold
$tFadeOut = $tTotal - 0.35

if (-not (Test-Path $Source)) { Write-Host "Source not found: $Source" -ForegroundColor Red; exit 1 }

$fontFile = @(
  "$env:WINDIR\Fonts\seguisb.ttf",   # Segoe UI Semibold
  "$env:WINDIR\Fonts\segoeuib.ttf",  # Segoe UI Bold
  "$env:WINDIR\Fonts\segoeui.ttf",
  "$env:WINDIR\Fonts\arial.ttf"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $fontFile) { Write-Host 'No usable font in the Windows font folder.' -ForegroundColor Red; exit 1 }
$fontArg = $fontFile.Replace('\', '/').Replace(':', '\:')

Add-Type -AssemblyName System.Drawing

# --- geometry ----------------------------------------------------------------
# The footage keeps the crop's exact aspect, so the vertical margin lands wherever
# the arithmetic puts it. Forcing it equal to the horizontal one would mean
# stretching the picture, which is never worth a tidier number.
$fw = $OUT_W - 2 * $Inset
if ($fw % 2) { $fw-- }
$fh = [int][Math]::Round($fw * $CropH / [double]$CropW)
if ($fh % 2) { $fh-- }
$px = [int](($OUT_W - $fw) / 2)
$py = [int](($OUT_H - $fh) / 2)

# --- the rounded mask --------------------------------------------------------
$maskPng = Join-Path $env:TEMP 'slate_fb_mask.png'
if ($Inset -gt 0) {
  $mb = New-Object System.Drawing.Bitmap($fw, $fh, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $mg = [System.Drawing.Graphics]::FromImage($mb)
  $mg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $mg.Clear([System.Drawing.Color]::Black)
  $r  = $Radius
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $gp.AddArc(0, 0, 2*$r, 2*$r, 180, 90)
  $gp.AddArc($fw - 2*$r, 0, 2*$r, 2*$r, 270, 90)
  $gp.AddArc($fw - 2*$r, $fh - 2*$r, 2*$r, 2*$r, 0, 90)
  $gp.AddArc(0, $fh - 2*$r, 2*$r, 2*$r, 90, 90)
  $gp.CloseFigure()
  $mg.FillPath([System.Drawing.Brushes]::White, $gp)
  $gp.Dispose(); $mg.Dispose()
  $mb.Save($maskPng, [System.Drawing.Imaging.ImageFormat]::Png)
  $mb.Dispose()
}

# --- the scrim ---------------------------------------------------------------
# Drawn row by row rather than with a LinearGradientBrush: a linear alpha ramp has
# a visible edge where it leaves zero, and a squared ramp does not.
$scrimPng = Join-Path $env:TEMP 'slate_fb_scrim.png'
if ($hasText) {
  $bmp = New-Object System.Drawing.Bitmap($OUT_W, $OUT_H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::Transparent)
  $rampTop = 980
  for ($y = $rampTop; $y -lt $OUT_H; $y++) {
    $k = ($y - $rampTop) / [double]($OUT_H - $rampTop)
    $a = [int]([Math]::Round(0.90 * $k * $k * 255))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb($a, 0x15, 0x11, 0x0D))
    $g.DrawLine($pen, 0, $y, $OUT_W, $y)
    $pen.Dispose()
  }
  $g.Dispose()
  $bmp.Save($scrimPng, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# --- text --------------------------------------------------------------------
function Text-Layer([string]$txt, [int]$size, [int]$y, [double]$st, [string]$op, [string]$tag) {
  if (-not $txt) { return '' }
  # Through a file, not inline. drawtext's quoting rules make an apostrophe unsafe
  # in text=: escaping it either swallows the character ("Didn't" -> "Didnt") or
  # spills the remaining filter options into the drawn string.
  $p = Join-Path $env:TEMP ("slate_fb_text_{0}.txt" -f $tag)
  [System.IO.File]::WriteAllText($p, $txt, (New-Object System.Text.UTF8Encoding($false)))
  $arg = $p.Replace('\', '/').Replace(':', '\:')
  $al  = "if(lt(t,$st),0,min($op,($op)*(t-$st)/0.40))"
  return ",drawtext=fontfile='$fontArg':textfile='$arg':fontcolor=white" +
         ":fontsize=$size" + ':x=(w-text_w)/2' + ":y=$y" + ":alpha='$al'"
}

$chain  = Text-Layer $Line1 $Size1 $Y1 $tLine1 '0.95' 'a'
$chain += Text-Layer $Line2 $Size2 $Y2 $tLine2 '0.60' 'b'

# --- the graph ---------------------------------------------------------------
# Input order is built here rather than hardcoded, because the scrim and the mask
# each appear only when they are actually used.
$inputs = @()
$idx    = 1
$scrimI = -1
$maskI  = -1
if ($hasText)     { $inputs += @('-loop','1','-framerate',"$FPS",'-i',$scrimPng); $scrimI = $idx; $idx++ }
if ($Inset -gt 0) { $inputs += @('-loop','1','-framerate',"$FPS",'-i',$maskPng);  $maskI  = $idx; $idx++ }

function Build-Graph([bool]$still) {
  $pad = ''
  if (-not $still -and $Hold -gt 0) { $pad = ",tpad=stop_mode=clone:stop_duration=$Hold" }

  if ($Inset -gt 0) {
    $fc  = "[0:v]crop=$CropW`:$CropH`:$CropX`:$CropY,scale=$fw`:$fh`:flags=lanczos,setsar=1$pad,format=rgba[fg];"
    $fc += "[$maskI`:v]format=gray[mk];[fg][mk]alphamerge[card];"
    $fc += "color=c=0x$BG_HEX`:s=$OUT_W`x$OUT_H`:r=$FPS[bgc];"
    $fc += "[bgc][card]overlay=$px`:$py`:shortest=1[base];"
  } else {
    $fc  = "[0:v]crop=$CropW`:$CropH`:$CropX`:$CropY,scale=$OUT_W`:$OUT_H`:flags=lanczos,setsar=1$pad[base];"
  }

  if ($hasText) {
    $fade = if ($still) { '' } else { ",fade=t=in:st=$tScrim`:d=0.45:alpha=1" }
    $fc += "[$scrimI`:v]format=rgba$fade[scrim];[base][scrim]overlay=0:0:shortest=1[c];"
  } else {
    $fc += "[base]null[c];"
  }
  return $fc
}

# --- peek --------------------------------------------------------------------
if ($Peek) {
  $at  = if ($At -ge 0) { $At } else { $Dur * 0.42 }
  $png = [System.IO.Path]::ChangeExtension($Out, $null) + 'peek.png'
  $fc  = (Build-Graph $true) + "[c]null$chain[out]"
  $args1 = @('-y','-v','error','-ss',"$($In + $at)",'-i',$Source) + $inputs +
           @('-filter_complex',$fc,'-map','[out]','-frames:v','1',$png)
  & ffmpeg @args1
  if ($LASTEXITCODE -ne 0) { Write-Host 'peek failed' -ForegroundColor Red; exit 1 }
  Write-Host "peek : $png"
  Write-Host ("crop : {0}x{1} at {2},{3} -> {4}x{5} inset {6} radius {7}" -f $CropW,$CropH,$CropX,$CropY,$fw,$fh,$Inset,$Radius)
  exit 0
}

# --- render ------------------------------------------------------------------
$tail = if ($Plate) { '' } else { ",fade=t=in:st=0:d=0.30,fade=t=out:st=$tFadeOut`:d=0.35" }
$fc   = (Build-Graph $false) + "[c]null$chain$tail,format=yuv420p[out]"

# -t on the OUTPUT as well as the input. The looped mask and the colour source are
# both infinite, and neither overlay's nor alphamerge's shortest handling can be
# relied on to end the graph - without this the render never terminates.
$args2 = @('-y','-v','error','-ss',"$In",'-t',"$Dur",'-i',$Source) + $inputs +
         @('-filter_complex',$fc,'-map','[out]','-t',"$tTotal",'-r',"$FPS",
           '-c:v','libx264','-preset','slow','-crf',"$Crf",
           '-pix_fmt','yuv420p','-movflags','+faststart','-an',$Out)
& ffmpeg @args2
if ($LASTEXITCODE -ne 0) { Write-Host 'render failed' -ForegroundColor Red; exit 1 }

# The frame count is the only honest proof of the frame rate. An editor's export
# dialog is not evidence; a looped still input silently dictating 25fps is exactly
# the failure this check catches.
$frames = (& ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 $Out)
$secs   = (& ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv=p=0 $Out)
Write-Host ""
Write-Host ("out    : {0}" -f $Out)
Write-Host ("size   : {0} MB" -f [Math]::Round((Get-Item $Out).Length / 1MB, 2))
Write-Host ("frames : {0} in {1}s  =  {2} fps" -f $frames, $secs, [Math]::Round([double]$frames / [double]$secs, 2))
Write-Host ("cut    : {0}s .. {1}s of the source" -f $In, ($In + $Dur))
if ($Plate) { Write-Host ("handle : {0}s of margin at each end for the cut" -f $Handle) }
