#!/usr/bin/env bash
# =================================================================
# Ruckus Unleashed Firmware Auto Downloader for Rocky Linux 8
# - Memory Caching for Parsed File Lists (버전당 1회 파싱)
# - Exact File Name Resolution from Location / Content-Disposition
# - Automatic Model Name Prefixing for version-only .bl7 files
# =================================================================
Version="v2.2.0"

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COOKIE_FILE="${SCRIPT_DIR}/cookies.txt"
PYTHON_SCRIPT="${SCRIPT_DIR}/get_ruckus_cookie.py"
BASE_URL="https://support.ruckuswireless.com"

RUCKUS_USER="${RUCKUS_USER:-}"
RUCKUS_PASS="${RUCKUS_PASS:-}"

echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}   Ruckus Unleashed Firmware Auto Downloader ($Version)  ${NC}"
echo -e "${CYAN}=======================================================${NC}"

# -----------------------------------------------------------------
# [단계 0] Python 환경 및 필수 패키지 점검
# -----------------------------------------------------------------
echo -e "${YELLOW}[0/5] 필수 패키지 및 모듈 설치 상태 확인 중...${NC}"

if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}[!] Python3가 설치되어 있지 않습니다. dnf로 설치합니다...${NC}"
    sudo dnf install -y python3 python3-pip
fi

PY_EXE="$(command -v python3)"

MODULES=("requests:requests" "bs4:beautifulsoup4" "lxml:lxml")

for item in "${MODULES[@]}"; do
    import_name="${item%%:*}"
    pkg_name="${item##*:}"
    
    if ! "$PY_EXE" -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$import_name') else 1)" &>/dev/null; then
        echo -e "${YELLOW}[!] 파이썬 ${pkg_name} (${import_name}) 모듈이 없습니다. 자동 설치를 진행합니다...${NC}"
        "$PY_EXE" -m pip install "$pkg_name" --quiet --user
    fi
done

echo -e "${GREEN}[+] 개발 및 실행 환경 검사 완료.${NC}"
echo "-------------------------------------------------"

# -----------------------------------------------------------------
# [단계 1] 쿠키 확인 및 로그인
# production_ruckus_support 쿠키 존재 + 만료 시간을 기준으로 로그인 성공 여부 확인
# -----------------------------------------------------------------
echo -e "${YELLOW}[1/5] 로그인 세션(cookies.txt) 유효성 검사 중...${NC}"

TARGET_COOKIE_NAME="production_ruckus_support"

check_ruckus_login_cookie() {
    local cookie_path="$1"
    local now_epoch
    local cookie_line
    local exp_epoch
    local expire_text

    if [ ! -f "$cookie_path" ]; then
        return 1
    fi

    now_epoch=$(date +%s)

    cookie_line=$(awk -F'\t' -v name="$TARGET_COOKIE_NAME" '
        NF >= 7 && $6 == name { print; exit }
    ' "$cookie_path")

    if [ -z "$cookie_line" ]; then
        return 1
    fi

    exp_epoch=$(printf '%s\n' "$cookie_line" | awk -F'\t' '{print $5}')

    if ! [[ "$exp_epoch" =~ ^[0-9]+$ ]] || [ "$exp_epoch" -le 0 ]; then
        return 1
    fi

    if [ "$exp_epoch" -le "$now_epoch" ]; then
        return 1
    fi

    expire_text=$(date -d "@$exp_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$exp_epoch")
    CHECKED_COOKIE_EXPIRE_TEXT="$expire_text"
    return 0
}

# 이메일 형식 간단 검사
is_valid_email() {
    local email="$1"
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

# 기존 쿠키가 유효한지 먼저 확인
NEED_LOGIN=false

if [ ! -f "$COOKIE_FILE" ]; then
    echo -e "${YELLOW}[!] 쿠키 파일이 없습니다. 로그인을 진행합니다.${NC}"
    NEED_LOGIN=true
elif check_ruckus_login_cookie "$COOKIE_FILE"; then
	#쿠키 만료일 확인시 아래 주서 제거후 교체
    #echo -e "${GREEN}[+] '${TARGET_COOKIE_NAME}' 쿠키가 유효합니다. (만료: ${CHECKED_COOKIE_EXPIRE_TEXT})${NC}"
	#쿠키 만료일 확인 불필요시 아래 주서 제거후 교체
	echo -e "${GREEN}[+] '${TARGET_COOKIE_NAME}' 쿠키가 유효합니다. ${NC}"
else
    echo -e "${YELLOW}[!] '${TARGET_COOKIE_NAME}' 인증 쿠키가 없거나 유효하지 않습니다. 재로그인을 진행합니다.${NC}"
    NEED_LOGIN=true
    rm -f "$COOKIE_FILE"
fi

if [ "$NEED_LOGIN" = true ]; then
    while true; do
        RUCKUS_USER=$(printf '%s' "$RUCKUS_USER" | xargs)
        RUCKUS_PASS=$(printf '%s' "$RUCKUS_PASS" | xargs)

        if [ -z "$RUCKUS_USER" ]; then
            echo -e "${CYAN}Ruckus 이메일 계정을 입력하세요:${NC}"
            read -rp " > " RUCKUS_USER
            RUCKUS_USER=$(printf '%s' "$RUCKUS_USER" | xargs)
        fi

        if ! is_valid_email "$RUCKUS_USER"; then
            echo -e "${RED}[-] 올바른 이메일 형식이 아닙니다. (예: user@example.com)${NC}"
            RUCKUS_USER=""
            RUCKUS_PASS=""
            continue
        fi

        if [ -z "$RUCKUS_PASS" ]; then
            echo -e "${CYAN}Ruckus 비밀번호를 입력하세요:${NC}"
            read -rsp " > " RUCKUS_PASS
            echo ""
        fi

        echo ""
        echo -e "${YELLOW}[*] 파이썬 로그인 스크립트 실행 중...${NC}"

        if "$PY_EXE" -u "$PYTHON_SCRIPT" -u "$RUCKUS_USER" -p "$RUCKUS_PASS" -o "$COOKIE_FILE"; then
            PY_EXIT_CODE=0
        else
            PY_EXIT_CODE=$?
        fi
		
		# Python 로그인 스크립트 자체 실행 실패
        if [ "$PY_EXIT_CODE" -ne 0 ]; then
            echo ""
            echo -e "${RED}=================================================${NC}"
            echo -e "${RED}[-] 로그인에 실패했습니다. 다시 시도하세요.${NC}"
            echo -e "${YELLOW}[!] 로그인 스크립트 실행에 실패했습니다.${NC}"
            echo -e "${RED}=================================================${NC}"
            rm -f "$COOKIE_FILE"
            RUCKUS_USER=""
            RUCKUS_PASS=""
            continue
        fi
		
        # cookies.txt 생성 여부
        if [ ! -f "$COOKIE_FILE" ]; then
            echo ""
            echo -e "${RED}=================================================${NC}"
            echo -e "${RED}[-] 로그인에 실패했습니다. 다시 시도하세요.${NC}"
            echo -e "${YELLOW}[!] cookies.txt 파일이 생성되지 않았습니다.${NC}"
            echo -e "${RED}=================================================${NC}"
            RUCKUS_USER=""
            RUCKUS_PASS=""
            continue
        fi

        # 실제 로그인 성공 여부는 production_ruckus_support 인증 쿠키로 최종 판단
        if ! check_ruckus_login_cookie "$COOKIE_FILE"; then
            echo ""
            echo -e "${RED}=================================================${NC}"
            echo -e "${RED}[-] 로그인에 실패했습니다. 다시 시도하세요.${NC}"
            echo -e "${YELLOW}[!] '${TARGET_COOKIE_NAME}' 인증 쿠키가 생성되지 않았거나 유효하지 않습니다.${NC}"
            echo -e "${RED}=================================================${NC}"
            rm -f "$COOKIE_FILE"
            RUCKUS_USER=""
            RUCKUS_PASS=""
            continue
        fi

		#쿠키 만료일 확인시 아래 주석 제거후 교체
        #echo -e "${GREEN}[+] 로그인 성공! 인증 쿠키 확인 완료. (만료: ${CHECKED_COOKIE_EXPIRE_TEXT})${NC}"
		#쿠키 만료일 확인 불필요시 아래 주서 제거후 교체
		echo -e "${GREEN}[+] 로그인 성공! 인증 쿠키 확인 완료. ${NC}"
        break
    done
else
    echo -e "${GREEN}[+] 기존 cookies.txt 세션이 유효합니다.${NC}"
fi

if [ -f "$COOKIE_FILE" ]; then
    sed -i '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$COOKIE_FILE"
fi

# -----------------------------------------------------------------
# [단계 2] 동적 버전 목록 파싱 (200.x 버전 필터링)
# -----------------------------------------------------------------
echo -e "\n${YELLOW}[2/5] Unleashed 소프트웨어 동적 버전 검색 중...${NC}"

temp_py_ver="${SCRIPT_DIR}/temp_get_unleashed_versions.py"
cat << 'EOF' > "$temp_py_ver"
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
EOF

availableVersions=$("$PY_EXE" "$temp_py_ver" "$COOKIE_FILE" "$BASE_URL")
rm -f "$temp_py_ver"

if [ -z "$availableVersions" ]; then
    echo -e "${RED}[-] 200.x 버전을 찾지 못했거나 동적 목록을 불러오지 못했습니다.${NC}"
    exit 1
fi

# -----------------------------------------------------------------
# 메인 루프 (버전 선택 → 파일 목록 캐싱 → 파일 선택/다운로드)
# -----------------------------------------------------------------
while true; do
    # -----------------------------------------------------------------
    # [단계 3] 릴리스 버전 선택
    # -----------------------------------------------------------------
    echo -e "\n${YELLOW}[3/5] 다운로드할 Unleashed 버전을 선택하세요:${NC}"
    
    vIdx=1
    while IFS= read -r ver; do
        printf " %2d) Unleashed %s\n" "$vIdx" "$ver"
        vIdx=$((vIdx + 1))
    done <<< "$availableVersions"
    echo "  0) 종료"
    echo ""

    read -rp "버전 선택 번호: " verChoice

    if [ -z "$verChoice" ]; then
        echo -e "${RED}[-] 다시 입력해주세요.${NC}"
        continue
    fi
    if [ "$verChoice" = "0" ]; then exit 0; fi

    if ! [[ "$verChoice" =~ ^[0-9]+$ ]] || [ "$verChoice" -lt 1 ] || [ "$verChoice" -ge "$vIdx" ]; then
        echo -e "${RED}[-] 올바른 번호를 선택해주세요. 다시 입력해주세요.${NC}"
        continue
    fi

    selectedVersion=$(echo "$availableVersions" | sed -n "${verChoice}p")
    echo -e "${CYAN}[*] 선택된 버전 ($selectedVersion)의 다운로드 URL을 수집 중입니다...${NC}"

    temp_py_urls="${SCRIPT_DIR}/temp_get_unleashed_urls.py"
    cat << 'EOF' > "$temp_py_urls"
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
EOF

    extractedUrls=$("$PY_EXE" "$temp_py_urls" "$COOKIE_FILE" "$BASE_URL" "$selectedVersion")
    rm -f "$temp_py_urls"

    if [ -z "$extractedUrls" ]; then
        echo -e "${RED}[-] 해당 버전에서 다운로드할 수 있는 소프트웨어를 찾지 못했습니다.${NC}"
        continue
    fi

    # -----------------------------------------------------------------
    # [단계 4] 세부 항목 분석 및 파싱 결과 메모리 캐싱
    # -----------------------------------------------------------------
    echo -e "\n${YELLOW}[4/5] 각 세부 항목의 파일 이름 및 용량 분석 중...${NC}"

    temp_py_details="${SCRIPT_DIR}/temp_get_unleashed_details.py"
    cat << 'EOF' > "$temp_py_details"
import sys, requests, urllib3
from bs4 import BeautifulSoup
urllib3.disable_warnings()

cookie_file = sys.argv[1]
urls = sys.argv[2:]

session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})

with open(cookie_file, 'r', encoding='utf-8') as f:
    for line in f:
        if line.strip() and (not line.startswith('#') or line.startswith('#HttpOnly_')):
            p = line.strip().split('\t')
            if len(p) >= 7:
                session.cookies.set(p[5], p[6], domain=p[0].lstrip('.'))

f_counter = 1
for page_url in urls:
    try:
        dr = session.get(page_url, verify=False, timeout=15)
        soup = BeautifulSoup(dr.text, 'html.parser')
        
        sw_title = "N/A"
        if soup.title:
            sw_title = soup.title.text.split('|')[0].strip()
            
        real_file_name = ""
        dt_fn = soup.find(lambda tag: tag.name == 'dt' and 'File Name:' in tag.text)
        if dt_fn and dt_fn.find_next_sibling('dd'):
            a_tag = dt_fn.find_next_sibling('dd').find('a')
            if a_tag:
                real_file_name = a_tag.text.strip()
            else:
                real_file_name = dt_fn.find_next_sibling('dd').text.strip()
        if not real_file_name:
            real_file_name = page_url.split('/')[-1]
            
        file_size = "N/A"
        dt_fs = soup.find(lambda tag: tag.name == 'dt' and 'File Size:' in tag.text)
        if dt_fs and dt_fs.find_next_sibling('dd'):
            file_size = dt_fs.find_next_sibling('dd').text.strip()

        print(f"{f_counter}\t{page_url}\t{real_file_name}\t{file_size}\t{sw_title}")
        f_counter += 1
    except: pass
EOF

    # URL 인자 전달 후 캐시된 파일 목록 생성 (버전당 1회)
    readarray -t url_array <<< "$extractedUrls"
    cached_file_list=$("$PY_EXE" "$temp_py_details" "$COOKIE_FILE" "${url_array[@]}")
    rm -f "$temp_py_details"

    if [ -z "$cached_file_list" ]; then
        echo -e "${RED}[-] 세부 항목을 분석하지 못했습니다.${NC}"
        continue
    fi

    # -----------------------------------------------------------------
    # 파일 선택 루프 (캐시된 목록 재사용)
    # -----------------------------------------------------------------
    while true; do
        echo -e "\n${GRAY}----------------------------------------------------------------------------------------------------${NC}"
        printf "${CYAN}%-6s | %-45s | %-15s${NC}\n" "번호" "파일 이름 (File Name)" "용량 (Size)"
        echo -e "${GRAY}----------------------------------------------------------------------------------------------------${NC}"

        file_count=0
        while IFS=$'\t' read -r findex fpage freal fsize ftitle; do
            printf "%4s) | %-45s | %-15s\n" "$findex" "$freal" "$fsize"
            echo -e "     └─ ${GRAY}${ftitle}${NC}\n"
            file_count=$((file_count + 1))
        done <<< "$cached_file_list"

        echo -e "${GRAY}----------------------------------------------------------------------------------------------------${NC}"
        echo "  a) 전체 파일 모두 선택 (${file_count}개)"
        echo "  b) 이전 메뉴로 돌아가기 (버전 재선택)"
        echo "  0) 종료"
        echo -e "${GRAY}----------------------------------------------------------------------------------------------------${NC}"

        read -rp "다운로드할 파일 번호 선택 (예: 1, 3 또는 1-5): " fileChoice

        if [ -z "$fileChoice" ]; then
            echo -e "${RED}[-] 번호를 입력해주세요. 다시 입력해주세요.${NC}"
            continue
        fi
        if [ "$fileChoice" = "0" ]; then exit 0; fi
        if [ "$fileChoice" = "b" ] || [ "$fileChoice" = "B" ]; then
            break
        fi

        selected_lines=""
        if [ "$fileChoice" = "a" ] || [ "$fileChoice" = "A" ]; then
            selected_lines="$cached_file_list"
        else
            selected_indices=()
            IFS=' ' read -r -a tokens <<< "$(echo "$fileChoice" | tr ',' ' ')"
            for token in "${tokens[@]}"; do
                if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    start="${BASH_REMATCH[1]}"
                    end="${BASH_REMATCH[2]}"
                    for ((n=start; n<=end; n++)); do selected_indices+=("$n"); done
                elif [[ "$token" =~ ^[0-9]+$ ]]; then
                    selected_indices+=("$token")
                fi
            done

            sorted_indices=$(printf "%s\n" "${selected_indices[@]}" | sort -nu)

            for num in $sorted_indices; do
                matched=$(echo "$cached_file_list" | awk -F'\t' -v n="$num" '$1 == n {print $0}')
                if [ -n "$matched" ]; then
                    selected_lines="${selected_lines}${matched}"$'\n'
                fi
            done
            selected_lines="$(echo "$selected_lines" | sed '/^$/d')"
        fi

        if [ -z "$selected_lines" ]; then
            echo -e "${RED}[-] 선택된 파일이 없습니다.${NC}"
            continue
        fi

        # -----------------------------------------------------------------
        # [단계 5] 다운로드 진행 (Location / Content-Disposition 기반 파일명 확정)
        # -----------------------------------------------------------------
        selected_count=$(echo "$selected_lines" | wc -l)
        echo -e "\n${YELLOW}[5/5] 순차적 다운로드 실행 중 (총 ${selected_count}개 파일)...${NC}"

        while IFS=$'\t' read -r findex fpage freal fsize ftitle; do
            pageUrl="$(echo "$fpage" | xargs)"
            uaHeader="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            eulaQuery='utf8=%E2%9C%93&tc_form%5Bagreement%5D=I+%22Understand+and+Agree%22&commit=Download'

            echo -e "\n${CYAN}[*] 다운로드 페이지 확인: ${pageUrl}${NC}"

            # ---------------------------------------------------------
            # 1. 원본 페이지에서 실제 EULA 제출 endpoint 추출
            # ---------------------------------------------------------
            pageHtml=$(curl -k -s -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                -H "User-Agent: $uaHeader" "$pageUrl")

            if [ -z "$pageHtml" ]; then
                echo -e "${RED}  [-] 다운로드 페이지를 가져오지 못했습니다.${NC}"
                continue
            fi

            downloadAction=$(printf '%s' "$pageHtml" | \
                grep -oE 'action="(/(software|documents)_downloads/[^"]+)"' | \
                head -n 1 | sed -E 's/^action="([^"]+)"$/\1/')

            if [ -n "$downloadAction" ]; then
                downloadEndpointUrl="https://support.ruckuswireless.com${downloadAction}?${eulaQuery}"
            else
                downloadEndpointUrl=$(echo "$pageUrl" | \
                    sed 's|/software/|/software_downloads/|g; s|/documents/|/documents_downloads/|g')
                downloadEndpointUrl="${downloadEndpointUrl}?${eulaQuery}"
            fi

            echo -e "${YELLOW}  [+] 약관 동의 제출 URL: ${downloadEndpointUrl}${NC}"

            # ---------------------------------------------------------
            # 2. 약관 동의 제출 후 Location 헤더에서 최종 direct URL 추출
            # ---------------------------------------------------------
            responseHeaders=$(mktemp)
            responseBody=$(mktemp)

            curl -k -s -D "$responseHeaders" -o "$responseBody" \
                -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                -H "User-Agent: $uaHeader" \
                -H "Referer: $pageUrl" \
                "$downloadEndpointUrl"

            finalLocation=$(grep -i '^Location:' "$responseHeaders" | tail -n 1 | \
                sed -E 's/^[Ll]ocation:[[:space:]]*//' | tr -d '\r')

            if [ -n "$finalLocation" ]; then
                if [[ "$finalLocation" =~ ^https?:// ]]; then
                    finalDirectUrl="$finalLocation"
                else
                    finalDirectUrl="https://support.ruckuswireless.com${finalLocation}"
                fi
            else
                finalDirectUrl="$downloadEndpointUrl"
            fi

            rm -f "$responseHeaders" "$responseBody"

            echo -e "${YELLOW}  [+] 최종 다운로드 URL 확보 완료.${NC}"

            # ---------------------------------------------------------
            # 3. 파일명 결정 (Windows .ps1과 동일 로직)
            #    - 캐시된 RealFileName을 기본으로 사용
            #    - Location / Content-Disposition 에서 원본 파일명 추출
            #    - 말줄임표(...) 또는 빈 값인 경우 추출한 원본 파일명으로 교체
            # ---------------------------------------------------------
            saveFileName="$freal"
            extractedFileName=""

            headRaw=$(curl -k -s -I -L -b "$COOKIE_FILE" \
                -H "User-Agent: $uaHeader" \
                -H "Referer: $pageUrl" "$finalDirectUrl" 2>/dev/null || true)

            # Content-Disposition: filename="..."
            cdLine=$(echo "$headRaw" | grep -i "Content-Disposition:.*filename=" | tail -n 1 || true)
            if [ -n "$cdLine" ]; then
                extractedFileName=$(echo "$cdLine" | sed -E 's/.*filename="?([^";\r\n]+)"?.*/\1/' | tr -d '\r' | xargs)
                if [ "$extractedFileName" = "login" ]; then
                    extractedFileName=""
                fi
            fi

            # Location URL 또는 finalDirectUrl 경로에서 파일명 추출
            if [ -z "$extractedFileName" ] && [ -n "$finalDirectUrl" ]; then
                cleanUri=$(echo "$finalDirectUrl" | cut -d'?' -f1)
                urlFile=$(basename "$cleanUri")
                if [[ "$urlFile" =~ ^[0-9]+-(.+)$ ]]; then
                    extractedFileName="${BASH_REMATCH[1]}"
                elif [ -n "$urlFile" ] && [ "$urlFile" != "/" ]; then
                    extractedFileName="$urlFile"
                fi
            fi

            # 말줄임표가 포함되어 있거나 비어있는 경우 → 추출한 원본 파일명 적용
            if [[ "$saveFileName" =~ \.{3,}$ ]] || [ -z "$saveFileName" ]; then
                if [ -n "$extractedFileName" ]; then
                    saveFileName="$extractedFileName"
                fi
            fi

            # .bl7 모델명 보정 (URL Slug 패턴에서 AP 모델 추출: for-r510, for-t750 등)
            if [[ "$saveFileName" =~ \.bl7$ ]]; then
                if ! [[ "$saveFileName" =~ (R[0-9]+|H[0-9]+|T[0-9]+|M[0-9]+|ZF[0-9]+) ]]; then
                    urlSlug="${pageUrl##*/}"
                    if [[ "$urlSlug" =~ for-(r[0-9]+|h[0-9]+|t[0-9]+|m[0-9]+|zf[0-9]+) ]]; then
                        modelName=$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
                        saveFileName="${modelName}_${saveFileName}"
                        echo -e "${YELLOW}  [!] 모델명 보정 적용: ${saveFileName}${NC}"
                    fi
                fi
            fi

            if [ -z "$saveFileName" ] || [ "$saveFileName" = "login" ]; then
                saveFileName="$freal"
            fi

            echo -e "${YELLOW}  [+] 대상 파일명 확정: ${saveFileName}${NC}"

            # ---------------------------------------------------------
            # 4. 최종 direct URL 다운로드 (이어받기 지원)
            # ---------------------------------------------------------
            curlExitCode=0

            if [ -f "$saveFileName" ] && [ -s "$saveFileName" ]; then
                echo -e "${YELLOW}  [!] 기존 파일 발견 -> '${saveFileName}' 이어서 다운로드를 시도합니다.${NC}"

                curl -k -L -C - --retry 5 --retry-delay 3 --retry-max-time 600 \
                    -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                    -H "User-Agent: $uaHeader" \
                    -H "Referer: $pageUrl" \
                    -o "$saveFileName" "$finalDirectUrl"
                curlExitCode=$?

                if [ "$curlExitCode" -eq 33 ]; then
                    echo -e "${YELLOW}  [!] 서버가 이어받기(Byte Range)를 지원하지 않습니다.${NC}"
                    echo -e "${YELLOW}  [*] 기존 부분 파일을 삭제하고 처음부터 다시 다운로드합니다.${NC}"
                    rm -f "$saveFileName"

                    curl -k -L --retry 5 --retry-delay 3 --retry-max-time 600 \
                        -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                        -H "User-Agent: $uaHeader" \
                        -H "Referer: $pageUrl" \
                        -o "$saveFileName" "$finalDirectUrl"
                    curlExitCode=$?
                fi
            else
                curl -k -L --retry 5 --retry-delay 3 --retry-max-time 600 \
                    -b "$COOKIE_FILE" -c "$COOKIE_FILE" \
                    -H "User-Agent: $uaHeader" \
                    -H "Referer: $pageUrl" \
                    -o "$saveFileName" "$finalDirectUrl"
                curlExitCode=$?
            fi

            if [ "$curlExitCode" -eq 0 ] && [ -f "$saveFileName" ]; then
                fileBytes=$(stat -c%s "$saveFileName" 2>/dev/null || echo 0)
                if [ "$fileBytes" -lt 50000 ]; then
                    headContent=$(head -c 512 "$saveFileName" 2>/dev/null || true)
                    if echo "$headContent" | grep -qiE '(<html|login|doctype)'; then
                        rm -f "$saveFileName"
                        echo -e "${RED}  [-] 다운로드 실패 (로그인/HTML 페이지가 반환됨)${NC}"
                        continue
                    fi
                fi
                echo -e "${GREEN}  [+] 다운로드 완료: ${saveFileName} ($(numfmt --to=iec-i --suffix=B "$fileBytes" 2>/dev/null || echo "${fileBytes} bytes"))${NC}"
            else
                echo -e "${RED}  [-] 다운로드 실패 (curl 종료 코드: ${curlExitCode})${NC}"
            fi
        done <<< "$selected_lines"

        echo -e "\n${GREEN}[+] 다운로드 작업이 완료되었습니다.${NC}"
        while true; do
            read -rp "다른 파일도 다운로드하시겠습니까? (y/n): " continueChoice
            if [[ "$continueChoice" = "y" || "$continueChoice" = "Y" ]]; then
                # 같은 버전의 캐시된 파일 목록으로 돌아감 (재파싱 없음)
                break
            elif [[ "$continueChoice" = "n" || "$continueChoice" = "N" ]]; then
                exit 0
            else
                echo -e "${RED}[-] 다시 입력해주세요. (y/n)${NC}"
            fi
        done
        continue
    done
done

echo -e "${GREEN}[+] 프로그램을 종료합니다.${NC}"