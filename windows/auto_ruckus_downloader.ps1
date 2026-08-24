# =================================================================
# Ruckus Firmware Auto Downloader for Windows
# - Universal Ruckus Product Line Support (APs, ICX, vSZ, Unleashed)
# - Automatic Model Name Prefixing for version-only .bl7 files
# - Parallel Downloading Support (Max 3 Concurrent)
# =================================================================
$Version = "v1.2.0"

# Windows Forms 어셈블리 로드 및 예외 처리 모드 선언 (스크립트 시작 시 1회만 실행)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = "Stop"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$COOKIE_FILE   = Join-Path $PSScriptRoot "cookies.txt"
$PYTHON_SCRIPT = Join-Path $PSScriptRoot "get_ruckus_cookie.py"
$BASE_URL      = "https://support.ruckuswireless.com"

$RUCKUS_USER = $env:RUCKUS_USER
$RUCKUS_PASS = $env:RUCKUS_PASS

Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "   Ruckus Universal Firmware Auto Downloader ($Version)" -ForegroundColor Cyan
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
# [단계 1] 쿠키 확인 및 로그인 (production_ruckus_support 인증 확인)
# -----------------------------------------------------------------
Write-Host "[1/5] 로그인 세션(cookies.txt) 유효성 검사 중..." -ForegroundColor Yellow

$TargetCookieName   = "production_ruckus_support"
$TargetCookieDomain = "support.ruckuswireless.com"

function Get-RuckusAuthCookie {
    param(
        [string]$CookiePath
    )

    if (-not (Test-Path $CookiePath)) {
        return $null
    }

    try {
        $cookieLines = Get-Content $CookiePath -Encoding UTF8 -ErrorAction Stop

        foreach ($line in $cookieLines) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                continue
            }

            $parts = $line -split "`t"

            if ($parts.Count -ge 7) {
                $cookieDomain = $parts[0].Trim()
                $cookieName   = $parts[5].Trim()
                $cookieValue  = $parts[6].Trim()

                if (
                    $cookieDomain -eq $TargetCookieDomain -and
                    $cookieName -eq $TargetCookieName -and
                    -not [string]::IsNullOrWhiteSpace($cookieValue)
                ) {
                    return $parts
                }
            }
        }
    }
    catch {
        Write-Host "[!] cookies.txt 파일을 확인하는 중 오류가 발생했습니다: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    return $null
}

function Test-RuckusLoginCookie {
    param(
        [string]$CookiePath
    )

    $authCookie = Get-RuckusAuthCookie -CookiePath $CookiePath

    if (-not $authCookie) {
        return $false
    }

    [long]$expEpoch = 0

    if (-not [long]::TryParse($authCookie[4].Trim(), [ref]$expEpoch)) {
        return $false
    }

    if ($expEpoch -gt 0) {
        $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        if ($expEpoch -le $nowEpoch) {
            return $false
        }
    }

    return $true
}

$NeedLogin = $true

if (Test-Path $COOKIE_FILE) {
    if (Test-RuckusLoginCookie -CookiePath $COOKIE_FILE) {
        $NeedLogin = $false
        Write-Host "[+] 기존 로그인 세션이 유효합니다." -ForegroundColor Green
        Write-Host "[+] '$TargetCookieName' 인증 쿠키를 확인했습니다." -ForegroundColor Green
    }
    else {
        Write-Host "[!] 기존 cookies.txt에 유효한 '$TargetCookieName' 인증 쿠키가 없습니다." -ForegroundColor Yellow
        Write-Host "[!] 로그인을 다시 진행합니다." -ForegroundColor Yellow

        Remove-Item $COOKIE_FILE -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host "[!] 쿠키 파일이 없습니다. 로그인을 진행합니다." -ForegroundColor Yellow
}

while ($NeedLogin) {
    Write-Host ""

    $RUCKUS_USER = $null
    $RUCKUS_PASS = $null

    $emailRegex = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'

    while ([string]::IsNullOrWhiteSpace($RUCKUS_USER) -or ($RUCKUS_USER -notmatch $emailRegex)) {
        if (-not [string]::IsNullOrWhiteSpace($RUCKUS_USER) -and ($RUCKUS_USER -notmatch $emailRegex)) {
            Write-Host "[-] 올바른 이메일 형식이 아닙니다. (예: user@example.com)" -ForegroundColor Red
        }

        Write-Host "Ruckus 이메일 계정을 입력하세요:" -ForegroundColor Cyan
        $RUCKUS_USER = (Read-Host " >").Trim()
    }

    while ([string]::IsNullOrWhiteSpace($RUCKUS_PASS)) {
        Write-Host "Ruckus 비밀번호를 입력하세요:" -ForegroundColor Cyan
        $SecurePass = Read-Host " >" -AsSecureString

        if ($SecurePass) {
            $bstr = [IntPtr]::Zero

            try {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
                $RUCKUS_PASS = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

                if ($RUCKUS_PASS) {
                    $RUCKUS_PASS = $RUCKUS_PASS.Trim()
                }
            }
            finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($RUCKUS_PASS)) {
            Write-Host "[-] 비밀번호는 빈값일 수 없습니다. 다시 입력해 주세요." -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "[*] 파이썬 로그인 스크립트 실행 중..." -ForegroundColor Yellow

    Remove-Item $COOKIE_FILE -Force -ErrorAction SilentlyContinue

    $pythonOutput = & "$pyExe" -u "$PYTHON_SCRIPT" -u "$RUCKUS_USER" -p "$RUCKUS_PASS" -o "$COOKIE_FILE" 2>&1
    $pyExitCode = $LASTEXITCODE

    if ($pyExitCode -ne 0 -and $pythonOutput) {
        Write-Host ""
        Write-Host "[로그인 프로그램 메시지]" -ForegroundColor DarkYellow
        foreach ($line in $pythonOutput) {
            Write-Host $line
        }
    }

    if ($pyExitCode -ne 0) {
        Write-Host ""
        Write-Host "=================================================" -ForegroundColor Red
        Write-Host "[!] 로그인 스크립트 실행에 실패했습니다." -ForegroundColor Yellow
        Write-Host "=================================================" -ForegroundColor Red

        Remove-Item $COOKIE_FILE -Force -ErrorAction SilentlyContinue
        continue
    }

    if (-not (Test-Path $COOKIE_FILE)) {
        Write-Host ""
        Write-Host "=================================================" -ForegroundColor Red
        Write-Host "[!] cookies.txt 파일이 생성되지 않았습니다." -ForegroundColor Yellow
        Write-Host "=================================================" -ForegroundColor Red
        continue
    }

    if (-not (Test-RuckusLoginCookie -CookiePath $COOKIE_FILE)) {
        Write-Host ""
        Write-Host "=================================================" -ForegroundColor Red
        Write-Host "[-] 로그인에 실패했습니다. 다시 시도하세요." -ForegroundColor Red
        Write-Host "=================================================" -ForegroundColor Red

        Remove-Item $COOKIE_FILE -Force -ErrorAction SilentlyContinue
        continue
    }

    $NeedLogin = $false

    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host "[+] 로그인에 성공했습니다!" -ForegroundColor Green
    Write-Host "[+] '$TargetCookieName' 인증 쿠키를 확인했습니다." -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green
}


# -----------------------------------------------------------------
:ProductLoop while ($true) {

    # -----------------------------------------------------------------
    # [단계 2] 제품 카테고리 동적 파싱
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "[2/5] Ruckus 제품 카테고리 동적 파싱 중..." -ForegroundColor Yellow

    $softwareHtml = & curl.exe -k -s -b "$COOKIE_FILE" `
      -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" `
      "$BASE_URL/software" | Out-String

    $optGroupMatches = [regex]::Matches($softwareHtml, '(?s)<optgroup label="([^"]+)">\s*(.*?)\s*</optgroup>')

    $allowedGroups = @(
        "RUCKUS Indoor APs",
        "RUCKUS Outdoor APs",
        "RUCKUS ICX Switches",
        "Virtual SmartZone (vSZ)",
        "RUCKUS Unleashed"
    )

    $productList = @()
    $pCount = 1

    foreach ($group in $optGroupMatches) {
        $groupLabel = $group.Groups[1].Value.Trim()
        $groupContent = $group.Groups[2].Value

        $isNormalGroup = $allowedGroups -contains $groupLabel
        $isEolGroup    = $groupLabel -eq "EOL RUCKUS Products"

        if ($isNormalGroup -or $isEolGroup) {
            $optionMatches = [regex]::Matches($groupContent, '<option value="(\d+)">([^<]+)</option>')

            foreach ($opt in $optionMatches) {
                $val  = $opt.Groups[1].Value.Trim()
                $name = $opt.Groups[2].Value.Trim()

                if ($isEolGroup -and ($name -notmatch '(?i)(Ruckus|SmartZone|ZoneDirector)')) { continue }
                if ($name -match '^zzz') { continue }

                $productList += [PSCustomObject]@{
                    Index = $pCount
                    Group = $groupLabel
                    Id    = $val
                    Name  = $name
                }
                $pCount++
            }
        }
    }

    if ($productList.Count -eq 0) {
        Write-Host "[-] 제품 목록을 동적으로 가져오지 못했습니다." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host ("{0,-4} | {1,-24} | {2}" -f "번호", "카테고리 (Group)", "제품명 (Product Name)") -ForegroundColor Cyan
    Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray

    foreach ($p in $productList) {
        Write-Host ("{0,4}) | {1,-24} | {2}" -f $p.Index, $p.Group, $p.Name)
    }

    Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host " 0) 종료"
    Write-Host ""

    $pChoice = Read-Host "대상 제품 선택 번호"
    if ($pChoice -eq "0" -or [string]::IsNullOrWhiteSpace($pChoice)) { exit 0 }

    $selectedProduct = $productList | Where-Object { $_.Index -eq [int]$pChoice }
    if (-not $selectedProduct) {
        Write-Host "[-] 올바른 번호를 선택해주세요." -ForegroundColor Red
        continue
    }

    $cleanProductName = $selectedProduct.Name -replace '(?i)^(Ruckus|ZoneFlex|SmartZone)\s+', '' -replace '\s+', '_'
    Write-Host "[+] 선택된 제품: [$($selectedProduct.Group)] $($selectedProduct.Name) (ID: $($selectedProduct.Id))" -ForegroundColor Green

    # -----------------------------------------------------------------
    :VersionLoop while ($true) {

        # [단계 3] 지원 버전 목록 파싱
        # -----------------------------------------------------------------
        Write-Host ""
        Write-Host "[3/5] 지원 펌웨어 버전 정보 수집 중..." -ForegroundColor Yellow

        $filterUrl = "$BASE_URL/products/$($selectedProduct.Id)/filtered_products?type=software"
        $filterHtml = & curl.exe -k -s -b "$COOKIE_FILE" `
          -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" `
          "$filterUrl" | Out-String

        $versionList = @()

        if ($filterHtml -match "(?s)<div\s+id=['""]product_software_version['""]\s*>(.*?)</div>") {
            $versionDivContent = $Matches[1]
            $optionMatches = [regex]::Matches($versionDivContent, '<option\s+value=["'']([^"'']*)["'']>([^<]+)</option>')
            
            $vCount = 1
            foreach ($om in $optionMatches) {
                $vVal  = $om.Groups[1].Value.Trim()
                $vText = $om.Groups[2].Value.Trim()

                if ($vVal -ne "" -and $vText -notmatch "Choose A Version") {
                    $versionList += [PSCustomObject]@{
                        Index   = $vCount
                        Version = $vVal
                    }
                    $vCount++
                }
            }
        }

        if ($versionList.Count -eq 0) {
            Write-Host "[!] 지정 영역에서 버전을 찾지 못했습니다. 전체 조회를 진행합니다." -ForegroundColor Yellow
            $selectedVersion = ""
        } else {
            Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray
            Write-Host " [ 파싱된 버전 목록 ]" -ForegroundColor Cyan
            Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray
            
            foreach ($v in $versionList) {
                Write-Host ("{0,3}) Version {1}" -f $v.Index, $v.Version)
            }
            
            Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray
            Write-Host " a) 모든 버전 선택 (전체 조회)"
            Write-Host " b) 이전 메뉴로 돌아가기 (제품 재선택)"
            Write-Host " 0) 종료"
            Write-Host "----------------------------------------------------------------------------" -ForegroundColor Gray

            $vChoice = Read-Host "버전 선택 번호"
            if ($vChoice -eq "0") { exit 0 }
            elseif ($vChoice -eq "b" -or $vChoice -eq "B") { continue ProductLoop }
            elseif ($vChoice -eq "a" -or $vChoice -eq "A") { 
                $selectedVersion = "" 
            }
            else {
                $selectedObj = $versionList | Where-Object { $_.Index -eq [int]$vChoice }
                if ($selectedObj) {
                    $selectedVersion = $selectedObj.Version
                } else {
                    Write-Host "[-] 잘못된 번호입니다. 전체 조회를 진행합니다." -ForegroundColor Red
                    $selectedVersion = ""
                }
            }
        }

        Write-Host "[+] 선택된 버전: $(if($selectedVersion){ $selectedVersion } else { 'ALL' })" -ForegroundColor Green

        # -----------------------------------------------------------------
        # [단계 4] 세부 소프트웨어 항목 파싱 (버전 변경 시 1회 파싱 후 캐싱)
        # -----------------------------------------------------------------
        Write-Host ""
        Write-Host "[4/5] 각 세부 항목의 파일 이름 및 용량 분석 중..." -ForegroundColor Yellow

        $versionParam = if ($selectedVersion) { "?version=$selectedVersion&type=software" } else { "?type=software" }
        $targetSoftwareListUrl = "$BASE_URL/products/$($selectedProduct.Id)/filtered_products$versionParam"

        $swListHtml = & curl.exe -k -s -b "$COOKIE_FILE" `
          -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" `
          "$targetSoftwareListUrl" | Out-String

        $subLinkMatches = [regex]::Matches($swListHtml, 'href="(/software/(\d+-[^"]+))"')
        $subUrls = @()

        foreach ($sm in $subLinkMatches) {
            $fullSubUrl = "$BASE_URL" + $sm.Groups[1].Value
            if ($subUrls -notcontains $fullSubUrl) { $subUrls += $fullSubUrl }
        }

        if ($subUrls.Count -eq 0) {
            Write-Host "[-] 다운로드 가능한 소프트웨어 항목을 찾을 수 없습니다." -ForegroundColor Red
            continue VersionLoop
        }

        # 메모리에 유지될 파싱 결과 리스트
        $cachedFileList = @()
        $fCounter = 1

        foreach ($pageUrl in $subUrls) {
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

            if ($cleanProductName -and $realFileName -match '^\d+[\d\.]+\.bl7$') {
                $realFileName = "${cleanProductName}_${realFileName}"
            }

            $fileSize = "N/A"
            if ($detailHtml -match '(?is)<dt>\s*File Size:\s*</dt>\s*<dd>\s*([^<]+?)\s*</dd>') {
                $fileSize = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
            }

            $cachedFileList += [PSCustomObject]@{
                Index         = $fCounter
                PageUrl       = $pageUrl
                RealFileName  = $realFileName
                SoftwareTitle = $softwareTitle
                FileSize      = $fileSize
            }
            $fCounter++
        }

        # -----------------------------------------------------------------
        :FileLoop while ($true) {

            # 캐시된 파일 목록 사용
            $fileList = $cachedFileList

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
            Write-Host "  b) 이전 메뉴로 돌아가기 (제품/버전 재선택)"
            Write-Host "  0) 종료"
            Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor Gray

            $fChoice = Read-Host "다운로드할 파일 번호 선택 (예: 1, 3 또는 1-5)"

            $selectedFiles = @()

            if ($fChoice -eq "0") { exit 0 }
            elseif ($fChoice -eq "b" -or $fChoice -eq "B") { continue VersionLoop }
            elseif ($fChoice -eq "a" -or $fChoice -eq "A" -or [string]::IsNullOrWhiteSpace($fChoice)) {
                $selectedFiles = $fileList
            } else {
                $selectedIndices = [System.Collections.Generic.List[int]]::new()
                $tokens = $fChoice -split '[\s,]+'

                foreach ($token in $tokens) {
                    if ($token -match '^(\d+)-(\d+)$') {
                        for ($n = [int]$Matches[1]; $n -le [int]$Matches[2]; $n++) { $selectedIndices.Add($n) }
                    } elseif ($token -match '^\d+$') {
                        $selectedIndices.Add([int]$token)
                    }
                }

                foreach ($num in ($selectedIndices | Select-Object -Unique | Sort-Object)) {
                    if ($num -ge 1 -and $num -le $fileList.Count) { $selectedFiles += $fileList[$num - 1] }
                }
            }

            if ($selectedFiles.Count -eq 0) {
                Write-Host "[-] 선택된 파일이 없습니다." -ForegroundColor Red
                continue FileLoop
            }

            # -----------------------------------------------------------------
            # [단계 5] 동시 최대 3개 병렬 다운로드
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

                $pageUrl  = $fileItem.PageUrl
                $uaHeader = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
                $eulaQuery = "utf8=%E2%9C%93&tc_form%5Bagreement%5D=I+%22Understand+and+Agree%22&commit=Download"

                # 1. 페이지 요청 및 EULA 엔드포인트 도출
                $pageHtml = & curl.exe -k -s -b "$COOKIE_FILE" -H "User-Agent: $uaHeader" "$pageUrl" | Out-String

                $downloadEndpointUrl = $null
                if ($pageHtml -match 'action="(/software_downloads/[^"]+)"') {
                    $downloadEndpointUrl = "https://support.ruckuswireless.com" + $Matches[1] + "?$eulaQuery"
                } elseif ($pageHtml -match 'action="(/documents_downloads/[^"]+)"') {
                    $downloadEndpointUrl = "https://support.ruckuswireless.com" + $Matches[1] + "?$eulaQuery"
                } else {
                    $downloadEndpointUrl = ($pageUrl -replace '/software/', '/software_downloads/') + "?$eulaQuery"
                }

                # 2. 약관 동의 제출 및 최종 S3 direct URL 추출 (Location 정보 분석)
                $headRaw = & curl.exe -k -s -I -b "$COOKIE_FILE" -H "User-Agent: $uaHeader" -H "Referer: $pageUrl" "$downloadEndpointUrl" | Out-String

                $finalDirectUrl = $downloadEndpointUrl
                if ($headRaw -match '(?i)Location:\s*([^\r\n]+)') {
                    $loc = $Matches[1].Trim()
                    if ($loc -match '^https?://') {
                        $finalDirectUrl = $loc
                    } else {
                        $finalDirectUrl = "https://support.ruckuswireless.com" + $loc
                    }
                }

                # Location 헤더 URL 또는 Content-Disposition 헤더에서 실제 원본 파일명 추출
                $extractedFileName = $null
                if ($headRaw -match '(?i)Content-Disposition:.*filename="?([^";\r\n]+)"?') {
                    $extractedFileName = $Matches[1].Trim()
                } elseif ($finalDirectUrl) {
                    $cleanUri = ($finalDirectUrl -split '\?')[0]
                    $urlFile = [System.IO.Path]::GetFileName($cleanUri)
                    if ($urlFile -match '^\d+-(.+)$') { 
                        $extractedFileName = $Matches[1] 
                    } elseif ($urlFile) { 
                        $extractedFileName = $urlFile 
                    }
                }

                # 저장 파일명 결정 (말줄임표가 포함되어 있거나 비어있는 경우 추출한 원본 파일명 적용)
                $saveFileName = $fileItem.RealFileName
                if (($saveFileName -match '\.{3,}$' -or [string]::IsNullOrWhiteSpace($saveFileName)) -and $extractedFileName) {
                    $saveFileName = $extractedFileName
                }

                $StatusData.FileName = $saveFileName
                $StatusData.Percent  = 0
                $StatusData.Status   = "다운로드 준비 중..."

                # curl 실행
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "curl.exe"
                $psi.Arguments = "-k -L -C - --retry 5 --retry-delay 3 -b `"$COOKIE_FILE`" -c `"$COOKIE_FILE`" -H `"User-Agent: $uaHeader`" -H `"Referer: $pageUrl`" -o `"$saveFileName`" `"$finalDirectUrl`""
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

                if (Test-Path $saveFileName) {
                    $fileBytes = (Get-Item $saveFileName).Length

                    if ($fileBytes -lt 50000) {
                        $headContent = Get-Content $saveFileName -Head 10 -ErrorAction SilentlyContinue | Out-String
                        if ($headContent -match '(?i)(<html|login|doctype)') {
                            Remove-Item $saveFileName -Force -ErrorAction SilentlyContinue
                            $StatusData.Status = "중지/실패"
                            return
                        }
                    }

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

            # 메시지 및 이동
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
                continue FileLoop
            } else {
                break ProductLoop
            }
        } # FileLoop
    } # VersionLoop
} # ProductLoop

Write-Host "[+] 프로그램을 종료합니다." -ForegroundColor Cyan
