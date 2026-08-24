#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import sys
import argparse
import requests
from bs4 import BeautifulSoup

LOGIN_URL = "https://auth1.ruckuswireless.com/login?referer=%2Foauth%2Fauthorize%3Fclient_id%3Df26a12b68eda21c97c3cbdec2dfb96ce31d46d8e995e190bf81f83e4b5e24d11%26redirect_uri%3Dhttps%253A%252F%252Fsupport.ruckuswireless.com%252Fcallback%26response_type%3Dcode%26scope%3Dpublic"

def export_wget_cookies(username, password, cookie_file="cookies.txt", timezone="Asia/Seoul"):
    session = requests.Session()
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    })

    print("[*] Ruckus 로그인 페이지 접속 중...")
    try:
        # 1. GET 요청으로 authenticity_token 추출
        res = session.get(LOGIN_URL)
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
        post_res = session.post(LOGIN_URL, data=payload, headers=headers, allow_redirects=True)

        if "support.ruckuswireless.com" not in post_res.url:
            print("[-] 로그인 실패: 계정 정보를 확인하세요.")
            return False

        print("[+] 로그인 성공!")

        # 3. wget 호환 Netscape 포맷 쿠키 파일 작성
        with open(cookie_file, "w", encoding="utf-8") as f:
            f.write("# Netscape HTTP Cookie File\n")
            f.write("# http://curl.haxx.se/rfc/cookie_spec.html\n")
            f.write("# This is a generated file!  Do not edit.\n\n")

            for c in session.cookies:
                domain = c.domain
                # domain 이 마침표로 시작하지 않으면 추가 (Netscape 포맷)
                include_subdomains = "TRUE" if domain.startswith(".") else "FALSE"
                path = c.path
                secure = "TRUE" if c.secure else "FALSE"
                expires = str(c.expires) if c.expires else "0"
                name = c.name
                value = c.value

                f.write(f"{domain}\t{include_subdomains}\t{path}\t{secure}\t{expires}\t{name}\t{value}\n")

        print(f"[+] 'wget'용 쿠키 파일 저장 완료: {cookie_file}")
        return True

    except Exception as e:
        print(f"[-] 오류 발생: {e}")
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Export Ruckus Session Cookies for wget")
    parser.add_argument("-u", "--username", required=True, help="Ruckus 계정 이메일")
    parser.add_argument("-p", "--password", required=True, help="Ruckus 계정 비밀번호")
    parser.add_argument("-o", "--output", default="cookies.txt", help="저장할 쿠키 파일명 (기본값: cookies.txt)")

    args = parser.parse_args()
    export_wget_cookies(args.username, args.password, args.output)
