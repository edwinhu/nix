@echo off
REM Runs once, elevated, during dockur/windows' final install stage. The whole
REM /oem folder lands at C:\OEM first, so setup.ps1 sits beside this file.
powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\setup.ps1 > C:\OEM\setup.log 2>&1
