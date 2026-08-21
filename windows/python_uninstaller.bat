@echo off
chcp 65001 > nul
title Ruckus Auto Downloader Uninstaller

:: 배치 파일이 있는 경로로 이동
cd /d "%~dp0"

echo =======================================================
echo   Python 패키지 삭제 및 환경 정리
echo =======================================================
echo.

:: 1. 파이썬 모듈 삭제
echo [*] 파이썬 패키지(requests, beautifulsoup4, lxml) 삭제 중...
python -m pip uninstall requests beautifulsoup4 lxml -y >nul 2>&1
if %ERRORLEVEL% equ 0 (
    echo [+] 파이썬 패키지 삭제 완료.
) else (
    echo [!] 파이썬 패키지 삭제 실패 또는 이미 삭제됨.
)
echo.

:: 2. Python 3.12 삭제 (User Scope 우선 시도 후 Machine Scope 시도)
echo [*] Python 3.12 프로그램 삭제 중 (winget)...
winget uninstall --id Python.Python.3.12 --scope user --silent --accept-source-agreements >nul 2>&1
if %ERRORLEVEL% neq 0 (
    winget uninstall --id Python.Python.3.12 --scope machine --silent --accept-source-agreements >nul 2>&1
)

if %ERRORLEVEL% equ 0 (
    echo [+] Python 3.12 삭제 완료.
) else (
    echo [!] winget 삭제 실패. 일반 사용자 권한으로 직접 실행을 시도합니다...
    winget uninstall --id Python.Python.3.12 --silent --accept-source-agreements
)
echo.

:: 3. 스크립트 실행 중 생성된 임시 파일 및 쿠키 삭제
echo [*] 생성된 쿠키 및 임시 파일 정리 중...
if exist "cookies.txt" (
    del /f /q "cookies.txt"
    echo [+] cookies.txt 삭제 완료.
)
if exist "temp_*.py" (
    del /f /q "temp_*.py"
    echo [+] 임시 파이썬 파일 삭제 완료.
)

echo.
echo =======================================================
echo   모든 삭제 및 정리 작업이 완료되었습니다.
echo =======================================================
echo.
pause
