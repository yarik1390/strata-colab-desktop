@echo off
rem Launch the Strata Colab Desktop UI without keeping a console window open.
setlocal
start "" "%WINDIR%\System32\wscript.exe" "%~dp0ui\Launch-Hidden.vbs"
