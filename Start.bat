@echo off
rem Double-click me: opens the PC AppLog window. Nothing to install.
rem Prefer the keyboard? Use app\Menu.bat.
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\Launcher.ps1"
