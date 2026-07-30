@echo off
chcp 65001 >nul
cd /d "%~dp0"

:: Автоматический запрос прав администратора (UAC)
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Запрос прав администратора...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Запуск основного скрипта
powershell -NoProfile -ExecutionPolicy Bypass -File "sc_block.ps1"
pause