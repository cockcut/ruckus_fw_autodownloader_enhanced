#!/usr/bin/env bash
# =================================================================
# Ruckus Firmware Auto Downloader for Rocky Linux 8
# - Universal Ruckus Product Line Support (APs, ICX, vSZ, Unleashed)
# - Automatic Model Name Prefixing for version-only .bl7 files
# - Memory caching of file list (parse once per version)
# - Filename extraction from Location / Content-Disposition
# =================================================================
Version="v1.2.0"

# -----------------------------------------------------------------
# GitHub 자동 업데이트 확인 및 실행
# -----------------------------------------------------------------
AUTO_UPDATE_CHECK() {
    # .git 디렉토리가 존재하는지 (git 클론 환경인지) 확인
    if [ -d "${SCRIPT_DIR}/.git" ] && command -v git &> /dev/null; then
        echo -e "${YELLOW}[*] GitHub 업데이트 확인 중...${NC}"
        
        # 원격 저장소의 최신 커밋 정보 갱신 (오류 출력 숨김)
        git -C "$SCRIPT_DIR" fetch origin main &> /dev/null || true

        # 현재 로컬 Head와 원격 Head 비교
        LOCAL_HASH=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "")
        REMOTE_HASH=$(git -C "$SCRIPT_DIR" rev-parse origin/main 2>/dev/null || echo "")

        if [ -n "$LOCAL_HASH" ] && [ -n "$REMOTE_HASH" ] && [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
            echo -e "${CYAN}[!] 새로운 업데이트가 존재합니다. 자동 업데이트를 진행합니다...${NC}"
            
            # 원격 코드 최신화
            if git -C "$SCRIPT_DIR" pull origin main; then
                echo -e "${GREEN}[+] 업데이트 완료! 스크립트를 재실행합니다.${NC}"
                echo "-------------------------------------------------"
                # 업데이트된 새 스크립트로 전달받은 인자($@)를 유지하여 재실행
                exec "$0" "$@"
            else
                echo -e "${RED}[-] git pull 실패. 기존 버전으로 계속 실행합니다.${NC}"
            fi
        else
            echo -e "${GREEN}[+] 최신 버전을 사용 중입니다.${NC}"
        fi
        echo "-------------------------------------------------"
    fi
}

# 업데이트 함수 호출
AUTO_UPDATE_CHECK

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
echo -e "${CYAN}   Ruckus Universal Firmware Auto Downloader ($Version)  ${NC}"
echo -e "${CYAN}=======================================================${NC}"

# -----------------------------------------------------------------
# [단계 0] Python3 환경 및 필수 패키지 점검
# -----------------------------------------------------------------
echo -e "${YELLOW}[0/5] 필수 패키지 및 모듈 설치 상태 확인 중...${NC}"

if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}[!] Python3가 설치되어 있지 않습니다. dnf로 설치합니다...${NC}"
    sudo dnf install -y python3 python3-pip
fi

PY_EXE="$(command -v python3)"

# 필수 파이썬 모듈 확인 및 pip 설치
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
echo -e "\033[1;33m[1/5] 로그인 세션(cookies.txt) 유효성 검사 중...\033[0m"

TARGET_COOKIE_NAME="production_ruckus_support"

# production_ruckus_support 쿠키가 존재하고 만료되지 않았으면 0,
# 없거나 만료되었으면 1을 반환
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

    # Netscape cookie format:
    # Domain | Flag | Path | Secure | Expiration | Name | Value
    # production_ruckus_support 행을 찾는다.
    cookie_line=$(awk -F'\t' -v name="$TARGET_COOKIE_NAME" '
        NF >= 7 && $6 == name { print; exit }
    ' "$cookie_path")

    if [ -z "$cookie_line" ]; then
        return 1
    fi

    exp_epoch=$(printf '%s\n' "$cookie_line" | awk -F'\t' '{print $5}')

    # 세션 쿠키(0)는 본 스크립트에서는 인증 유효성을 확실하게 판단할 수 없으므로
    # 재로그인하도록 처리한다.
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

# 로그인 필요 시 성공할 때까지 이메일/비밀번호 입력부터 반복
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

        # set -e가 있어도 로그인 프로그램 실패 시 즉시 스크립트가 종료되지 않도록
        # if 문 안에서 실행하고 종료 코드를 직접 처리한다.
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

# 빈 줄 및 일반 주석 제거
# (쿠키 값 자체는 변경하지 않으며 실제 인증 쿠키 행은 유지)
if [ -f "$COOKIE_FILE" ]; then
    sed -i '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$COOKIE_FILE"
fi

# -----------------------------------------------------------------
# 메인 루프 (버전 선택 → 파일 목록 캐싱 → 파일 선택/다운로드)
# -----------------------------------------------------------------
while true; do
    # -----------------------------------------------------------------
    # [단계 2] 제품 카테고리 동적 파싱
    # -----------------------------------------------------------------
    echo -e "\n${YELLOW}[2/5] Ruckus 제품 카테고리 동적 파싱 중...${NC}"

    temp_py_cat="${SCRIPT_DIR}/temp_parse_categories.py"
    cat << 'EOF' > "$temp_py_cat"
import sys, re, requests, urllib3
from bs4 import BeautifulSoup
urllib3.disable_warnings()

cookie_file, base_url = sys.argv[1], sys.argv[2]
session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})

with open(cookie_file, 'r', encoding='utf-8') as f:
    for line in f:
        if not line.startswith('#') and line.strip():
            p = line.strip().split('\t')
            if len(p) >= 7:
                session.cookies.set(p[5], p[6], domain=p[0].lstrip('.'))

try:
    r = session.get(f"{base_url}/software", verify=False, timeout=15)
    soup = BeautifulSoup(r.text, 'html.parser')
    allowed_groups = [
        "RUCKUS Indoor APs", "RUCKUS Outdoor APs",
        "RUCKUS ICX Switches", "Virtual SmartZone (vSZ)", "RUCKUS Unleashed"
    ]
    p_count = 1
    for group in soup.find_all('optgroup'):
        label = group.get('label', '').strip()
        is_normal = label in allowed_groups
        is_eol = (label == "EOL RUCKUS Products")
        if is_normal or is_eol:
            for opt in group.find_all('option'):
                val = opt.get('value', '').strip()
                name = opt.text.strip()
                if is_eol and not re.search(r'(Ruckus|SmartZone|ZoneDirector)', name, re.I):
                    continue
                if name.startswith('zzz'):
                    continue
                print(f"{p_count}\t{label}\t{val}\t{name}")
                p_count += 1
except Exception:
    sys.exit(1)
EOF

    product_raw_list=$("$PY_EXE" "$temp_py_cat" "$COOKIE_FILE" "$BASE_URL")
    rm -f "$temp_py_cat"

    if [ -z "$product_raw_list" ]; then
        echo -e "${RED}[-] 제품 목록을 동적으로 가져오지 못했습니다.${NC}"
        exit 1
    fi

    echo -e "\n${GRAY}----------------------------------------------------------------------------${NC}"
    printf "${CYAN}%-4s | %-24s | %s${NC}\n" "번호" "카테고리 (Group)" "제품명 (Product Name)"
    echo -e "${GRAY}----------------------------------------------------------------------------${NC}"
    while IFS=$'\t' read -r idx group pid pname; do
        printf "%4s) | %-24s | %s\n" "$idx" "$group" "$pname"
    done <<< "$product_raw_list"
    echo -e "${GRAY}----------------------------------------------------------------------------${NC}"
    echo " 0) 종료"
    echo ""

    read -rp "대상 제품 선택 번호: " pChoice
    if [ -z "$pChoice" ]; then
        echo -e "${RED}[-] 다시 입력해주세요.${NC}"
        continue
    fi
    if [ "$pChoice" = "0" ]; then exit 0; fi

    selected_line=$(echo "$product_raw_list" | awk -F'\t' -v ch="$pChoice" '$1 == ch {print $0}')
    if [ -z "$selected_line" ]; then
        echo -e "${RED}[-] 올바른 번호를 선택해주세요. 다시 입력해주세요.${NC}"
        continue
    fi

    sel_group=$(echo "$selected_line" | cut -f2)
    sel_id=$(echo "$selected_line" | cut -f3)
    sel_name=$(echo "$selected_line" | cut -f4)
    echo -e "${GREEN}[+] 선택된 제품: [${sel_group}] ${sel_name} (ID: ${sel_id})${NC}"

    # 모델명 정제 (Windows .ps1의 $cleanProductName과 동일 목적)
    # Ruckus/ZoneFlex/SmartZone 접두어 제거 후 공백을 _ 로 변환
    cleanProductName=$(echo "$sel_name" | \
        sed -E 's/^(Ruckus|ZoneFlex|SmartZone)[[:space:]]+//I' | \
        sed -E 's/[^a-zA-Z0-9_-]/_/g; s/_+/_/g; s/^_|_$//g')

    # [단계 3] 버전 선택 루프
    while true; do
        echo -e "\n${YELLOW}[3/5] 지원 펌웨어 버전 정보 수집 중...${NC}"

        temp_py_ver="${SCRIPT_DIR}/temp_parse_versions.py"
        cat << 'EOF' > "$temp_py_ver"
import sys, requests, urllib3
from bs4 import BeautifulSoup
urllib3.disable_warnings()

cookie_file, base_url, pid = sys.argv[1], sys.argv[2], sys.argv[3]
session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
with open(cookie_file, 'r', encoding='utf-8') as f:
    for line in f:
        if not line.startswith('#') and line.strip():
            p = line.strip().split('\t')
            if len(p) >= 7:
                session.cookies.set(p[5], p[6], domain=p[0].lstrip('.'))
try:
    url = f"{base_url}/products/{pid}/filtered_products?type=software"
    r = session.get(url, verify=False, timeout=15)
    soup = BeautifulSoup(r.text, 'html.parser')
    ver_div = soup.find('div', id='product_software_version')
    if ver_div:
        v_count = 1
        for opt in ver_div.find_all('option'):
            val = opt.get('value', '').strip()
            txt = opt.text.strip()
            if val and "Choose A Version" not in txt:
                print(f"{v_count}\t{val}")
                v_count += 1
except Exception:
    pass
EOF

        version_raw_list=$("$PY_EXE" "$temp_py_ver" "$COOKIE_FILE" "$BASE_URL" "$sel_id")
        rm -f "$temp_py_ver"

        selectedVersion=""
        vChoice=""
        NO_VERSION_MENU=false
        if [ -z "$version_raw_list" ]; then
            echo -e "${YELLOW}[!] 지정 영역에서 버전을 찾지 못했습니다. 전체 조회를 진행합니다.${NC}"
            NO_VERSION_MENU=true
        else
            echo -e "${GRAY}----------------------------------------------------------------------------${NC}"
            echo -e "${CYAN} [ 파싱된 버전 목록 ]${NC}"
            echo -e "${GRAY}----------------------------------------------------------------------------${NC}"
            while IFS=$'\t' read -r vidx vval; do
                printf "%3s) Version %s\n" "$vidx" "$vval"
            done <<< "$version_raw_list"
            echo -e "${GRAY}----------------------------------------------------------------------------${NC}"
            echo " a) 모든 버전 선택 (전체 조회)"
            echo " b) 이전 메뉴로 돌아가기 (제품 재선택)"
            echo " 0) 종료"
            echo ""

            read -rp "버전 선택 번호: " vChoice
            if [ -z "$vChoice" ]; then
                echo -e "${RED}[-] 다시 입력해주세요.${NC}"
                continue
            fi
            if [ "$vChoice" = "0" ]; then exit 0; fi
            if [ "$vChoice" = "b" ] || [ "$vChoice" = "B" ]; then
                break
            fi
            if [ "$vChoice" = "a" ] || [ "$vChoice" = "A" ]; then
                selectedVersion=""
            else
                selectedVersion=$(echo "$version_raw_list" | awk -F'\t' -v ch="$vChoice" '$1 == ch {print $2}')
                if [ -z "$selectedVersion" ]; then
                    echo -e "${RED}[-] 잘못된 번호입니다. 다시 입력해주세요.${NC}"
                    continue
                fi
            fi
        fi

        # b를 눌렀을 때 제품 선택으로 돌아가기
        if [ "$vChoice" = "b" ] || [ "$vChoice" = "B" ]; then
            break
        fi

        echo -e "${GREEN}[+] 선택된 버전: ${selectedVersion:-ALL}${NC}"

        # -----------------------------------------------------------------
        # [단계 4] 세부 항목 분석 및 파싱 결과 메모리 캐싱
        # -----------------------------------------------------------------
        echo -e "\n${YELLOW}[4/5] 각 세부 항목의 파일 이름 및 용량 분석 중...${NC}"

        temp_py_files="${SCRIPT_DIR}/temp_parse_files.py"
        cat << 'EOF' > "$temp_py_files"
import sys, re, requests, urllib3
from bs4 import BeautifulSoup
urllib3.disable_warnings()

cookie_file, base_url, pid, version, clean_name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"})
with open(cookie_file, 'r', encoding='utf-8') as f:
    for line in f:
        if not line.startswith('#') and line.strip():
            p = line.strip().split('\t')
            if len(p) >= 7:
                session.cookies.set(p[5], p[6], domain=p[0].lstrip('.'))

v_param = f"?version={version}&type=software" if version else "?type=software"
target_url = f"{base_url}/products/{pid}/filtered_products{v_param}"
try:
    r = session.get(target_url, verify=False, timeout=15)
    matches = re.findall(r'href="(/software/(\d+-[^"]+))"', r.text)
    sub_urls = []
    for m in matches:
        full_u = base_url + m[0]
        if full_u not in sub_urls:
            sub_urls.append(full_u)
    f_counter = 1
    for page_url in sub_urls:
        dr = session.get(page_url, verify=False, timeout=15)
        soup = BeautifulSoup(dr.text, 'html.parser')
        sw_title = soup.title.text.split('|')[0].strip() if soup.title else "N/A"
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

        # Windows .ps1과 동일: 버전만 있는 .bl7 파일에 모델명 접두어 자동 부여
        if clean_name and re.match(r'^\d+[\d\.]+\.bl7$', real_file_name):
            real_file_name = f"{clean_name}_{real_file_name}"

        file_size = "N/A"
        dt_fs = soup.find(lambda tag: tag.name == 'dt' and 'File Size:' in tag.text)
        if dt_fs and dt_fs.find_next_sibling('dd'):
            file_size = dt_fs.find_next_sibling('dd').text.strip()
        print(f"{f_counter}\t{page_url}\t{real_file_name}\t{file_size}\t{sw_title}")
        f_counter += 1
except Exception:
    sys.exit(1)
EOF

        # 캐시된 파일 목록 (버전당 1회만 생성, 이후 FileLoop에서 재사용)
        cached_file_list=$("$PY_EXE" "$temp_py_files" "$COOKIE_FILE" "$BASE_URL" "$sel_id" "$selectedVersion" "$cleanProductName")
        rm -f "$temp_py_files"

        if [ -z "$cached_file_list" ]; then
            echo -e "${RED}[-] 다운로드 가능한 소프트웨어 항목을 찾을 수 없습니다.${NC}"
            continue
        fi

        # -----------------------------------------------------------------
        # 파일 선택 루프 (캐시된 목록 사용)
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
            if [ "$NO_VERSION_MENU" = true ]; then
                echo "  b) 이전 메뉴로 돌아가기 (제품 재선택)"
            else
                echo "  b) 이전 메뉴로 돌아가기 (버전 재선택)"
            fi
            echo "  0) 종료"
            echo -e "${GRAY}----------------------------------------------------------------------------------------------------${NC}"

            read -rp "다운로드할 파일 번호 선택 (예: 1, 3 또는 1-5): " fChoice
            if [ -z "$fChoice" ]; then
                echo -e "${RED}[-] 번호를 입력해주세요. 다시 입력해주세요.${NC}"
                continue
            fi
            if [ "$fChoice" = "0" ]; then exit 0; fi
            if [ "$fChoice" = "b" ] || [ "$fChoice" = "B" ]; then
                # 버전 메뉴가 없었던 경우(EOL 등) → 제품 선택으로 바로 복귀
                # 버전 메뉴가 있었던 경우 → 버전 선택으로 복귀
                if [ "$NO_VERSION_MENU" = true ]; then
                    break 2
                else
                    break
                fi
            fi

            selected_lines=""
            if [ "$fChoice" = "a" ] || [ "$fChoice" = "A" ]; then
                selected_lines="$cached_file_list"
            else
                selected_indices=()
                IFS=' ' read -r -a tokens <<< "$(echo "$fChoice" | tr ',' ' ')"
                for token in "${tokens[@]}"; do
                    if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
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

            selected_count=$(echo "$selected_lines" | wc -l)
            echo -e "\n${YELLOW}[5/5] 순차적 다운로드 실행 중 (총 ${selected_count}개 파일)...${NC}"

            while IFS=$'\t' read -r findex fpage freal fsize ftitle; do
                pageUrl="$fpage"
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

                # action="/software_downloads/..." 또는
                # action="/documents_downloads/..." 추출
                downloadAction=$(printf '%s' "$pageHtml" | \
                    grep -oE 'action="(/(software|documents)_downloads/[^"]+)"' | \
                    head -n 1 | sed -E 's/^action="([^"]+)"$/\1/')

                if [ -n "$downloadAction" ]; then
                    downloadEndpointUrl="https://support.ruckuswireless.com${downloadAction}?${eulaQuery}"
                else
                    # 기존 방식 fallback
                    downloadEndpointUrl=$(echo "$pageUrl" | \
                        sed 's|/software/|/software_downloads/|g; s|/documents/|/documents_downloads/|g')
                    downloadEndpointUrl="${downloadEndpointUrl}?${eulaQuery}"
                fi

                echo -e "${YELLOW}  [+] 약관 동의 제출 URL: ${downloadEndpointUrl}${NC}"

                # ---------------------------------------------------------
                # 2. 약관 동의 제출 후 응답 Location에서 최종 direct URL 추출
                #    - HEAD(-I)만 사용하지 않고 실제 GET 응답 헤더를 받아 처리
                #      일부 endpoint는 HEAD와 GET 동작이 달라지는 문제 방지
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
                    # 서버가 바로 파일/S3 URL을 반환하는 경우를 위해 endpoint를 fallback으로 사용
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

                # HEAD 요청으로 Content-Disposition 및 Location 기반 파일명 추출
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

                # Location URL 또는 finalDirectUrl 경로에서 파일명 추출 (Content-Disposition이 없을 때)
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

                # .bl7 이고 모델명 접두어가 아직 없는 경우 보정 (캐시 단계에서 대부분 처리됨)
                if [[ "$saveFileName" =~ \.bl7$ ]] && [[ ! "$saveFileName" =~ ^"${cleanProductName}" ]]; then
                    if [[ "$saveFileName" =~ ^[0-9]+[0-9\.]*\.bl7$ ]]; then
                        saveFileName="${cleanProductName}_${saveFileName}"
                        echo -e "${YELLOW}  [!] 모델명 보정 적용: ${saveFileName}${NC}"
                    fi
                fi

                if [ -z "$saveFileName" ] || [ "$saveFileName" = "login" ]; then
                    saveFileName="$freal"
                fi

                echo -e "${YELLOW}  [+] 대상 파일명 확정: ${saveFileName}${NC}"

                # ---------------------------------------------------------
                # 4. 최종 direct URL 다운로드
                #    기존 파일이 있으면 resume 시도.
                #    S3/서버가 Range를 지원하지 않아 curl 33 오류가 나면
                #    기존 부분 파일을 삭제하고 처음부터 다시 다운로드.
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
                    # 작은 파일 + HTML/로그인 페이지인 경우 실패로 간주 (Windows .ps1과 동일)
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
                    # 같은 제품/버전의 캐시된 파일 목록으로 돌아감 (재파싱 없음)
                    break
                elif [[ "$continueChoice" = "n" || "$continueChoice" = "N" ]]; then
                    exit 0
                else
                    echo -e "${RED}[-] 다시 입력해주세요. (y/n)${NC}"
                fi
            done
            continue
        done

        # [4/5]에서 b -> 현재 제품의 [3/5] 버전 목록으로 돌아감
        continue
    done
done