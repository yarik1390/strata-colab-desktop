@echo off
rem Run or monitor Strata Auto-Tune through Google Colab's active-workload `colab exec` channel.
rem Usage: tune.bat [thorough|quick] [coding|chat] [work|performance]
setlocal
chcp 65001 >nul
title Strata Auto-Tune Monitor
if defined STRATA_WSL_DISTRO (
    wsl.exe -d "%STRATA_WSL_DISTRO%" --cd "%~dp0." --exec bash -l ./tune.sh %*
) else (
    wsl.exe --cd "%~dp0." --exec bash -l ./tune.sh %*
)
echo.
pause
