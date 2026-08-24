@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul

title Ruckus Universal Firmware Auto Downloader

rem ============================================================
rem 기본 설정
rem ============================================================

set "SCRIPT_NAME=auto_ruckus_downloader.ps1"
set "LOCAL_FILE=%~dp0auto_ruckus_downloader.ps1"
set "BACKUP_FILE=%~dp0auto_ruckus_downloader.ps1.bak"

set "TEMP_DIR=%TEMP%\RuckusUniversalUpdate"
set "TEMP_FILE=%TEMP_DIR%\auto_ruckus_downloader.ps1"

set "GITHUB_API_URL=https://api.github.com/repos/cockcut/ruckus_fw_autodownloader_enhanced/git/ref/heads/main"
set "GITHUB_RAW_BASE=https://raw.githubusercontent.com/cockcut/ruckus_fw_autodownloader_enhanced"


rem ============================================================
rem 업데이트 확인 시작
rem ============================================================

echo.
echo ============================================================
echo [업데이트 확인 중]
echo ============================================================
echo.
echo [*] GitHub 최신 커밋 정보를 확인합니다...

set "COMMIT_SHA="

for /f "usebackq delims=" %%A in (`powershell.exe -NoProfile -Command "$ProgressPreference='SilentlyContinue'; try { $r=Invoke-RestMethod -Uri '%GITHUB_API_URL%' -Headers @{ 'User-Agent'='RuckusUpdater' } -TimeoutSec 20; if ($r.object.sha) { $r.object.sha } else { exit 1 } } catch { exit 1 }"`) do (
    if not defined COMMIT_SHA set "COMMIT_SHA=%%A"
)

if not defined COMMIT_SHA (
    goto UPDATE_CHECK_FAILED
)

echo [*] 최신 커밋 확인 완료.
echo [*] 최신 커밋 SHA:
echo     %COMMIT_SHA%

set "UPDATE_URL=%GITHUB_RAW_BASE%/%COMMIT_SHA%/windows/%SCRIPT_NAME%"

echo.
echo [*] 최신 PS1 파일 다운로드 URL:
echo     %UPDATE_URL%


rem ============================================================
rem 임시 폴더 생성
rem ============================================================

if not exist "%TEMP_DIR%" (
    mkdir "%TEMP_DIR%" >nul 2>&1
)

if not exist "%TEMP_DIR%" (
    goto UPDATE_CHECK_FAILED
)


rem ============================================================
rem 기존 임시 파일 삭제
rem ============================================================

if exist "%TEMP_FILE%" (
    del /f /q "%TEMP_FILE%" >nul 2>&1
)

if exist "%TEMP_FILE%" (
    goto UPDATE_CHECK_FAILED
)


rem ============================================================
rem 최신 Commit SHA 기준 파일 다운로드
rem ============================================================

echo.
echo [*] GitHub 최신 PS1 파일을 다운로드합니다...

curl.exe -L --fail --silent --show-error --connect-timeout 10 --max-time 60 -o "%TEMP_FILE%" "%UPDATE_URL%"

if errorlevel 1 (
    goto UPDATE_CHECK_FAILED
)


rem ============================================================
rem 다운로드 파일 확인
rem ============================================================

if not exist "%TEMP_FILE%" (
    goto UPDATE_CHECK_FAILED
)

for %%A in ("%TEMP_FILE%") do set "TEMP_SIZE=%%~zA"

if not defined TEMP_SIZE (
    goto UPDATE_CHECK_FAILED
)

if "%TEMP_SIZE%"=="0" (
    goto UPDATE_CHECK_FAILED
)


rem ============================================================
rem 로컬 PS1 파일이 없는 경우 설치
rem ============================================================

if not exist "%LOCAL_FILE%" (

    echo.
    echo [+] 로컬 PS1 파일이 없습니다.
    echo [*] 최신 파일을 새로 설치합니다...

    copy /y "%TEMP_FILE%" "%LOCAL_FILE%" >nul

    if errorlevel 1 (
        goto UPDATE_CHECK_FAILED
    )

    if not exist "%LOCAL_FILE%" (
        goto UPDATE_CHECK_FAILED
    )

    call :GetHash "%LOCAL_FILE%" LOCAL_HASH
    call :GetHash "%TEMP_FILE%" REMOTE_HASH

    if not defined LOCAL_HASH (
        goto UPDATE_CHECK_FAILED
    )

    if not defined REMOTE_HASH (
        goto UPDATE_CHECK_FAILED
    )

    if /I not "%LOCAL_HASH%"=="%REMOTE_HASH%" (
        goto UPDATE_CHECK_FAILED
    )

    echo.
    echo ============================================================
    echo [+] 최신 PS1 파일 설치가 완료되었습니다.
    echo ============================================================

    goto CLEANUP_AND_RUN
)


rem ============================================================
rem SHA-256 파일 비교
rem ============================================================

echo.
echo [*] 로컬 파일과 최신 GitHub 파일을 비교합니다...

call :GetHash "%LOCAL_FILE%" LOCAL_HASH
call :GetHash "%TEMP_FILE%" REMOTE_HASH

if not defined LOCAL_HASH (
    goto UPDATE_CHECK_FAILED
)

if not defined REMOTE_HASH (
    goto UPDATE_CHECK_FAILED
)


rem ============================================================
rem 동일 파일 확인
rem ============================================================

if /I "%LOCAL_HASH%"=="%REMOTE_HASH%" (

    echo [+] 현재 최신 버전입니다.

    goto CLEANUP_AND_RUN
)


rem ============================================================
rem 업데이트 진행
rem ============================================================

echo.
echo ============================================================
echo [+] 새로운 파일 변경 사항을 발견했습니다.
echo ============================================================
echo.

rem 기존 백업 삭제
if exist "%BACKUP_FILE%" (

    echo [*] 기존 백업 파일을 삭제합니다...

    del /f /q "%BACKUP_FILE%" >nul 2>&1

)

if exist "%BACKUP_FILE%" (

    echo [!] 기존 백업 파일을 삭제할 수 없습니다.

    goto UPDATE_CHECK_FAILED

)


rem ============================================================
rem 현재 파일 백업
rem ============================================================

echo [*] 현재 PS1 파일을 백업합니다...

copy /y "%LOCAL_FILE%" "%BACKUP_FILE%" >nul

if errorlevel 1 (

    echo [!] 현재 PS1 파일 백업에 실패했습니다.

    goto UPDATE_CHECK_FAILED

)

if not exist "%BACKUP_FILE%" (

    echo [!] 백업 파일이 생성되지 않았습니다.

    goto UPDATE_CHECK_FAILED

)

echo [+] 기존 파일 백업 완료.


rem ============================================================
rem 최신 파일 적용
rem ============================================================

echo [*] 최신 PS1 파일을 적용합니다...

copy /y "%TEMP_FILE%" "%LOCAL_FILE%" >nul

if errorlevel 1 (

    echo [!] 최신 파일 적용에 실패했습니다.
    echo [*] 기존 백업 파일로 복구합니다...

    copy /y "%BACKUP_FILE%" "%LOCAL_FILE%" >nul 2>&1

    goto UPDATE_CHECK_FAILED

)

if not exist "%LOCAL_FILE%" (

    echo [!] 업데이트 파일이 생성되지 않았습니다.

    goto RESTORE_BACKUP

)


rem ============================================================
rem 업데이트 결과 검증
rem ============================================================

echo [*] 업데이트 결과를 검증합니다...

call :GetHash "%LOCAL_FILE%" UPDATED_HASH

if not defined UPDATED_HASH (

    echo [!] 업데이트 후 파일 확인에 실패했습니다.

    goto RESTORE_BACKUP

)

if /I not "%UPDATED_HASH%"=="%REMOTE_HASH%" (

    echo [!] 업데이트 파일 검증에 실패했습니다.

    goto RESTORE_BACKUP

)


echo.
echo ============================================================
echo [+] 업데이트가 완료되었습니다!
echo ============================================================


goto CLEANUP_AND_RUN


rem ============================================================
rem 업데이트 실패 시 백업 복구
rem ============================================================

:RESTORE_BACKUP

echo.
echo [!] 업데이트에 문제가 발생했습니다.
echo [*] 기존 백업 파일로 복구합니다...

if exist "%BACKUP_FILE%" (
    copy /y "%BACKUP_FILE%" "%LOCAL_FILE%" >nul 2>&1
)

goto UPDATE_CHECK_FAILED


rem ============================================================
rem 업데이트 확인 실패
rem ============================================================

:UPDATE_CHECK_FAILED

echo.
echo ============================================================
echo [업데이트 확인 실패]
echo ============================================================
echo.
echo [!] 인터넷 연결 또는 GitHub 접속 상태를 확인하세요.
echo [*] 기존 PS1 스크립트를 계속 실행합니다.


rem ============================================================
rem 임시 파일 정리
rem ============================================================

:CLEANUP_AND_RUN

if exist "%TEMP_FILE%" (
    del /f /q "%TEMP_FILE%" >nul 2>&1
)

if exist "%TEMP_DIR%" (
    rmdir /s /q "%TEMP_DIR%" >nul 2>&1
)


rem ============================================================
rem PS1 실행
rem ============================================================

echo.
echo ============================================================
echo [Ruckus Universal Firmware Downloader 실행]
echo ============================================================
echo.

if not exist "%LOCAL_FILE%" (

    echo [오류] 실행할 PS1 파일이 없습니다.
    echo.
    pause
    exit /b 1

)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCAL_FILE%"

echo.
pause
exit /b


rem ============================================================
rem SHA-256 해시 계산 함수
rem ============================================================

:GetHash

setlocal DisableDelayedExpansion
set "HASH="

for /f "tokens=1" %%H in ('
    certutil -hashfile "%~1" SHA256 ^| findstr /r /i "^[0-9A-F][0-9A-F][0-9A-F][0-9A-F]"
') do (
    if not defined HASH set "HASH=%%H"
)

endlocal & set "%~2=%HASH%"
exit /b