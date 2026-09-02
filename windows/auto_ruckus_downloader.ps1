# =================================================================
# Ruckus Firmware Auto Downloader - Full GUI Edition (v1.1.0)
# - Windows Forms Full GUI Interface
# - Universal Support (AP, ICX, vSZ, Unleashed)
# - Auto Session Verification & Parallel Downloader
# - 'ALL' version query: Iterates through all individual versions without pagination
# - Added: Real-time Search/Filter & Column Sorting
# - Added: Automatic model prefixing for 'rcks_fw.bl7' type files
# =================================================================

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    exit $p.ExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$COOKIE_FILE   = Join-Path $PSScriptRoot "cookies.txt"
$PYTHON_SCRIPT = Join-Path $PSScriptRoot "get_ruckus_cookie.py"
$BASE_URL      = "https://support.ruckuswireless.com"
$UA            = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# ListView 컬럼 정렬을 위한 Comparer 클래스 정의
class ListViewComparer : System.Collections.IComparer {
    [int]$Column
    [bool]$Ascending
    ListViewComparer([int]$col, [bool]$asc) {
        $this.Column = $col
        $this.Ascending = $asc
    }
    [int] Compare([object]$x, [object]$y) {
        $cx = $x.SubItems[$this.Column].Text
        $cy = $y.SubItems[$this.Column].Text
        
        $result = [string]::Compare($cx, $cy)
        if (-not $this.Ascending) { $result = -$result }
        return $result
    }
}

function Test-PythonEnv {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCmd -or $pythonCmd.Source -match "WindowsApps") {
        winget install --id Python.Python.3.12 --source winget --scope user --silent --accept-package-agreements --accept-source-agreements | Out-Null
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }
    $pyExe = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $pyExe -or $pyExe -match "WindowsApps") {
        $pyExe = Join-Path $env:LocalAppData "Programs\Python\Python312\python.exe"
    }
    if (-not (Test-Path $pyExe)) { return $null }
    $modules = @{ "requests"="requests"; "bs4"="beautifulsoup4"; "lxml"="lxml" }
    foreach ($importName in $modules.Keys) {
        $pkgName = $modules[$importName]
        $checkScript = "import sys, importlib.util; sys.exit(0 if importlib.util.find_spec('$importName') else 1)"
        & "$pyExe" -c "$checkScript"
        if ($LASTEXITCODE -ne 0) { & "$pyExe" -m pip install $pkgName --quiet }
    }
    return $pyExe
}

function Test-CookieValid {
    if (-not (Test-Path $COOKIE_FILE)) { return $false }
    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cookieLines = Get-Content $COOKIE_FILE -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $cookieLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $parts = $line.Split("`t")
        if ($parts.Count -ge 7 -and $parts[5].Trim() -eq "production_ruckus_support") {
            $expEpoch = 0
            if ([long]::TryParse($parts[4].Trim(), [ref]$expEpoch)) {
                if ($expEpoch -gt $nowEpoch) { return $true }
            }
        }
    }
    return $false
}

function Clear-SessionLists {
    $cmbProd.Items.Clear()
    $cmbVer.Items.Clear()
    $listView.Items.Clear()
    $script:ProductDataList = @()
    $script:FileDataList = @()
    $lblSelectedInfo.Text = "제품을 불러오려면 로그인이 필요합니다."
}

$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text = "Ruckus Firmware Auto Downloader v1.1.0 (GUI)"
$mainForm.Size = New-Object System.Drawing.Size(850, 710)
$mainForm.StartPosition = "CenterScreen"
$mainForm.FormBorderStyle = "FixedSingle"
$mainForm.MaximizeBox = $false

$fontLabel = New-Object System.Drawing.Font("맑은 고딕", 9, [System.Drawing.FontStyle]::Regular)
$fontBold  = New-Object System.Drawing.Font("맑은 고딕", 9, [System.Drawing.FontStyle]::Bold)

$grpLogin = New-Object System.Windows.Forms.GroupBox
$grpLogin.Text = " 1. Ruckus 계정 세션 관리 "
$grpLogin.Location = New-Object System.Drawing.Point(15, 10)
$grpLogin.Size = New-Object System.Drawing.Size(805, 75)
$grpLogin.Font = $fontBold
$mainForm.Controls.Add($grpLogin)

$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = "Email:"
$lblUser.Location = New-Object System.Drawing.Point(15, 30)
$lblUser.Size = New-Object System.Drawing.Size(45, 20)
$lblUser.Font = $fontLabel
$grpLogin.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(65, 27)
$txtUser.Size = New-Object System.Drawing.Size(170, 23)
$txtUser.Text = $env:RUCKUS_USER
$txtUser.Font = $fontLabel
$grpLogin.Controls.Add($txtUser)

$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Text = "PW:"
$lblPass.Location = New-Object System.Drawing.Point(242, 30)
$lblPass.Size = New-Object System.Drawing.Size(30, 20)
$lblPass.Font = $fontLabel
$grpLogin.Controls.Add($lblPass)

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(274, 27)
$txtPass.Size = New-Object System.Drawing.Size(130, 23)
$txtPass.PasswordChar = '*'
$txtPass.Text = $env:RUCKUS_PASS
$txtPass.Font = $fontLabel
$grpLogin.Controls.Add($txtPass)

$btnLogin = New-Object System.Windows.Forms.Button
$btnLogin.Text = "로그인 및 세션 갱신"
$btnLogin.Location = New-Object System.Drawing.Point(412, 25)
$btnLogin.Size = New-Object System.Drawing.Size(130, 27)
$btnLogin.Font = $fontLabel
$grpLogin.Controls.Add($btnLogin)

$btnClearCookie = New-Object System.Windows.Forms.Button
$btnClearCookie.Text = "쿠키 삭제"
$btnClearCookie.Location = New-Object System.Drawing.Point(548, 25)
$btnClearCookie.Size = New-Object System.Drawing.Size(85, 27)
$btnClearCookie.Font = $fontLabel
$grpLogin.Controls.Add($btnClearCookie)

$lblSessionStatus = New-Object System.Windows.Forms.Label
$lblSessionStatus.Text = "세션 상태: 확인 중..."
$lblSessionStatus.Location = New-Object System.Drawing.Point(640, 30)
$lblSessionStatus.Size = New-Object System.Drawing.Size(155, 20)
$lblSessionStatus.Font = $fontLabel
$grpLogin.Controls.Add($lblSessionStatus)

$grpSelect = New-Object System.Windows.Forms.GroupBox
$grpSelect.Text = " 2. 제품 및 버전 선택 "
$grpSelect.Location = New-Object System.Drawing.Point(15, 95)
$grpSelect.Size = New-Object System.Drawing.Size(805, 90)
$grpSelect.Font = $fontBold
$mainForm.Controls.Add($grpSelect)

$lblProd = New-Object System.Windows.Forms.Label
$lblProd.Text = "제품 선택:"
$lblProd.Location = New-Object System.Drawing.Point(15, 28)
$lblProd.Size = New-Object System.Drawing.Size(65, 20)
$lblProd.Font = $fontLabel
$grpSelect.Controls.Add($lblProd)

$cmbProd = New-Object System.Windows.Forms.ComboBox
$cmbProd.Location = New-Object System.Drawing.Point(85, 25)
$cmbProd.Size = New-Object System.Drawing.Size(320, 23)
$cmbProd.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbProd.Font = $fontLabel
$grpSelect.Controls.Add($cmbProd)

$lblVer = New-Object System.Windows.Forms.Label
$lblVer.Text = "버전 선택:"
$lblVer.Location = New-Object System.Drawing.Point(420, 28)
$lblVer.Size = New-Object System.Drawing.Size(65, 20)
$lblVer.Font = $fontLabel
$grpSelect.Controls.Add($lblVer)

$cmbVer = New-Object System.Windows.Forms.ComboBox
$cmbVer.Location = New-Object System.Drawing.Point(490, 25)
$cmbVer.Size = New-Object System.Drawing.Size(180, 23)
$cmbVer.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbVer.Font = $fontLabel
$grpSelect.Controls.Add($cmbVer)

$btnFetchFiles = New-Object System.Windows.Forms.Button
$btnFetchFiles.Text = "파일 목록 조회"
$btnFetchFiles.Location = New-Object System.Drawing.Point(680, 23)
$btnFetchFiles.Size = New-Object System.Drawing.Size(110, 55)
$btnFetchFiles.Font = $fontLabel
$grpSelect.Controls.Add($btnFetchFiles)

$lblSelectedInfo = New-Object System.Windows.Forms.Label
$lblSelectedInfo.Text = "제품을 불러오는 중입니다..."
$lblSelectedInfo.Location = New-Object System.Drawing.Point(15, 58)
$lblSelectedInfo.Size = New-Object System.Drawing.Size(655, 20)
$lblSelectedInfo.Font = $fontLabel
$lblSelectedInfo.ForeColor = [System.Drawing.Color]::Blue
$grpSelect.Controls.Add($lblSelectedInfo)

$grpFiles = New-Object System.Windows.Forms.GroupBox
$grpFiles.Text = " 3. 다운로드 가능 파일 목록 (검색 및 정렬 가능) "
$grpFiles.Location = New-Object System.Drawing.Point(15, 195)
$grpFiles.Size = New-Object System.Drawing.Size(805, 410)
$grpFiles.Font = $fontBold
$mainForm.Controls.Add($grpFiles)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "결과 내 검색:"
$lblSearch.Location = New-Object System.Drawing.Point(15, 25)
$lblSearch.Size = New-Object System.Drawing.Size(80, 20)
$lblSearch.Font = $fontLabel
$grpFiles.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(95, 23)
$txtSearch.Size = New-Object System.Drawing.Size(695, 23)
$txtSearch.Font = $fontLabel
$grpFiles.Controls.Add($txtSearch)

$listView = New-Object System.Windows.Forms.ListView
$listView.Location = New-Object System.Drawing.Point(15, 55)
$listView.Size = New-Object System.Drawing.Size(775, 305)
$listView.View = [System.Windows.Forms.View]::Details
$listView.CheckBoxes = $true
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.Font = $fontLabel
[void]$listView.Columns.Add("파일명 (Real File Name)", 280)
[void]$listView.Columns.Add("용량 (Size)", 90)
[void]$listView.Columns.Add("소프트웨어 타이틀 (Title)", 380)
$grpFiles.Controls.Add($listView)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = "전체 선택/해제"
$btnSelectAll.Location = New-Object System.Drawing.Point(15, 370)
$btnSelectAll.Size = New-Object System.Drawing.Size(110, 28)
$btnSelectAll.Font = $fontLabel
$grpFiles.Controls.Add($btnSelectAll)

$btnStartDownload = New-Object System.Windows.Forms.Button
$btnStartDownload.Text = "선택 파일 다운로드 실행 (최대 3개 병렬)"
$btnStartDownload.Location = New-Object System.Drawing.Point(540, 367)
$btnStartDownload.Size = New-Object System.Drawing.Size(250, 33)
$btnStartDownload.Font = $fontBold
$btnStartDownload.BackColor = [System.Drawing.Color]::LightSkyBlue
$grpFiles.Controls.Add($btnStartDownload)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "준비 완료."
[void]$statusStrip.Items.Add($statusLabel)
$mainForm.Controls.Add($statusStrip)

$script:ProductDataList = @()
$script:FileDataList = @()
$script:PyExePath = $null
$script:SelectAllState = $false
$script:SortColumn = -1
$script:SortAscending = $true

$listView.add_ColumnClick({
    param($sender, $e)
    if ($e.Column -eq $script:SortColumn) {
        $script:SortAscending = -not $script:SortAscending
    } else {
        $script:SortColumn = $e.Column
        $script:SortAscending = $true
    }
    $listView.ListViewItemSorter = [ListViewComparer]::new($script:SortColumn, $script:SortAscending)
    $listView.Sort()
})

$txtSearch.add_TextChanged({
    $keyword = $txtSearch.Text.Trim().ToLower()
    $listView.Items.Clear()
    foreach ($fObj in $script:FileDataList) {
        if ([string]::IsNullOrEmpty($keyword) -or 
            $fObj.RealFileName.ToLower().Contains($keyword) -or 
            $fObj.SoftwareTitle.ToLower().Contains($keyword) -or 
            $fObj.FileSize.ToLower().Contains($keyword)) {
            
            $item = New-Object System.Windows.Forms.ListViewItem($fObj.RealFileName)
            [void]$item.SubItems.Add($fObj.FileSize)
            [void]$item.SubItems.Add($fObj.SoftwareTitle)
            $item.Checked = $false
            [void]$listView.Items.Add($item)
        }
    }
    $listView.ListViewItemSorter = $null
})

$ParseDetailBlock = {
    param($pageUrl, $COOKIE_FILE, $UA, $cleanProductName)
    $detailHtml = & curl.exe -k -s --connect-timeout 15 --max-time 30 -b "$COOKIE_FILE" -H "User-Agent: $UA" "$pageUrl" | Out-String
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
    
    # 수정: rcks_fw.bl7 또는 숫자로만 된 .bl7 파일 등 공통 확장자/이름일 경우 모델명 접두사 부여
    if ($cleanProductName) {
        if ($realFileName -match '^\d+[\d\.]+\.bl7$' -or $realFileName -eq 'rcks_fw.bl7') {
            $realFileName = "${cleanProductName}_${realFileName}"
        }
    }

    $fileSize = "N/A"
    if ($detailHtml -match '(?is)<dt>\s*File Size:\s*</dt>\s*<dd>\s*([^<]+?)\s*</dd>') {
        $fileSize = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
    }
    return [PSCustomObject]@{
        PageUrl = $pageUrl
        RealFileName = $realFileName
        SoftwareTitle = $softwareTitle
        FileSize = $fileSize
        CleanProdName = $cleanProductName
    }
}

function Get-FileDetailsParallel {
    param([string[]]$Urls, [string]$CleanName)
    if (-not $Urls -or $Urls.Count -eq 0) { return @() }
    $poolSize = [Math]::Min(8, $Urls.Count)
    $pool = [runspacefactory]::CreateRunspacePool(1, $poolSize)
    $pool.Open()
    $jobs = @()
    foreach ($u in $Urls) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($ParseDetailBlock).AddArgument($u).AddArgument($COOKIE_FILE).AddArgument($UA).AddArgument($CleanName)
        $jobs += [PSCustomObject]@{ Pipe = $ps; Handle = $ps.BeginInvoke(); Url = $u }
    }
    $results = @()
    foreach ($j in $jobs) {
        try {
            $out = $j.Pipe.EndInvoke($j.Handle)
            if ($out) { $results += $out }
        } catch {}
        finally { $j.Pipe.Dispose() }
    }
    $pool.Close(); $pool.Dispose()
    return $results
}

$btnLogin.add_Click({
    $user = $txtUser.Text.Trim()
    $pass = $txtPass.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)) {
        [System.Windows.Forms.MessageBox]::Show("이메일과 비밀번호를 모두 입력해주세요.", "알림", "OK", "Warning")
        return
    }
    $statusLabel.Text = "로그인 시도 중..."
    $mainForm.Refresh()
    Remove-Item $COOKIE_FILE -Force -ErrorAction SilentlyContinue
    & "$script:PyExePath" -u "$PYTHON_SCRIPT" -u "$user" -p "$pass" -o "$COOKIE_FILE"
    if (Test-CookieValid) {
        $lblSessionStatus.Text = "세션 상태: 유효함 (성공)"
        $lblSessionStatus.ForeColor = [System.Drawing.Color]::Green
        $statusLabel.Text = "로그인 성공!"
        Load-Products
    } else {
        $lblSessionStatus.Text = "세션 상태: 로그인 실패"
        $lblSessionStatus.ForeColor = [System.Drawing.Color]::Red
        [System.Windows.Forms.MessageBox]::Show("로그인에 실패했습니다. 계정 정보를 확인하세요.", "오류", "OK", "Error")
    }
})

$btnClearCookie.add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("저장된 로그인 쿠키를 삭제할까요?", "쿠키 삭제", "YesNo", "Question")
    if ($confirm -ne "Yes") { return }
    Remove-Item $COOKIE_FILE -Force -ErrorAction SilentlyContinue
    Clear-SessionLists
    $lblSessionStatus.Text = "세션 상태: 쿠키 없음"
    $lblSessionStatus.ForeColor = [System.Drawing.Color]::Red
    $statusLabel.Text = "쿠키를 삭제했습니다. 다시 로그인하세요."
})

function Load-Products {
    $statusLabel.Text = "제품 카테고리 로딩 중..."
    $cmbProd.Items.Clear()
    $cmbVer.Items.Clear()
    $listView.Items.Clear()
    $mainForm.Refresh()
    $softwareHtml = & curl.exe -k -s --connect-timeout 15 --max-time 30 -b "$COOKIE_FILE" -H "User-Agent: $UA" "$BASE_URL/software" | Out-String
    $optGroupMatches = [regex]::Matches($softwareHtml, '(?s)<optgroup label="([^"]+)">\s*(.*?)\s*</optgroup>')
    $allowedGroups = @("RUCKUS Indoor APs", "RUCKUS Outdoor APs", "RUCKUS ICX Switches", "Virtual SmartZone (vSZ)", "RUCKUS Unleashed")
    $script:ProductDataList = @()
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
                $pObj = [PSCustomObject]@{ Group = $groupLabel; Id = $val; Name = $name }
                $script:ProductDataList += $pObj
                [void]$cmbProd.Items.Add("[$groupLabel] $name")
            }
        }
    }
    if ($cmbProd.Items.Count -gt 0) {
        $cmbProd.SelectedIndex = 0
        $statusLabel.Text = "제품 목록 ($($cmbProd.Items.Count)개) 수집 완료."
    } else {
        $statusLabel.Text = "제품 목록을 불러오지 못했습니다."
    }
}

$cmbProd.add_SelectedIndexChanged({
    if ($cmbProd.SelectedIndex -lt 0) { return }
    $selectedProd = $script:ProductDataList[$cmbProd.SelectedIndex]
    $lblSelectedInfo.Text = "선택된 제품 ID: $($selectedProd.Id) | 카테고리: $($selectedProd.Group)"
    $statusLabel.Text = "지원 버전 파싱 중..."
    $cmbVer.Items.Clear()
    $mainForm.Refresh()
    $filterUrl = "$BASE_URL/products/$($selectedProd.Id)/filtered_products?type=software"
    $filterHtml = & curl.exe -k -s --connect-timeout 15 --max-time 30 -b "$COOKIE_FILE" -H "User-Agent: $UA" "$filterUrl" | Out-String
    [void]$cmbVer.Items.Add("ALL (전체 버전)")
    if ($filterHtml -match "(?s)<div\s+id=['""]product_software_version['""]\s*>(.*?)</div>") {
        $versionDivContent = $Matches[1]
        $optionMatches = [regex]::Matches($versionDivContent, '<option\s+value=["'']([^"'']*)["'']>([^<]+)</option>')
        foreach ($om in $optionMatches) {
            $vVal  = $om.Groups[1].Value.Trim()
            $vText = $om.Groups[2].Value.Trim()
            if ($vVal -ne "" -and $vText -notmatch "Choose A Version") { [void]$cmbVer.Items.Add($vVal) }
        }
    }
    $cmbVer.SelectedIndex = 0
    $statusLabel.Text = "버전 파싱 완료."
})

$btnFetchFiles.add_Click({
    if ($cmbProd.SelectedIndex -lt 0) { return }
    $selectedProd = $script:ProductDataList[$cmbProd.SelectedIndex]
    $cleanProductName = $selectedProd.Name -replace '(?i)^(Ruckus|ZoneFlex|SmartZone)\s+', '' -replace '\s+', '_'
    $isAllVersion = ($cmbVer.SelectedIndex -le 0)
    
    $statusLabel.Text = "소프트웨어 항목 분석 중... (버전별 일괄 조회)"
    $listView.Items.Clear()
    $txtSearch.Text = ""
    $mainForm.Refresh()

    $subUrls = @()

    if ($isAllVersion) {
        $targetVersions = @()
        for ($i = 1; $i -lt $cmbVer.Items.Count; $i++) {
            $targetVersions += $cmbVer.Items[$i].ToString()
        }

        foreach ($ver in $targetVersions) {
            $versionParam = "?version=$ver&type=software"
            $targetSoftwareListUrl = "$BASE_URL/products/$($selectedProd.Id)/filtered_products$versionParam"

            $swListHtml = & curl.exe -k -s --connect-timeout 15 --max-time 30 -b "$COOKIE_FILE" -H "User-Agent: $UA" "$targetSoftwareListUrl" | Out-String
            $subLinkMatches = [regex]::Matches($swListHtml, 'href="(/software/(\d+-[^"]+))"')

            foreach ($sm in $subLinkMatches) {
                $fullSubUrl = "$BASE_URL" + $sm.Groups[1].Value
                if ($subUrls -notcontains $fullSubUrl) {
                    $subUrls += $fullSubUrl
                }
            }
        }
    } else {
        $selectedVersion = $cmbVer.SelectedItem.ToString()
        $versionParam = "?version=$selectedVersion&type=software"
        $targetSoftwareListUrl = "$BASE_URL/products/$($selectedProd.Id)/filtered_products$versionParam"
        
        $swListHtml = & curl.exe -k -s --connect-timeout 15 --max-time 30 -b "$COOKIE_FILE" -H "User-Agent: $UA" "$targetSoftwareListUrl" | Out-String
        $subLinkMatches = [regex]::Matches($swListHtml, 'href="(/software/(\d+-[^"]+))"')
        
        foreach ($sm in $subLinkMatches) {
            $fullSubUrl = "$BASE_URL" + $sm.Groups[1].Value
            if ($subUrls -notcontains $fullSubUrl) {
                $subUrls += $fullSubUrl
            }
        }
    }

    $rawFileDataList = @(Get-FileDetailsParallel -Urls $subUrls -CleanName $cleanProductName)
    $script:FileDataList = @()
    foreach ($fObj in $rawFileDataList) {
        if ($fObj.RealFileName -notmatch '(?i)Software\s*Link') {
            $script:FileDataList += $fObj
        }
    }

    foreach ($fObj in $script:FileDataList) {
        $item = New-Object System.Windows.Forms.ListViewItem($fObj.RealFileName)
        [void]$item.SubItems.Add($fObj.FileSize)
        [void]$item.SubItems.Add($fObj.SoftwareTitle)
        $item.Checked = $false
        [void]$listView.Items.Add($item)
    }
    $script:SelectAllState = $false
    $statusLabel.Text = "총 $($script:FileDataList.Count)개 소프트웨어 항목 파싱 완료 (전체 버전 순회)."
})

$btnSelectAll.add_Click({
    $script:SelectAllState = -not $script:SelectAllState
    foreach ($item in $listView.Items) { $item.Checked = $script:SelectAllState }
})

$btnStartDownload.add_Click({
    $selectedFiles = @()
    for ($i = 0; $i -lt $listView.Items.Count; $i++) {
        if ($listView.Items[$i].Checked) {
            $currFileName = $listView.Items[$i].Text
            $matchedFile = $script:FileDataList | Where-Object { $_.RealFileName -eq $currFileName } | Select-Object -First 1
            if ($matchedFile) { $selectedFiles += $matchedFile }
        }
    }
    if ($selectedFiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("다운로드할 파일을 선택하세요.", "알림", "OK", "Warning")
        return
    }
    $MaxConcurrent = 3
    $RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxConcurrent)
    $RunspacePool.Open()
    $Jobs = [System.Collections.Generic.List[PSCustomObject]]::new()
    $ActiveProcIds = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $CancelState = [hashtable]::Synchronized(@{ Cancelled = $false })
    $DownloadScriptBlock = {
        param($fileItem, $COOKIE_FILE, $StatusData, $ActiveProcIds, $CancelState)
        if ($CancelState.Cancelled) { $StatusData.Status = "중지됨"; return }
        $pageUrl  = $fileItem.PageUrl
        $uaHeader = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        $eulaQuery = "utf8=%E2%9C%93&tc_form%5Bagreement%5D=I+%22Understand+and+Agree%22&commit=Download"
        $pageHtml = & curl.exe -k -s -b "$COOKIE_FILE" -H "User-Agent: $uaHeader" "$pageUrl" | Out-String
        $downloadEndpointUrl = $null
        if ($pageHtml -match 'action="(/software_downloads/[^"]+)"') {
            $downloadEndpointUrl = "https://support.ruckuswireless.com" + $Matches[1] + "?$eulaQuery"
        } elseif ($pageHtml -match 'action="(/documents_downloads/[^"]+)"') {
            $downloadEndpointUrl = "https://support.ruckuswireless.com" + $Matches[1] + "?$eulaQuery"
        } else {
            $downloadEndpointUrl = ($pageUrl -replace '/software/', '/software_downloads/') + "?$eulaQuery"
        }
        $headRaw = & curl.exe -k -s -I -b "$COOKIE_FILE" -H "User-Agent: $uaHeader" -H "Referer: $pageUrl" "$downloadEndpointUrl" | Out-String
        $finalDirectUrl = $downloadEndpointUrl
        if ($headRaw -match '(?i)Location:\s*([^\r\n]+)') {
            $loc = $Matches[1].Trim()
            $finalDirectUrl = if ($loc -match '^https?://') { $loc } else { "https://support.ruckuswireless.com" + $loc }
        }
        $saveFileName = $fileItem.RealFileName
        $StatusData.FileName = $saveFileName
        $StatusData.Status   = "다운로드 중..."
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
                if ($CancelState.Cancelled) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue; break }
                $line = $process.StandardError.ReadLine()
                if ($line) {
                    $tokens = $line.Trim() -split '\s+'
                    if ($tokens.Count -ge 4 -and $tokens[0] -match '^\d+$') {
                        $pct = [int]$tokens[0]
                        if ($pct -le 100) {
                            $StatusData.Percent = $pct
                            $StatusData.SizeInfo = "$($tokens[3]) / $($tokens[1])"
                        }
                    }
                }
            }
            if ($process.HasExited) { $curlExitCode = $process.ExitCode }
        } catch { $StatusData.Status = "오류" }
        finally {
            if ($process) {
                try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch {}
                try { [void]$ActiveProcIds.Remove($process.Id) } catch {}
                try { $process.Dispose() } catch {}
            }
        }
        if ($CancelState.Cancelled) { $StatusData.Status = "중지됨"; return }
        if (Test-Path $saveFileName) {
            $fileBytes = (Get-Item $saveFileName).Length
            if ($fileBytes -gt 0 -and ($curlExitCode -eq 0 -or $curlExitCode -eq 33 -or $curlExitCode -eq 18 -or $StatusData.Percent -ge 99)) {
                $StatusData.Percent = 100
                $StatusData.Status  = "완료"
                $StatusData.SizeInfo = "{0:N2} MB" -f ($fileBytes / 1MB)
                return
            }
        }
        $StatusData.Status = "실패"
    }

    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = "다운로드 진행 상황"
    $progressForm.Width = 720
    $progressForm.Height = [Math]::Min(900, 100 + ($selectedFiles.Count * 65))
    $progressForm.StartPosition = "CenterParent"
    $progressForm.FormBorderStyle = "FixedDialog"
    $progressForm.MaximizeBox = $false
    $uiElements = @()
    $topPos = 15
    for ($i = 0; $i -lt $selectedFiles.Count; $i++) {
        $fileItem = $selectedFiles[$i]
        $syncHash = [hashtable]::Synchronized(@{
            FileName = $fileItem.RealFileName
            FileSize = $fileItem.FileSize
            SizeInfo = "0 B / " + $fileItem.FileSize
            Percent  = 0
            Status   = "대기 중..."
        })
        $PowerShell = [powershell]::Create()
        $PowerShell.RunspacePool = $RunspacePool
        [void]$PowerShell.AddScript($DownloadScriptBlock).AddArgument($fileItem).AddArgument($COOKIE_FILE).AddArgument($syncHash).AddArgument($ActiveProcIds).AddArgument($CancelState)
        $Jobs.Add([PSCustomObject]@{ Pipe = $PowerShell; Result = $PowerShell.BeginInvoke(); Status = $syncHash })
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Left = 20; $lbl.Top = $topPos; $lbl.Width = 660; $lbl.Height = 18
        $lbl.Font = $fontLabel
        $lbl.Text = "[$($i+1)/$($selectedFiles.Count)] 대기 중: $($fileItem.RealFileName)"
        $progressForm.Controls.Add($lbl)
        $pb = New-Object System.Windows.Forms.ProgressBar
        $pb.Left = 20; $pb.Top = $topPos + 20; $pb.Width = 660; $pb.Height = 20
        $pb.Minimum = 0; $pb.Maximum = 100; $pb.Value = 0
        $progressForm.Controls.Add($pb)
        $uiElements += [PSCustomObject]@{ Label = $lbl; ProgressBar = $pb }
        $topPos += 60
    }
    $script:IsCancelled = $false
    $script:AllDone = $false
    $progressForm.add_FormClosing({
        if (-not $script:AllDone) {
            $script:IsCancelled = $true
            $CancelState.Cancelled = $true
            foreach ($procId in @($ActiveProcIds)) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
        }
    })
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.add_Tick({
        $finishedCount = 0
        for ($i = 0; $i -lt $Jobs.Count; $i++) {
            $st = $Jobs[$i].Status
            $ui = $uiElements[$i]
            $ui.ProgressBar.Value = [math]::Min(100, [math]::Max(0, $st.Percent))
            $ui.Label.Text = "[$($i+1)/$($Jobs.Count)] [$($st.Status)] [$($st.SizeInfo)] $($st.FileName)"
            if ($Jobs[$i].Result.IsCompleted) { $finishedCount++ }
        }
        if ($finishedCount -eq $Jobs.Count) {
            $script:AllDone = $true
            $timer.Stop()
            $progressForm.Close()
        }
    })
    $timer.Start()
    [void]$progressForm.ShowDialog()
    foreach ($job in $Jobs) {
        try { [void]$job.Pipe.EndInvoke($job.Result) } catch {}
        finally { try { $job.Pipe.Dispose() } catch {} }
    }
    $RunspacePool.Close(); $RunspacePool.Dispose()
    if ($script:IsCancelled) {
        [System.Windows.Forms.MessageBox]::Show("사용자에 의해 다운로드가 중단되었습니다.", "알림", "OK", "Information")
    } else {
        [System.Windows.Forms.MessageBox]::Show("선택한 모든 파일의 다운로드 작업이 완료되었습니다.", "완료", "OK", "Information")
    }
})

$mainForm.add_Shown({
    $statusLabel.Text = "파이썬 및 필수 패키지 환경 검사 중..."
    $mainForm.Refresh()
    $script:PyExePath = Test-PythonEnv
    if (-not $script:PyExePath) {
        [System.Windows.Forms.MessageBox]::Show("Python 환경 구성에 실패했습니다.", "오류", "OK", "Error")
        $mainForm.Close()
        return
    }
    if (Test-CookieValid) {
        $lblSessionStatus.Text = "세션 상태: 유효함"
        $lblSessionStatus.ForeColor = [System.Drawing.Color]::Green
        Load-Products
    } else {
        $lblSessionStatus.Text = "세션 상태: 만료됨/없음"
        $lblSessionStatus.ForeColor = [System.Drawing.Color]::Red
        $statusLabel.Text = "계정 정보를 입력하고 로그인을 진행해주세요."
    }
})

[void]$mainForm.ShowDialog()