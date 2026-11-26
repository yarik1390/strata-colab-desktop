<#
.SYNOPSIS
    Generates ui\strata-colab.ico and creates the Windows Desktop shortcut for Strata Colab Desktop.
#>
[CmdletBinding()]
param(
    [switch]$ForceIcon
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$UiDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $UiDir '..')).Path
$IconPath = Join-Path $UiDir 'strata-colab.ico'
$VbsPath = Join-Path $UiDir 'Launch-Hidden.vbs'

if (-not (Test-Path $VbsPath)) {
    throw "Missing launcher wrapper: $VbsPath"
}

function Write-StrataIconFile {
    param([string]$OutPath)
    $sizes = @(16, 32, 48, 256)
    $pngBlobs = New-Object System.Collections.Generic.List[byte[]]

    foreach ($sz in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        $pad = [float]($sz * 0.06)
        $box = [float]($sz - 2 * $pad)
        $rad = [float]($sz * 0.22)
        $d = $rad * 2.0
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($pad, $pad, $d, $d, 180, 90)
        $path.AddArc($pad + $box - $d, $pad, $d, $d, 270, 90)
        $path.AddArc($pad + $box - $d, $pad + $box - $d, $d, $d, 0, 90)
        $path.AddArc($pad, $pad + $box - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.PointF(0, 0)),
            (New-Object System.Drawing.PointF($sz, $sz)),
            [System.Drawing.Color]::FromArgb(255, 15, 23, 42),
            [System.Drawing.Color]::FromArgb(255, 30, 58, 138)
        )
        $g.FillPath($bgBrush, $path)

        $borderPen = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::FromArgb(225, 56, 189, 248),
            [Math]::Max(1.0, $sz * 0.05)
        )
        $g.DrawPath($borderPen, $path)

        $fontSz = [float]($sz * 0.56)
        $font = New-Object System.Drawing.Font('Segoe UI', $fontSz, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = [System.Drawing.StringAlignment]::Center
        $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
        $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 248, 250, 252))
        $rect = New-Object System.Drawing.RectangleF(0, ($sz * 0.02), $sz, $sz)
        $g.DrawString('S', $font, $textBrush, $rect, $sf)

        $dotSize = [Math]::Max(2.0, $sz * 0.16)
        $dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 56, 189, 248))
        $g.FillEllipse($dotBrush, [float]($sz * 0.68), [float]($sz * 0.18), [float]$dotSize, [float]$dotSize)

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngBlobs.Add($ms.ToArray())

        $ms.Dispose(); $dotBrush.Dispose(); $textBrush.Dispose(); $sf.Dispose(); $font.Dispose()
        $borderPen.Dispose(); $bgBrush.Dispose(); $path.Dispose(); $g.Dispose(); $bmp.Dispose()
    }

    $fs = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]$sizes.Count)

    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { [byte]0 } else { [byte]$sizes[$i] }
        $bytes = $pngBlobs[$i]
        $bw.Write($dim)
        $bw.Write($dim)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]32)
        $bw.Write([UInt32]$bytes.Length)
        $bw.Write([UInt32]$offset)
        $offset += $bytes.Length
    }
    foreach ($bytes in $pngBlobs) {
        $bw.Write($bytes)
    }
    $bw.Flush(); $bw.Dispose(); $fs.Dispose()
}

if ($ForceIcon -or -not (Test-Path $IconPath)) {
    Write-StrataIconFile -OutPath $IconPath
}

$DesktopDir = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($DesktopDir) -or -not (Test-Path $DesktopDir)) {
    throw "Could not resolve Desktop directory."
}

$ShortcutPath = Join-Path $DesktopDir 'Strata Colab Desktop.lnk'
$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($ShortcutPath)
$sc.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$sc.Arguments = "`"$VbsPath`""
$sc.WorkingDirectory = $RepoRoot
$sc.IconLocation = "$IconPath,0"
$sc.Description = 'Launch Strata Colab Desktop (Google Colab GPU & Tunnel UI)'
$sc.Save()

Write-Output "Icon: $IconPath"
Write-Output "Desktop shortcut created: $ShortcutPath"
