@echo off
title PC Health Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCHealthCheck.ps1"
echo.
pause
