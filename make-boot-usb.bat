@echo off
setlocal
:: ======================================================================
::  ВНИМАНИЕ: этот файл должен быть сохранен в кодировке CP866 (OEM/DOS)
::  и с окончаниями строк CRLF. Не пересохраняйте его в UTF-8 и не
::  добавляйте "chcp 65001" - cmd.exe перестанет правильно разбирать
::  скрипт (строки будут рваться и исполняться как команды).
:: ======================================================================

:: 1. Проверка прав Администратора и автоматический UAC-запрос
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ИНФО] Запрос прав Администратора...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/k cd /d ""%~dp0"" && powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%~dp0make-boot-usb.ps1""' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:: 2. Запуск основного PowerShell скрипта
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-boot-usb.ps1"

if %errorlevel% neq 0 (
    chcp 866 >nul
    echo.
    echo ======================================================================
    echo  Работа мастера завершена с ошибкой.
    echo ======================================================================
    pause
)
