#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Ruckus Cookie Exporter for Windows (v1.0.1)
#

import sys
import argparse
import requests
import urllib3
from bs4 import BeautifulSoup

# SSL 경고 메시지 억제
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VERSION = "v1.0.1-win"
LOGIN_URL = "https://auth1.ruckuswireless.com/login?referer=%2Foauth%2Fauthorize%3Fclient_id%3Df26a12b68eda21c97c3cbdec2dfb96ce31d46d8e995e190bf81f83e4b5e24d11%26redirect_uri%3Dhttps%253A%252F%252Fsupport.ruckuswireless.com%252Fcallback%26response_type%3Dcode%26scope%3Dpublic"

def export_wget_cookies(username, password, cookie_file="cookies.txt", timezone="Asia/Seoul"):
    session = requests.Session()
    # SSL 검증 우회 옵션 적용 (verify=False)
    session.verify = False
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    })

    print(f"[*] Ruckus Cookie Exporter {VERSION} 실행")
    print("[*] Ruckus 로그인 페이지 접속 중...")
    try:
        # 1. GET 요청으로 authenticity_token 추출 (verify=False 적용)
        res = session.get(LOGIN_URL, verify=False)
        res.raise_for_status()

        soup = BeautifulSoup(res.text, "html.parser")
        token_input = soup.find("input", {"name": "authenticity_token"})
        if not token_input or not token_input.get("value"):
            print("[-] authenticity_token 추출 실패!")
            return False

        auth_token = token_input["value"]

        # 2. POST 로그인
        payload = {
            "utf8": "✓",
            "authenticity_token": auth_token,
            "user[username]": username,
            "user[password]": password,
            "user[timezone]": timezone
        }

        headers = {
            "Referer": LOGIN_URL,
            "Content-Type": "application/x-www-form-urlencoded"
        }

        print("[*] 로그인 요청 전송 중...")
        post_res = session.post(LOGIN_URL, data=payload, headers=headers, allow_redirects=True, verify=False)

        if "support.ruckuswireless.com" not in post_res.url:
            print("[-] 로그인 실패: 계정 정보를 확인하세요.")
            return False

        print("[+] 로그인 성공!")

        # 3. Windows/curl.exe 호환 Netscape 포맷 쿠키 파일 작성
        with open(cookie_file, "w", encoding="utf-8", newline='\n') as f:
            f.write("# Netscape HTTP Cookie File\n")
            f.write("# http://curl.haxx.se/rfc/cookie_spec.html\n")
            f.write("# This is a generated file! Do not edit.\n\n")

            for c in session.cookies:
                domain = c.domain
                include_subdomains = "TRUE" if domain.startswith(".") else "FALSE"
                path = c.path
                secure = "TRUE" if c.secure else "FALSE"
                expires = str(c.expires) if c.expires else "0"
                name = c.name
                value = c.value

                f.write(f"{domain}\t{include_subdomains}\t{path}\t{secure}\t{expires}\t{name}\t{value}\n")

        print(f"[+] 'curl.exe'용 쿠키 파일 저장 완료: {cookie_file}")
        return True

    except Exception as e:
        print(f"[-] 오류 발생: {e}")
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=f"Export Ruckus Session Cookies for Windows curl.exe ({VERSION})")
    parser.add_argument("-u", "--username", required=True, help="Ruckus 계정 이메일")
    parser.add_argument("-p", "--password", required=True, help="Ruckus 계정 비밀번호")
    parser.add_argument("-o", "--output", default="cookies.txt", help="저장할 쿠키 파일명 (기본값: cookies.txt)")

    args = parser.parse_args()
    export_wget_cookies(args.username, args.password, args.output)
