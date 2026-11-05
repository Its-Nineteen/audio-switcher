@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0AudioSwitcher.ps1" -List
set "result=%errorlevel%"
echo.
pause
exit /b %result%
