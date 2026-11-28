@echo off
rem Show the state of the Colab runtime, Strata and the local tunnel.
setlocal
chcp 65001 >nul
if defined STRATA_WSL_DISTRO (
    wsl.exe -d "%STRATA_WSL_DISTRO%" --cd "%~dp0." -- bash -lc "bash ./status.sh"
) else (
    wsl.exe --cd "%~dp0." -- bash -lc "bash ./status.sh"
)
echo.
pause
