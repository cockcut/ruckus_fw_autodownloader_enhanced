# =================================================================
# Ruckus Unleashed Firmware Auto Downloader for Windows (v2.1.7)
# - Parallel Downloading Support (Max 3 Concurrent)
# =================================================================

# Windows Forms 어셈블리 로드 및 예외 처리 모드 선언 (스크립트 시작 시 1회만 실행)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# -----------------------------------------------------------------
# 주요 경로 및 기본 변수 선언
# -----------------------------------------------------------------
$COOKIE_FILE   = Join-Path $PSScriptRoot "cookies.txt"
$PYTHON_SCRIPT = Join-Path $PSScriptRoot "get_ruckus_cookie.py"
$BASE_URL      = "https://support.ruckuswireless.com"

$RUCKUS_USER = $env:RUCKUS_USER
$RUCKUS_PASS = $env:RUCKUS_PASS

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "   Ruckus Unleashed Firmware Auto Downloader (v2.1.7)" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------
# [단계 0] Python 환경 및 필수 패키지 점검
# -----------------------------------------------------------------
Write-Host "[0/5] 필수 패키지 및 모듈 설치 상태 확인 중..." -ForegroundColor Yellow

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd -or $pythonCmd.Source -match "WindowsApps") {
    Write-Host "[!] Python이 설치되어 있지 않습니다. winget으로 설치를 진행합니다..." -ForegroundColor Yellow
    winget install --id Python.Python.3.12 --source winget --scope user --silent --accept-package-agreements --accept-source-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

$pyExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pyExe -or $pyExe -match "WindowsApps") {
    $pyExe = Join-Path $env:LocalAppData "Programs\Python\Python312\python.exe"
}

if (-not (Test-Path $pyExe)) {
    Write-Host "[-] Python 설치 또는 경로 인식에 실패했습니다. 파이썬을 수동으로 설치 후 다시 실행해 주세요." -ForegroundColor Red
    exit 1
}

$modules = @{
    "requests" = "requests"
    "bs4"      = "beautifulsoup4"
    "lxml"     = "lxml"
}

foreach ($importName in $modules.Keys) {
    $pkgName = $modules[$importName]
    $checkScript = "import sys, importlib.util; sys.exit(0 if importlib.util.find_spec('$importName') else 1)"
    & "$pyExe" -c "$checkScript"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] 파이썬 $pkgName ($importName) 모듈이 없습니다. 자동 설치를 진행합니다..." -ForegroundColor Yellow
        & "$pyExe" -m pip install $pkgName --quiet
    }
}
Write-Host "[+] 개발 및 실행 환경 검사 완료." -ForegroundColor Green
Write-Host "-------------------------------------------------"

# -----------------------------------------------------------------
# [단계 1] 쿠키 확인 및 로그인 (production_ruckus_support 만료 검사)
# -----------------------------------------------------------------
Write-Host "[1/5] 로그인 세션(cookies.txt) 유효성 검사 중..." -ForegroundColor Yellow

$NeedLogin = $false
$TargetCookieName = "production_ruckus_support"

if (-not (Test-Path $COOKIE_FILE)) {
    Write-Host "[!] 쿠키 파일이 없습니다. 로그인을 진행합니다." -ForegroundColor Yellow
    $NeedLogin = $true
} else {
    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cookieLines = Get-Content $COOKIE_FILE -Encoding UTF8

    # production_ruckus_support 쿠키만 찾는다.
    $targetCookie = $null

    foreach ($line in $cookieLines) {
        # Netscape 쿠키 파일의 주석 및 빈 줄 건너뛰기
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $parts = $line.Split("`t")

        # Netscape 쿠키 형식:
        # Domain | Flag | Path | Secure | Expiration | Name | Value
        if ($parts.Count -ge 7 -and $parts[5].Trim() -eq $TargetCookieName) {
            $targetCookie = $parts
            break
        }
    }

    if (-not $targetCookie) {
        Write-Host "[!] '$TargetCookieName' 쿠키를 찾을 수 없습니다. 재로그인을 진행합니다." -ForegroundColor Yellow
        $NeedLogin = $true
    } else {
        $expEpoch = 0

        if ([long]::TryParse($targetCookie[4].Trim(), [ref]$expEpoch)) {
            if ($expEpoch -gt 0 -and $expEpoch -le $nowEpoch) {
                Write-Host "[!] '$TargetCookieName' 쿠키가 만료되었습니다." -ForegroundColor Red
                $NeedLogin = $true
            } else {
                $expireDate = [DateTimeOffset]::FromUnixTimeSeconds($expEpoch).ToLocalTime()
                Write-Host "[+] '$TargetCookieName' 쿠키가 유효합니다." -ForegroundColor Green
            }
        } else {
            Write-Host "[!] '$TargetCookieName' 쿠키의 만료 시간을 확인할 수 없습니다. 재로그인을 진행합니다." -ForegroundColor Yellow
            $NeedLogin = $true
        }
    }
}

if ($NeedLogin) {
    Write-Host ""

    # 환경변수 기본값 정돈
    if ($RUCKUS_USER) { $RUCKUS_USER = $RUCKUS_USER.Trim() }
    if ($RUCKUS_PASS) { $RUCKUS_PASS = $RUCKUS_PASS.Trim() }

    # 이메일 정규식 패턴 (기본적인 user@domain.tld 검증)
    $emailRegex = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    # 1. 이메일 입력 검증 루프 (빈값 및 이메일 형식 체크)
    while ([string]::IsNullOrWhiteSpace($RUCKUS_USER) -or ($RUCKUS_USER -notmatch $emailRegex)) {
        if (-not [string]::IsNullOrWhiteSpace($RUCKUS_USER) -and ($RUCKUS_USER -notmatch $emailRegex)) {
            Write-Host "[-] 올바른 이메일 형식이 아닙니다. (예: user@example.com)" -ForegroundColor Red
        }
        
        Write-Host "Ruckus 이메일 계정을 입력하세요:" -ForegroundColor Cyan
        $RUCKUS_USER = (Read-Host " >").Trim()
    }

    # 2. 비밀번호 입력 검증 루프 (빈값 체크)
    while ([string]::IsNullOrWhiteSpace($RUCKUS_PASS)) {
        Write-Host "Ruckus 비밀번호를 입력하세요:" -ForegroundColor Cyan
        $SecurePass = Read-Host " >" -AsSecureString
        
        if ($SecurePass) {
            $RUCKUS_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
            ).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($RUCKUS_PASS)) {
            Write-Host "[-] 비밀번호는 빈값일 수 없습니다. 다시 입력해 주세요." -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "[*] 파이썬 로그인 스크립트 실행 중..." -ForegroundColor Yellow

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    & "$pyExe" -u "$PYTHON_SCRIPT" -u "$RUCKUS_USER" -p "$RUCKUS_PASS" -o "$COOKIE_FILE"

    $pyExitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldPref

    if (($pyExitCode -ne 0) -or (-not (Test-Path $COOKIE_FILE))) {
        Write-Host "[-] 로그인 및 쿠키 생성 실패." -ForegroundColor Red
        exit 1
    }

    Write-Host "[+] 쿠키 발급 완료!" -ForegroundColor Green
} else {
    Write-Host "[+] 기존 cookies.txt 세션이 유효합니다." -ForegroundColor Green
}

#(Get-Content $COOKIE_FILE) |
#    Where-Object { $_ -and -not $_.StartsWith("#") } |
#    Set-Content $COOKIE_FILE -Encoding utf8

# -----------------------------------------------------------------
# [단계 2] 동적 버전 목록 파싱 (200.x 버전 필터링)
# -----------------------------------------------------------------
Write-Host ""
Write-Host "[2/5] Unleashed 소프트웨어 동적 버전 검색 중..." -ForegroundColor Yellow

$pyGetVersionsScript = @"
import sys, re, requests, urllib3
from bs4 import BeautifulSoup
urllib3.disable_warnings()

cookie_file, base_url = sys.argv[1], sys.argv[2]
session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})

with open(cookie_file, 'r', encoding='utf-8') as f:
    for line in f:
        if line.strip() and (not line.startswith('#') or line.startswith('#HttpOnly_')):
            p = line.strip().split('\t')
            if len(p) >= 7:
                session.cookies.set(p[5], p[6], domain=p[0].lstrip('.'))

url = f"{base_url}/products/82/filtered_products?type=software"
try:
    r = session.get(url, verify=False, timeout=15)
    soup = BeautifulSoup(r.text, 'html.parser')
    options = soup.select("#product_software_version select[name='version_filter'] option")
    
    versions = []
    for opt in options:
        val = opt.get('value', '').strip()
        if val.startswith('200.'):
            versions.append(val)
            
    for v in sorted(versions, key=lambda x: [int(p) for p in x.split('.')], reverse=True):
        print(v)
except Exception as e:
    sys.exit(1)
"@

$tempPy = Join-Path $PSScriptRoot "temp_get_versions.py"
$pyGetVersionsScript | Out-File -FilePath $tempPy -Encoding utf8

$oldPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$availableVersions = python $tempPy "$COOKIE_FILE" "$BASE_URL"
$ErrorActionPreference = $oldPref
Remove-Item $tempPy -ErrorAction SilentlyContinue

if (-not $availableVersions -or $availableVersions.Count -eq 0) {
    Write-Host "[-] 200.x 버전을 찾지 못했거나 동적 목록을 불러오지 못했습니다." -ForegroundColor Red
    exit 1
}

# 인터랙티브 메인 루프
while ($true) {
    # -----------------------------------------------------------------
    # [단계 3] 릴리스 버전 선택 (URL 목록을 메모리 변수에 수집)
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "[3/5] 다운로드할 Unleashed 버전을 선택하세요:" -ForegroundColor Yellow
    
    $vIdx = 1
    foreach ($ver in $availableVersions) {
        Write-Host (" {0,2}) Unleashed {1}" -f $vIdx, $ver)
        $vIdx++
    }
    Write-Host "  0) 종료"
    Write-Host ""

    $verChoice = Read-Host "버전 선택 번호"

    if ($verChoice -eq "0") { exit 0 }

    if (-not ([int]::TryParse($verChoice, [ref]$null)) -or [int]$verChoice -lt 1 -or [int]$verChoice -gt $availableVersions.Count) {
        Write-Host "[-] 올바른 번호를 선택해주세요." -ForegroundColor Red
        continue
    }

    $selectedVersion = $availableVersions[[int]$verChoice - 1]
    Write-Host "[*] 선택된 버전 ($selectedVersion)의 다운로드 URL을 수집 중입니다..." -ForegroundColor Cyan

    $pyGetUrlsScript = @"
import sys, re, requests, urllib3
urllib3.disable_warnings()

cookie_file, base_url, version = sys.argv[1], sys.argv[2], sys.argv[3]
session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})

with open(cookie_file, 'r', encoding='utf-8') as f:
    for line in f:
        if line.strip() and (not line.startswith('#') or line.startswith('#HttpOnly_')):
            p = line.strip().split('\t')
            if len(p) >= 7:
                session.cookies.set(p[5], p[6], domain=p[0].lstrip('.'))

url = f"{base_url}/products/82/filtered_products?version={version}&type=software"
urls = []
try:
    r = session.get(url, verify=False, timeout=15)
    matches = re.findall(r'href="(/documents/[^"]+|/software/[^"]+)"', r.text)
    for m in matches:
        if "unleashed" in m.lower() and "snmp" not in m.lower():
            urls.append(base_url + m)
except: pass

for u in sorted(list(set(urls))):
    print(u)
"@

    $tempPy2 = Join-Path $PSScriptRoot "temp_get_urls.py"
    $pyGetUrlsScript | Out-File -FilePath $tempPy2 -Encoding utf8

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $extractedUrls = python $tempPy2 "$COOKIE_FILE" "$BASE_URL" "$selectedVersion"
    $ErrorActionPreference = $oldPref
    Remove-Item $tempPy2 -ErrorAction SilentlyContinue

    if (-not $extractedUrls -or $extractedUrls.Count -eq 0) {
        Write-Host "[-] 해당 버전에서 다운로드할 수 있는 소프트웨어를 찾지 못했습니다." -ForegroundColor Red
        continue
    }

    # -----------------------------------------------------------------
    # [단계 4] 세부 항목 분석 및 다운로드 대상 객체 선택
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "[4/5] 각 세부 항목의 파일 이름 및 용량 분석 중..." -ForegroundColor Yellow

    $fileList = @()
    $fCounter = 1

    foreach ($pageUrl in $extractedUrls) {
        $detailHtml = & curl.exe -k -s -b "$COOKIE_FILE" `
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" `
            "$pageUrl" | Out-String

        $softwareTitle = "N/A"
        if ($detailHtml -match '(?is)<title[^>]*>\s*(.*?)\s*</title>') {
            $fullTitle = [System.Net.WebUtility]::HtmlDecode($Matches[1])
            $softwareTitle = (($fullTitle -split '\|')[0].Trim() -replace '\s+', ' ')
        }

        $realFileName = ""
        if ($detailHtml -match '(?is)<dt>\s*File Name:\s*</dt>\s*<dd>\s*<a[^>]*>\s*([^<]+?)\s*</a>\s*</dd>') {
            $realFileName = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
        }
        if (-not $realFileName) { $realFileName = [System.IO.Path]::GetFileName($pageUrl) }

        $fileSize = "N/A"
        if ($detailHtml -match '(?is)<dt>\s*File Size:\s*</dt>\s*<dd>\s*([^<]+?)\s*</dd>') {
            $fileSize = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
        }

        $fileList += [PSCustomObject]@{
            Index         = $fCounter
            PageUrl       = $pageUrl
            RealFileName  = $realFileName
            SoftwareTitle = $softwareTitle
            FileSize      = $fileSize
        }
        $fCounter++
    }

    Write-Host ""
    Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host ("{0,-6} | {1,-45} | {2,-15}" -f "번호", "파일 이름 (File Name)", "용량 (Size)") -ForegroundColor Cyan
    Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor Gray

    foreach ($f in $fileList) {
        Write-Host ("{0,4}) | {1,-45} | {2,-15}" -f $f.Index, $f.RealFileName, $f.FileSize)
        Write-Host ("     └─ " + $f.SoftwareTitle) -ForegroundColor DarkGray
        Write-Host ""
    }

    Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "  a) 전체 파일 모두 선택 ($($fileList.Count)개)"
    Write-Host "  b) 이전 메뉴로 돌아가기 (버전 재선택)"
    Write-Host "  0) 종료"
    Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor Gray

    $fileChoice = Read-Host "다운로드할 파일 번호 선택 (예: 1, 3 또는 1-5)"

    $selectedFiles = @()

    if ($fileChoice -eq "0") { exit 0 }
    elseif ($fileChoice -eq "b" -or $fileChoice -eq "B") { continue }
    elseif ($fileChoice -eq "a" -or $fileChoice -eq "A" -or [string]::IsNullOrWhiteSpace($fileChoice)) {
        $selectedFiles = $fileList
    } else {
        $selectedIndices = [System.Collections.Generic.List[int]]::new()
        $tokens = $fileChoice -split '[\s,]+'

        foreach ($token in $tokens) {
            if ($token -match '^(\d+)-(\d+)$') {
                for ($n = [int]$Matches[1]; $n -le [int]$Matches[2]; $n++) { $selectedIndices.Add($n) }
            } elseif ($token -match '^\d+$') {
                $selectedIndices.Add([int]$token)
            }
        }

        foreach ($num in ($selectedIndices | Select-Object -Unique | Sort-Object)) {
            if ($num -ge 1 -and $num -le $fileList.Count) {
                $selectedFiles += $fileList[$num - 1]
            }
        }
    }

    if ($selectedFiles.Count -eq 0) {
        Write-Host "[-] 선택된 파일이 없습니다." -ForegroundColor Red
        continue
    }

    # -----------------------------------------------------------------
    # [단계 5] 동시 최대 3개 병렬 다운로드 (curl.exe 완벽 종료 보장)
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "[5/5] 다운로드 실행 중 (총 $($selectedFiles.Count)개 파일 / 최대 3개 동시)..." -ForegroundColor Yellow

    $MaxConcurrent = 3
    $RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxConcurrent)
    $RunspacePool.Open()

    $Jobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:ActiveProcIds = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $CancelState = [hashtable]::Synchronized(@{ Cancelled = $false })

    # 스레드별 다운로드 수행 블록
    $DownloadScriptBlock = {
        param($fileItem, $COOKIE_FILE, $cleanProductName, $StatusData, $ActiveProcIds, $CancelState)

        if ($CancelState.Cancelled) { $StatusData.Status = "중지됨"; return }

        $pageUrl     = $fileItem.PageUrl
        $downloadUrl = $pageUrl -replace '/software/', '/software_downloads/' -replace '/documents/', '/documents_downloads/'
        $refererUrl  = $pageUrl

        # 헤더 파싱을 통한 실제 파일명 도출
        $headRaw = & curl.exe -k -s -I -b "$COOKIE_FILE" -H "User-Agent: Mozilla/5.0" -H "Referer: $refererUrl" "$downloadUrl" | Out-String
        $targetFileName = ""

        if ($headRaw -match '(?i)Location:\s*([^\r\n]+)') {
            $parsedName = ([System.Uri]$Matches[1].Trim()).Segments[-1]
            if ($parsedName -and $parsedName -notmatch '\?') {
                $targetFileName = [System.Uri]::UnescapeDataString($parsedName)
            }
        }
        if (-not $targetFileName -and $headRaw -match '(?i)filename="?([^";\r\n]+)"?') {
            $targetFileName = $Matches[1].Trim()
        }
        if (-not $targetFileName) {
            $targetFileName = $fileItem.RealFileName
        }

        # 파일명 패치
        if ($cleanProductName -and $targetFileName -match '\.bl7$' -and $targetFileName -notmatch "^$cleanProductName") {
            if ($targetFileName -match '^\d+[\d\.]+\.bl7$') {
                $targetFileName = "${cleanProductName}_${targetFileName}"
            }
        }
        
        if ($CancelState.Cancelled) { $StatusData.Status = "중지됨"; return }

        $saveFileName = $targetFileName
        $StatusData.FileName = $saveFileName
        $StatusData.Percent  = 0
        $StatusData.Status   = "다운로드 준비 중..."

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "curl.exe"
        $psi.Arguments = "-k -L -C - --retry 5 --retry-delay 3 -b `"$COOKIE_FILE`" -H `"User-Agent: Mozilla/5.0`" -H `"Referer: $refererUrl`" -o `"$saveFileName`" `"$downloadUrl`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $process = $null
        $curlExitCode = -1

        try {
            $process = [System.Diagnostics.Process]::Start($psi)
            [void]$ActiveProcIds.Add($process.Id)

            while (-not $process.HasExited) {
                if ($CancelState.Cancelled) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    break
                }
                $line = $process.StandardError.ReadLine()
                if ($line) {
                    $tokens = (-split $line.Trim())
                    if ($tokens.Count -ge 4 -and $tokens[0] -match '^\d+$') {
                        $pct = [int]$tokens[0]
                        $totalSize = $tokens[1]
                        $dlSize    = $tokens[3]

                        if ($pct -le 100) {
                            $StatusData.Percent = $pct
                            if ($totalSize -and $dlSize) {
                                $StatusData.SizeInfo = "$dlSize / $totalSize"
                            }
                            $StatusData.Status = "다운로드 중... ($pct%)"
                        }
                    }
                }
            }
            if ($process.HasExited) {
                $curlExitCode = $process.ExitCode
            }
        } catch {
            $StatusData.Status = "중지됨"
        } finally {
            if ($process) {
                try {
                    if (-not $process.HasExited) {
                        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    }
                    $process.WaitForExit()
                } catch {}

                try { [void]$ActiveProcIds.Remove($process.Id) } catch {}
                try { $process.Dispose() } catch {}
            }
        }

        if ($CancelState.Cancelled) { $StatusData.Status = "중지됨"; return }

        # 최종 검증: 파일이 실제로 존재하고 크기가 0보다 크며, 진행률 99% 이상이거나 exitcode가 0, 18, 33인 경우 완료 처리
        if (Test-Path $saveFileName) {
            $fileBytes = (Get-Item $saveFileName).Length
            if ($fileBytes -gt 0 -and ($curlExitCode -eq 0 -or $curlExitCode -eq 33 -or $curlExitCode -eq 18 -or $StatusData.Percent -ge 99)) {
                $StatusData.Percent = 100
                $StatusData.Status  = "완료"
                $StatusData.SizeInfo = "{0:N2} MB" -f ($fileBytes / 1MB)
                return
            }
        }

        $StatusData.Status = "중지/실패"
    }

    # 공유 상태 테이블 정의
    $JobStatuses = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($fileItem in $selectedFiles) {
        $syncHash = [hashtable]::Synchronized(@{
            FileName = $fileItem.RealFileName
            FileSize = $fileItem.FileSize
            SizeInfo = "0 B / " + $fileItem.FileSize
            Percent  = 0
            Status   = "대기 중..."
        })
        $JobStatuses.Add($syncHash)

        $PowerShell = [powershell]::Create()
        $PowerShell.RunspacePool = $RunspacePool
        [void]$PowerShell.AddScript($DownloadScriptBlock).AddArgument($fileItem).AddArgument($COOKIE_FILE).AddArgument($cleanProductName).AddArgument($syncHash).AddArgument($script:ActiveProcIds).AddArgument($CancelState)

        $JobObj = [PSCustomObject]@{
            Pipe   = $PowerShell
            Result = $PowerShell.BeginInvoke()
            Status = $syncHash
        }
        $Jobs.Add($JobObj)
    }

    # GUI 진행 상황 창 (Form) 구성
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Ruckus Firmware 병렬 다운로드 진행상황"
    $form.Width = 720
    $form.Height = 85 + ($Jobs.Count * 65)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $script:IsUserCancelled = $false
    $script:AllDone = $false

    $form.add_FormClosing({
        param($sender, $e)
        try {
            if (-not $script:AllDone) {
                $script:IsUserCancelled = $true
                $CancelState.Cancelled = $true

                $pList = @($script:ActiveProcIds)
                foreach ($pId in $pList) {
                    if ($pId) {
                        Stop-Process -Id $pId -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } catch {}
    })

    $uiElements = @()
    $topPos = 15

    for ($i = 0; $i -lt $Jobs.Count; $i++) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Left = 20; $lbl.Top = $topPos; $lbl.Width = 660; $lbl.Height = 18
        $lbl.Text = "[$($i+1)/$($Jobs.Count)] 대기 중: $($Jobs[$i].Status.FileName) ($($Jobs[$i].Status.FileSize))"
        $form.Controls.Add($lbl)

        $pb = New-Object System.Windows.Forms.ProgressBar
        $pb.Left = 20; $pb.Top = $topPos + 20; $pb.Width = 660; $pb.Height = 20
        $pb.Minimum = 0; $pb.Maximum = 100; $pb.Value = 0
        $form.Controls.Add($pb)

        $uiElements += [PSCustomObject]@{ Label = $lbl; ProgressBar = $pb }
        $topPos += 60
    }

    # UI 실시간 업데이트 타이머
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.add_Tick({
        $allFinished = $true
        for ($i = 0; $i -lt $Jobs.Count; $i++) {
            $st = $Jobs[$i].Status
            $ui = $uiElements[$i]

            $ui.ProgressBar.Value = [math]::Min(100, [math]::Max(0, $st.Percent))
            
            $sizeStr = if ($st.SizeInfo) { " [ " + $st.SizeInfo + " ]" } else { "" }
            $ui.Label.Text = "[$($i+1)/$($Jobs.Count)] [$($st.Status)]$sizeStr $($st.FileName)"

            if (-not $Jobs[$i].Result.IsCompleted) {
                $allFinished = $false
            }
        }

        if ($allFinished) {
            $script:AllDone = $true
            $timer.Stop()
            $form.Close()
        }
    })

    $timer.Start()
    [void]$form.ShowDialog()

    # 스레드 파이프라인 정리
    foreach ($job in $Jobs) {
        try {
            if ($script:IsUserCancelled) {
                $CancelState.Cancelled = $true
            }
            [void]$job.Pipe.EndInvoke($job.Result)
        } catch {}
        finally {
            try { $job.Pipe.Dispose() } catch {}
        }
    }

    if ($script:IsUserCancelled) {
        foreach ($pId in @($script:ActiveProcIds)) {
            try { Stop-Process -Id $pId -Force -ErrorAction SilentlyContinue } catch {}
            try { Wait-Process -Id $pId -Timeout 5 -ErrorAction SilentlyContinue } catch {}
        }
        $script:ActiveProcIds.Clear()

        foreach ($job in $Jobs) {
            $partialFile = $job.Status.FileName
            if ($partialFile -and $job.Status.Status -ne "완료" -and (Test-Path -LiteralPath $partialFile)) {
                Write-Host "  [~] 중단 파일 유지(이어받기 가능): $partialFile" -ForegroundColor Cyan
            }
        }
    }

    $RunspacePool.Close()
    $RunspacePool.Dispose()

    # 결과 메시지 출력
    if ($script:IsUserCancelled) {
        Write-Host "  [!] 사용자에 의해 다운로드가 중지되었습니다. 중단된 파일은 유지되며 같은 파일을 다시 선택하면 이어받습니다." -ForegroundColor Yellow
    } else {
        foreach ($job in $Jobs) {
            if ($job.Status.Status -eq "완료") {
                Write-Host "  [+] 완료: $($job.Status.FileName) ($($job.Status.SizeInfo))" -ForegroundColor Green
            } else {
                Write-Host "  [-] 중지/실패: $($job.Status.FileName)" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "[+] 다운로드 작업이 완료되었습니다." -ForegroundColor Green
    }

    Write-Host ""
    $continueChoice = Read-Host "다른 파일도 다운로드하시겠습니까? (y/n)"
    if ($continueChoice -eq "y" -or $continueChoice -eq "Y") {
        continue
    } else {
        break
    }
}

Write-Host "[+] 프로그램을 종료합니다." -ForegroundColor Cyan
