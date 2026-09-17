@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Ruckus Unleashed Downloader Build
chcp 949 >nul
set PYTHONDONTWRITEBYTECODE=1

echo.
echo ============================================================
echo   Ruckus Unleashed Downloader Build
echo ============================================================
echo.
echo Folder: %CD%
echo.

set "PY="
if exist "%LocalAppData%\Programs\Python\Python312\python.exe" set "PY=%LocalAppData%\Programs\Python\Python312\python.exe"
if not defined PY if exist "%ProgramFiles%\Python312\python.exe" set "PY=%ProgramFiles%\Python312\python.exe"
if not defined PY where python >nul 2>&1 && for /f "delims=" %%P in ('where python') do if not defined PY set "PY=%%P"

if not defined PY (
    echo [오류] Python을 찾을 수 없습니다.
    echo        Python 3.12 이상을 설치한 뒤 다시 실행하세요.
    pause
    exit /b 1
)

echo [*] Python:
"%PY%" --version
echo.

echo [*] 빌드에 필요한 패키지를 설치합니다...
"%PY%" -m pip install --upgrade pip
"%PY%" -m pip install pyinstaller requests beautifulsoup4 lxml
if errorlevel 1 (
    echo [오류] 패키지 설치에 실패했습니다.
    pause
    exit /b 1
)

if not exist "Ruckus_Unleashed_Downloader.py" (
    echo [오류] Ruckus_Unleashed_Downloader.py 가 없습니다.
    pause
    exit /b 1
)
if not exist "updater.py" (
    echo [오류] updater.py 가 없습니다.
    pause
    exit /b 1
)

if not exist "get_ruckus_cookie.py" (
    echo [오류] get_ruckus_cookie.py 가 없습니다.
    pause
    exit /b 1
)

echo.
echo [*] PyInstaller 로 단일 EXE를 생성합니다...
echo.

"%PY%" -m PyInstaller --noconfirm --clean --windowed --onefile ^
    --name "Ruckus_Unleashed_Downloader" ^
    --distpath "dist" ^
    --add-data "get_ruckus_cookie.py;." ^
    --add-data "updater.py;." ^
    --hidden-import updater ^
    --hidden-import get_ruckus_cookie ^
    --hidden-import requests ^
    --hidden-import bs4 ^
    --hidden-import lxml ^
    "Ruckus_Unleashed_Downloader.py"

if errorlevel 1 (
    echo.
    echo [오류] 빌드에 실패했습니다.
    if exist "build" rmdir /s /q "build"
    if exist "Ruckus_Unleashed_Downloader.spec" del /q "Ruckus_Unleashed_Downloader.spec"
    pause
    exit /b 1
)

if exist "build" rmdir /s /q "build"
if exist "Ruckus_Unleashed_Downloader.spec" del /q "Ruckus_Unleashed_Downloader.spec"

if exist "dist\Ruckus_Unleashed_Downloader.exe" (
    echo.
    echo ============================================================
    echo [+] 빌드 완료
    echo     %cd%\dist\Ruckus_Unleashed_Downloader.exe
    echo ============================================================
) else (
    echo [오류] dist\Ruckus_Unleashed_Downloader.exe 를 찾지 못했습니다.
    pause
    exit /b 1
)

echo.
pause
exit /b 0
