#!/usr/bin/env bash
# ============================================================
# Ruckus Universal Firmware Auto Downloader - Linux Updater
# GitHub에서 최신 버전을 확인하고 자동 업데이트 후 실행
# ============================================================


SCRIPT_NAME="auto_ruckus_downloader_linux.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}"
BACKUP_FILE="${SCRIPT_DIR}/${SCRIPT_NAME}.bak"

TEMP_DIR="${TMPDIR:-/tmp}/RuckusUniversalUpdate"
TEMP_FILE="${TEMP_DIR}/${SCRIPT_NAME}"

GITHUB_API_URL="https://api.github.com/repos/cockcut/ruckus_fw_autodownloader_enhanced/git/ref/heads/main"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/cockcut/ruckus_fw_autodownloader_enhanced"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "============================================================"
echo "[업데이트 확인 중]"
echo "============================================================"
echo ""
echo -e "${CYAN}[*] GitHub 최신 커밋 정보를 확인합니다...${NC}"

COMMIT_SHA=""

# GitHub API로 최신 커밋 SHA 가져오기
COMMIT_SHA=$(curl -sL --connect-timeout 10 --max-time 20 \
    -H "User-Agent: RuckusUpdater" \
    "$GITHUB_API_URL" 2>/dev/null | \
    grep -o '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]*"' | head -1 | \
    sed -E 's/.*"([a-f0-9]+)".*/\1/')

if [ -z "$COMMIT_SHA" ]; then
    echo -e "${YELLOW}[!] 커밋 SHA를 가져오지 못했습니다. 기존 스크립트를 실행합니다.${NC}"
    goto_run=1
else
    echo -e "${GREEN}[*] 최신 커밋 확인 완료.${NC}"
    echo -e "${CYAN}[*] 최신 커밋 SHA:${NC}"
    echo "    $COMMIT_SHA"

    UPDATE_URL="${GITHUB_RAW_BASE}/${COMMIT_SHA}/linux/${SCRIPT_NAME}"

    echo ""
    echo -e "${CYAN}[*] 최신 SH 파일 다운로드 URL:${NC}"
    echo "    $UPDATE_URL"

    # 임시 폴더 생성
    mkdir -p "$TEMP_DIR" 2>/dev/null || true

    if [ ! -d "$TEMP_DIR" ]; then
        echo -e "${YELLOW}[!] 임시 폴더 생성 실패. 기존 스크립트를 실행합니다.${NC}"
        goto_run=1
    else
        # 기존 임시 파일 삭제
        rm -f "$TEMP_FILE" 2>/dev/null || true

        echo ""
        echo -e "${CYAN}[*] GitHub 최신 SH 파일을 다운로드합니다...${NC}"

        if ! curl -L --fail --silent --show-error \
            --connect-timeout 10 --max-time 60 \
            -o "$TEMP_FILE" "$UPDATE_URL"; then
            echo -e "${YELLOW}[!] 다운로드 실패. 기존 스크립트를 실행합니다.${NC}"
            goto_run=1
        elif [ ! -f "$TEMP_FILE" ] || [ ! -s "$TEMP_FILE" ]; then
            echo -e "${YELLOW}[!] 다운로드된 파일이 비어 있습니다. 기존 스크립트를 실행합니다.${NC}"
            goto_run=1
        else
            # 로컬 파일이 없는 경우 새로 설치
            if [ ! -f "$LOCAL_FILE" ]; then
                echo ""
                echo -e "${GREEN}[+] 로컬 SH 파일이 없습니다.${NC}"
                echo -e "${CYAN}[*] 최신 파일을 새로 설치합니다...${NC}"

                cp -f "$TEMP_FILE" "$LOCAL_FILE"
                chmod +x "$LOCAL_FILE"

                LOCAL_HASH=$(sha256sum "$LOCAL_FILE" 2>/dev/null | awk '{print $1}')
                REMOTE_HASH=$(sha256sum "$TEMP_FILE" 2>/dev/null | awk '{print $1}')

                if [ -n "$LOCAL_HASH" ] && [ -n "$REMOTE_HASH" ] && [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
                    echo ""
                    echo "============================================================"
                    echo -e "${GREEN}[+] 최신 SH 파일 설치가 완료되었습니다.${NC}"
                    echo "============================================================"
                else
                    echo -e "${YELLOW}[!] 설치 검증 실패. 기존 스크립트를 실행합니다.${NC}"
                fi
                goto_run=1
            else
                # SHA-256 비교
                echo ""
                echo -e "${CYAN}[*] 로컬 파일과 최신 GitHub 파일을 비교합니다...${NC}"

                LOCAL_HASH=$(sha256sum "$LOCAL_FILE" 2>/dev/null | awk '{print $1}')
                REMOTE_HASH=$(sha256sum "$TEMP_FILE" 2>/dev/null | awk '{print $1}')

                if [ -z "$LOCAL_HASH" ] || [ -z "$REMOTE_HASH" ]; then
                    echo -e "${YELLOW}[!] 해시 계산 실패. 기존 스크립트를 실행합니다.${NC}"
                    goto_run=1
                elif [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
                    echo -e "${GREEN}[+] 현재 최신 버전입니다.${NC}"
                    goto_run=1
                else
                    # 업데이트 진행
                    echo ""
                    echo "============================================================"
                    echo -e "${GREEN}[+] 새로운 파일 변경 사항을 발견했습니다.${NC}"
                    echo "============================================================"
                    echo ""

                    # 기존 백업 삭제
                    if [ -f "$BACKUP_FILE" ]; then
                        echo -e "${CYAN}[*] 기존 백업 파일을 삭제합니다...${NC}"
                        rm -f "$BACKUP_FILE" 2>/dev/null || true
                    fi

                    # 현재 파일 백업
                    echo -e "${CYAN}[*] 현재 SH 파일을 백업합니다...${NC}"
                    if ! cp -f "$LOCAL_FILE" "$BACKUP_FILE"; then
                        echo -e "${RED}[!] 현재 SH 파일 백업에 실패했습니다.${NC}"
                        goto_run=1
                    elif [ ! -f "$BACKUP_FILE" ]; then
                        echo -e "${RED}[!] 백업 파일이 생성되지 않았습니다.${NC}"
                        goto_run=1
                    else
                        echo -e "${GREEN}[+] 기존 파일 백업 완료.${NC}"

                        # 최신 파일 적용
                        echo -e "${CYAN}[*] 최신 SH 파일을 적용합니다...${NC}"
                        if ! cp -f "$TEMP_FILE" "$LOCAL_FILE"; then
                            echo -e "${RED}[!] 최신 파일 적용에 실패했습니다.${NC}"
                            echo -e "${CYAN}[*] 기존 백업 파일로 복구합니다...${NC}"
                            cp -f "$BACKUP_FILE" "$LOCAL_FILE" 2>/dev/null || true
                            goto_run=1
                        else
                            chmod +x "$LOCAL_FILE"

                            # 업데이트 결과 검증
                            echo -e "${CYAN}[*] 업데이트 결과를 검증합니다...${NC}"
                            UPDATED_HASH=$(sha256sum "$LOCAL_FILE" 2>/dev/null | awk '{print $1}')

                            if [ -z "$UPDATED_HASH" ] || [ "$UPDATED_HASH" != "$REMOTE_HASH" ]; then
                                echo -e "${RED}[!] 업데이트 파일 검증에 실패했습니다.${NC}"
                                echo -e "${CYAN}[*] 기존 백업 파일로 복구합니다...${NC}"
                                cp -f "$BACKUP_FILE" "$LOCAL_FILE" 2>/dev/null || true
                                goto_run=1
                            else
                                echo ""
                                echo "============================================================"
                                echo -e "${GREEN}[+] 업데이트가 완료되었습니다!${NC}"
                                echo "============================================================"
                                goto_run=1
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
fi

# 임시 파일 정리
rm -f "$TEMP_FILE" 2>/dev/null || true
rmdir "$TEMP_DIR" 2>/dev/null || true

# ============================================================
# SH 실행
# ============================================================
echo ""
echo "============================================================"
echo "[Ruckus Universal Firmware Downloader 실행]"
echo "============================================================"
echo ""

if [ ! -f "$LOCAL_FILE" ]; then
    echo -e "${RED}[오류] 실행할 SH 파일이 없습니다.${NC}"
    echo ""
    exit 1
fi

chmod +x "$LOCAL_FILE" 2>/dev/null || true
exec bash "$LOCAL_FILE"

