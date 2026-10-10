@echo off
title PC Health Check - Deep Scan
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCHealthCheck.ps1" -Deep
echo.
pause
