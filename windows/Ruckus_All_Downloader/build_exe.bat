@echo off
setlocal EnableExtensions
cd /d "%~dp0"
title Ruckus All Downloader Build
chcp 949 >nul
set PYTHONDONTWRITEBYTECODE=1

echo.
echo ============================================================
echo   Ruckus All Downloader Build
echo ============================================================
echo.
echo Folder: %CD%
echo.

set "PY="
if exist "%LocalAppData%\Programs\Python\Python312\python.exe" set "PY=%LocalAppData%\Programs\Python\Python312\python.exe"
if not defined PY if exist "%ProgramFiles%\Python312\python.exe" set "PY=%ProgramFiles%\Python312\python.exe"
if not defined PY where python >nul 2>&1 && for /f "delims=" %%P in ('where python') do if not defined PY set "PY=%%P"

if not defined PY (
    echo [����] Python�� ã�� �� �����ϴ�.
    echo        Python 3.12 �̻��� ��ġ�� �� �ٽ� �����ϼ���.
    pause
    exit /b 1
)

echo [*] Python:
"%PY%" --version
echo.

echo [*] ���忡 �ʿ��� ��Ű���� ��ġ�մϴ�...
"%PY%" -m pip install --upgrade pip
"%PY%" -m pip install pyinstaller requests beautifulsoup4 lxml
if errorlevel 1 (
    echo [����] ��Ű�� ��ġ�� �����߽��ϴ�.
    pause
    exit /b 1
)

if not exist "Ruckus_All_Downloader.py" (
    echo [����] Ruckus_All_Downloader.py �� �����ϴ�.
    pause
    exit /b 1
)
if not exist "updater.py" (
    echo [����] updater.py �� �����ϴ�.
    pause
    exit /b 1
)

if not exist "get_ruckus_cookie.py" (
    echo [����] get_ruckus_cookie.py �� �����ϴ�.
    pause
    exit /b 1
)

echo.
echo [*] PyInstaller �� ���� EXE�� �����մϴ�...
echo.

"%PY%" -m PyInstaller --noconfirm --clean --windowed --onefile ^
    --name "Ruckus_All_Downloader" ^
    --distpath "dist" ^
    --add-data "get_ruckus_cookie.py;." ^
    --add-data "updater.py;." ^
    --hidden-import updater ^
    --hidden-import get_ruckus_cookie ^
    --hidden-import requests ^
    --hidden-import bs4 ^
    --hidden-import lxml ^
    "Ruckus_All_Downloader.py"

if errorlevel 1 (
    echo.
    echo [����] ���忡 �����߽��ϴ�.
    if exist "build" rmdir /s /q "build"
    if exist "Ruckus_All_Downloader.spec" del /q "Ruckus_All_Downloader.spec"
    pause
    exit /b 1
)

if exist "build" rmdir /s /q "build"
if exist "Ruckus_All_Downloader.spec" del /q "Ruckus_All_Downloader.spec"

if exist "dist\Ruckus_All_Downloader.exe" (
    echo.
    echo [*] Writing SHA256 file...
    "%PY%" -c "import hashlib,pathlib; p=pathlib.Path(r'dist')/'Ruckus_All_Downloader.exe'; h=hashlib.sha256(p.read_bytes()).hexdigest(); out=pathlib.Path(str(p)+'.sha256'); out.write_text(h+'  '+p.name+'\n', encoding='ascii'); print('   ', out); print('   ', h)"
    echo.
    echo ============================================================
    echo [+] Build done
    echo     %cd%\dist\Ruckus_All_Downloader.exe
    echo     %cd%\dist\Ruckus_All_Downloader.exe.sha256
    echo ============================================================
) else (
    echo [����] dist\Ruckus_All_Downloader.exe �� ã�� ���߽��ϴ�.
    pause
    exit /b 1
)

echo.
pause
exit /b 0
