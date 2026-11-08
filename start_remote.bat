@echo off
setlocal
chcp 65001 >nul
title Remote PC AI Control Server
cd /d "%~dp0"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PYTHONPATH=%~dp0;%~dp0.venv\Lib\site-packages;%PYTHONPATH%"

REM Prefer Windows-Firewall-permitted system Python 3.12 so Public Wi-Fi inbound traffic (:5000/:5001) is allowed.
set "PY_EXE="
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
    set "PY_EXE=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
)
if not defined PY_EXE (
    for /f "delims=" %%I in ('where python 2^>nul') do (
        if not defined PY_EXE (
            echo %%I | findstr /i "WindowsApps" >nul
            if errorlevel 1 set "PY_EXE=%%I"
        )
    )
)
if not defined PY_EXE (
    if exist "%~dp0.venv\Scripts\python.exe" (
        set "PY_EXE=%~dp0.venv\Scripts\python.exe"
    )
)

if not defined PY_EXE (
    echo [ERROR] Python 3.12+ not found.
    if not defined REMOTE_PC_NO_PAUSE pause
    exit /b 1
)

"%PY_EXE%" "%~dp0app.py" %*
if not defined REMOTE_PC_NO_PAUSE pause
