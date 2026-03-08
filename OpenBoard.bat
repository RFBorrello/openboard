@echo off
setlocal
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\launch_openboard.ps1"
exit /b %ERRORLEVEL%
