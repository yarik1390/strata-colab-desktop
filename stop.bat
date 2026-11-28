@echo off
rem Close the tunnel and stop the Colab runtime. The downloaded model is deleted too.
setlocal
chcp 65001 >nul
if defined STRATA_WSL_DISTRO (
    wsl.exe -d "%STRATA_WSL_DISTRO%" --cd "%~dp0." -- bash -lc "bash ./down.sh"
) else (
    wsl.exe --cd "%~dp0." -- bash -lc "bash ./down.sh"
)
echo.
pause
