@echo off
rem Launch the Strata Colab Desktop UI without keeping a console window open.
setlocal
if exist "%WINDIR%\System32\wscript.exe" (
    if exist "%~dp0ui\Launch-Hidden.vbs" (
        start "" "%WINDIR%\System32\wscript.exe" "%~dp0ui\Launch-Hidden.vbs"
        exit /b 0
    )
)
rem Fallback when VBScript / wscript.exe is unavailable (e.g. Windows 11 24H2+ without VBScript FOD)
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ui\StrataLauncher.ps1"
