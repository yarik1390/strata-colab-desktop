<#
.SYNOPSIS
    Generates ui\strata-colab.ico and creates the Windows Desktop (and optional
    Start Menu) shortcut for Strata Colab Desktop.
#>
[CmdletBinding()]
param(
    [switch]$ForceIcon,
    [switch]$StartMenu
)

$ErrorActionPreference = 'Stop'

$UiDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $UiDir '..')).Path
$HelpersPath = Join-Path $UiDir 'StrataHelpers.psm1'
$IconPath = Join-Path $UiDir 'strata-colab.ico'
$VbsPath = Join-Path $UiDir 'Launch-Hidden.vbs'
$Ps1Path = Join-Path $UiDir 'StrataLauncher.ps1'

if (-not (Test-Path -LiteralPath $HelpersPath)) {
    throw "Missing helper module: $HelpersPath"
}
if (-not (Test-Path -LiteralPath $Ps1Path)) {
    throw "Missing launcher script: $Ps1Path"
}

Import-Module $HelpersPath -Force -DisableNameChecking

Write-StrataIconFile -OutPath $IconPath -Force:$ForceIcon

$wscriptExe = Join-Path $env:WINDIR 'System32\wscript.exe'
$useVbs = (Test-Path -LiteralPath $wscriptExe) -and (Test-Path -LiteralPath $VbsPath)

function New-StrataShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath
    )
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($ShortcutPath)
    if ($useVbs) {
        $sc.TargetPath = $wscriptExe
        $sc.Arguments = "`"$VbsPath`""
    } else {
        # Fallback for Windows 11 24H2+ environments where VBScript/wscript is unavailable
        $sc.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$Ps1Path`""
        $sc.WindowStyle = 7
    }
    $sc.WorkingDirectory = $RepoRoot
    $sc.IconLocation = "$IconPath,0"
    $sc.Description = 'Launch Strata Colab Desktop (Google Colab GPU & Tunnel UI)'
    $sc.Save()
}

$DesktopDir = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($DesktopDir) -or -not (Test-Path -LiteralPath $DesktopDir)) {
    throw 'Could not resolve Desktop directory.'
}

$DesktopShortcut = Join-Path $DesktopDir 'Strata Colab Desktop.lnk'
New-StrataShortcut -ShortcutPath $DesktopShortcut

Write-Output "Icon: $IconPath"
Write-Output "Desktop shortcut created: $DesktopShortcut"

if ($StartMenu) {
    $ProgramsDir = [Environment]::GetFolderPath('Programs')
    if (-not [string]::IsNullOrWhiteSpace($ProgramsDir) -and (Test-Path -LiteralPath $ProgramsDir)) {
        $StartMenuShortcut = Join-Path $ProgramsDir 'Strata Colab Desktop.lnk'
        New-StrataShortcut -ShortcutPath $StartMenuShortcut
        Write-Output "Start Menu shortcut created: $StartMenuShortcut"
    }
}
