@echo off
rem Double-click me. One menu for everything; nothing to install.
setlocal
title Personal-PC-AppLog
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"

:menu
cls
echo.
echo   Personal-PC-AppLog
echo   ------------------
echo   1  Show PC specs (copied to the clipboard, ready to paste)
echo   2  Check installed apps (what changed since last time)
echo   3  App changes in the last 30 days
echo   4  Run automatically every Sunday at 10:00
echo   5  Stop running automatically
echo   6  Open the logs folder
echo   Q  Quit
echo.
choice /c 123456Q /n /m "  Press a key: "
if errorlevel 255 exit /b 1
if errorlevel 7 exit /b 0
if errorlevel 6 goto logs
if errorlevel 5 goto unschedule
if errorlevel 4 goto schedule
if errorlevel 3 goto history
if errorlevel 2 goto apps
if errorlevel 1 goto specs
exit /b 1

:specs
echo.
%PS% "%~dp0PCSpecs.ps1" -Copy
goto back

:apps
echo.
%PS% "%~dp0AppLog.ps1"
goto back

:history
echo.
%PS% "%~dp0AppLog.ps1" -History 30
goto back

:schedule
echo.
%PS% "%~dp0Schedule.ps1"
goto back

:unschedule
echo.
%PS% "%~dp0Schedule.ps1" -Remove
goto back

:logs
if not exist "%~dp0logs" mkdir "%~dp0logs"
start "" "%~dp0logs"
goto menu

:back
echo.
pause
goto menu
