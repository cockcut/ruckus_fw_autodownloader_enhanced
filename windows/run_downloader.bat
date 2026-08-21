@echo off
chcp 65001 > nul
title Ruckus Product Firmware Auto Downloader

set "JSON_URL=https://raw.githubusercontent.com/cockcut/ruckus_fw_autodownloader_enhanced/refs/heads/main/version.json"
set "PS1_FILE=%~dp0auto_ruckus_downloader.ps1"

echo [*] 업데이트 체크 중...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; try { $info = Invoke-RestMethod -Uri '%JSON_URL%' -TimeoutSec 5; $remoteVer = $info.universal_version; $remoteUrl = $info.universal_ps1_url; $localVer = '0.0.0'; if (Test-Path '%PS1_FILE%') { $lines = Get-Content '%PS1_FILE%' -Head 10 -ErrorAction SilentlyContinue | Out-String; if ($lines -match 'v(\d+\.\d+\.\d+)') { $localVer = $Matches[1] } }; if ([version]$remoteVer -gt [version]$localVer) { Write-Host '[!] 새 버전이 발견되었습니다. (' $localVer ' -> ' $remoteVer ')' -ForegroundColor Yellow; Write-Host '[*] 최신 스크립트를 다운로드합니다...' -ForegroundColor Cyan; Invoke-WebRequest -Uri $remoteUrl -OutFile '%PS1_FILE%' -UseBasicParsing; Write-Host '[+] 업데이트 완료!' -ForegroundColor Green; Write-Host '=======================================================' -ForegroundColor Cyan; Write-Host '   업데이트가 완료되었으니 배치 파일을 다시 실행해 주세요.' -ForegroundColor Yellow; Write-Host '=======================================================' -ForegroundColor Cyan; exit 99 } else { Write-Host '[+] 최신 버전입니다. (v'$localVer')' -ForegroundColor Green } } catch { Write-Host '[!] 업데이트 체크 실패: 인터넷 연결 및 GitHub URL을 확인하세요.' -ForegroundColor Red; Write-Host '[*] 기존 버전으로 계속 실행합니다...' -ForegroundColor Yellow }"

if %ERRORLEVEL% equ 99 (
    echo.
    pause
    exit /b
)

echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1_FILE%"
echo.
pause
