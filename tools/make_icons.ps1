# Draws the marker icons into Mods/DragonSwordRadar/assets. Chest icons are white and get tinted in game.
param([string]$OutDir = (Join-Path $PSScriptRoot "..\Mods\DragonSwordRadar\assets"))
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force $OutDir | Out-Null
$dark = [System.Drawing.Color]::FromArgb(255, 24, 28, 38)

function New-Canvas([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([System.Drawing.Color]::Transparent)
    return @($bmp, $g)
}
function Save-Canvas($c, [string]$name) { $c[1].Dispose(); $c[0].Save((Join-Path $OutDir $name), [System.Drawing.Imaging.ImageFormat]::Png); $c[0].Dispose() }
function Pt([double]$x, [double]$y) { New-Object System.Drawing.PointF([single]$x, [single]$y) }

# dot: chest marker
$c = New-Canvas 64
$c[1].FillEllipse((New-Object System.Drawing.SolidBrush($dark)), 4, 4, 56, 56)
$c[1].FillEllipse([System.Drawing.Brushes]::White, 12, 12, 40, 40)
Save-Canvas $c "dot.png"

# dot-near: nearest chest, with a ring
$c = New-Canvas 96
$c[1].FillEllipse((New-Object System.Drawing.SolidBrush($dark)), 4, 4, 88, 88)
$c[1].FillEllipse([System.Drawing.Brushes]::White, 11, 11, 74, 74)
$c[1].FillEllipse((New-Object System.Drawing.SolidBrush($dark)), 20, 20, 56, 56)
$c[1].FillEllipse([System.Drawing.Brushes]::White, 27, 27, 42, 42)
Save-Canvas $c "dot-near.png"

# arrow: points right; rotated in game to show "above" / "below"
$c = New-Canvas 128
$shape = [System.Drawing.PointF[]]@((Pt 14 50), (Pt 70 50), (Pt 70 24), (Pt 116 64), (Pt 70 104), (Pt 70 78), (Pt 14 78))
$pen = New-Object System.Drawing.Pen($dark, 10); $pen.LineJoin = 'Round'
$c[1].DrawPolygon($pen, $shape)
$c[1].FillPolygon([System.Drawing.Brushes]::White, $shape)
Save-Canvas $c "arrow.png"

# quest: blue diamond with "!"
$c = New-Canvas 96
$d = { param($r) [System.Drawing.PointF[]]@((Pt 48 (48 - $r)), (Pt (48 + $r) 48), (Pt 48 (48 + $r)), (Pt (48 - $r) 48)) }
$c[1].FillPolygon((New-Object System.Drawing.SolidBrush($dark)), (& $d 46))
$c[1].FillPolygon((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 53, 174, 255))), (& $d 35))
$c[1].FillPolygon([System.Drawing.Brushes]::White, [System.Drawing.PointF[]]@((Pt 41.5 27), (Pt 54.5 27), (Pt 51.5 54), (Pt 44.5 54)))
$c[1].FillEllipse([System.Drawing.Brushes]::White, 42.5, 59, 11, 11)
Save-Canvas $c "quest.png"

# talk: yellow speech bubble with three dots
$c = New-Canvas 96
$p = New-Object System.Drawing.Drawing2D.GraphicsPath
$p.AddArc(9, 12, 20, 20, 180, 90); $p.AddArc(67, 12, 20, 20, 270, 90); $p.AddArc(67, 46, 20, 20, 0, 90)
$p.AddLine(77, 66, 46, 66); $p.AddLine(46, 66, 26, 86); $p.AddLine(26, 86, 28, 66); $p.AddArc(9, 46, 20, 20, 90, 90); $p.CloseFigure()
$pen = New-Object System.Drawing.Pen($dark, 11); $pen.LineJoin = 'Round'
$c[1].DrawPath($pen, $p)
$c[1].FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 221, 87))), $p)
foreach ($x in 29, 48, 67) { $c[1].FillEllipse((New-Object System.Drawing.SolidBrush($dark)), $x - 7, 32, 14, 14) }
Save-Canvas $c "talk.png"
"icons written to $OutDir"
