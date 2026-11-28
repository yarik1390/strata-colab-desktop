@echo off
rem Print or apply coding-agent connection configs (Claude Code, Cursor, Cline, OpenAI SDK).
rem Usage: connect.bat [claude|cursor|openai|all] [--apply]
setlocal
chcp 65001 >nul
title Strata Client Connect Helper
if defined STRATA_WSL_DISTRO (
    wsl.exe -d "%STRATA_WSL_DISTRO%" --cd "%~dp0." --exec bash -l ./connect.sh %*
) else (
    wsl.exe --cd "%~dp0." --exec bash -l ./connect.sh %*
)
echo.
pause
