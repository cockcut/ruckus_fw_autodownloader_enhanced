@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Ruckus Unleashed Downloader
chcp 949 >nul
set PYTHONDONTWRITEBYTECODE=1

echo.
echo ============================================================
echo   Ruckus Unleashed Downloader
echo ============================================================
echo.
echo Folder: %CD%
echo.

if exist "%~dp0dist\Ruckus_Unleashed_Downloader.exe" (
    echo [*] 빌드된 EXE를 실행합니다.
    start "" "%~dp0dist\Ruckus_Unleashed_Downloader.exe"
    exit /b 0
)

set "PY="
if exist "%LocalAppData%\Programs\Python\Python312\python.exe" set "PY=%LocalAppData%\Programs\Python\Python312\python.exe"
if not defined PY if exist "%ProgramFiles%\Python312\python.exe" set "PY=%ProgramFiles%\Python312\python.exe"
if not defined PY where python >nul 2>&1 && for /f "delims=" %%P in ('where python') do if not defined PY set "PY=%%P"

if not defined PY (
    echo [오류] Python을 찾을 수 없습니다.
    echo        build_exe.bat 으로 EXE를 만들거나 Python을 설치하세요.
    pause
    exit /b 1
)

if not exist "%~dp0Ruckus_Unleashed_Downloader.py" (
    echo [오류] Ruckus_Unleashed_Downloader.py 가 없습니다.
    pause
    exit /b 1
)

echo [*] 필요한 패키지를 확인합니다...
"%PY%" -c "import requests,bs4" 2>nul
if errorlevel 1 (
    echo 관련 모듈을 자동 설치합니다.
    "%PY%" -m pip install requests beautifulsoup4 lxml
)

echo [*] Python GUI를 실행합니다.
"%PY%" -B "%~dp0Ruckus_Unleashed_Downloader.py"
if errorlevel 1 pause
exit /b %ERRORLEVEL%
