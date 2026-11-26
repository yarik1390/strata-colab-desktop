@echo off
rem Create a Windows Desktop shortcut ("Strata Colab Desktop") with custom icon.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ui\Create-Shortcut.ps1"
if errorlevel 1 (
    echo.
    echo Failed to create Desktop shortcut.
    pause
    exit /b 1
)
echo.
pause
