@echo off
rem Run or monitor Strata Auto-Tune through Google Colab's active-workload `colab exec` channel.
rem Usage: tune.bat [thorough|quick] [coding|chat] [work|performance]
setlocal
chcp 65001 >nul
set "DISTRO_OPT="
if defined STRATA_WSL_DISTRO set "DISTRO_OPT=-d %STRATA_WSL_DISTRO%"
title Strata Auto-Tune Monitor
wsl.exe %DISTRO_OPT% --cd "%~dp0." -- bash -lc "bash ./tune.sh %*"
echo.
pause
