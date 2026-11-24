@echo off
rem Double-click me: opens the PC AppLog window. Nothing to install.
rem Prefer the keyboard? Use app\Menu.bat.
rem Runs in this console on purpose: opening a second one made the window appear later.
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\Launcher.ps1"
