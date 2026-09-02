# -*- coding: utf-8 -*-
"""GitHub 업데이트: 소스는 폴더 파일, exe는 Releases 또는 dist/exe."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import requests

GITHUB_OWNER = "cockcut"
GITHUB_REPO = "ruckus_fw_autodownloader_enhanced"
GITHUB_BRANCH = "main"
API = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}"
RAW = f"https://raw.githubusercontent.com/{GITHUB_OWNER}/{GITHUB_REPO}/{GITHUB_BRANCH}"
HEADERS = {"User-Agent": "Ruckus-FW-Downloader-Updater"}

REPO_DIR = "windows/Ruckus_All_Downloader"
APP_PY = "Ruckus_All_Downloader.py"
EXE_NAME = "Ruckus_All_Downloader.exe"
SOURCE_FILES = (
    "Ruckus_All_Downloader.py",
    "get_ruckus_cookie.py",
    "run_downloader.bat",
    "python_uninstaller.bat",
    "ver.txt",
    "updater.py",
)


def configure(*, repo_dir: str, app_py: str, exe_name: str, source_files: tuple[str, ...]):
    global REPO_DIR, APP_PY, EXE_NAME, SOURCE_FILES
    REPO_DIR = repo_dir
    APP_PY = app_py
    EXE_NAME = exe_name
    SOURCE_FILES = source_files


def _get(url: str, timeout: int = 20, stream: bool = False):
    try:
        return requests.get(url, headers=HEADERS, timeout=timeout, stream=stream)
    except requests.exceptions.SSLError:
        return requests.get(url, headers=HEADERS, timeout=timeout, stream=stream, verify=False)


def parse_version(text: str) -> str:
    ver = ""
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.search(r"v?\d+\.\d+\.\d+[a-zA-Z0-9]*", line)
        if m:
            ver = m.group(0)
    return norm_ver(ver)


def norm_ver(s: str) -> str:
    t = (s or "").strip()
    if t.lower().startswith("v") and len(t) > 1 and t[1].isdigit():
        t = t[1:]
    return t


def ver_tuple(s: str):
    t = norm_ver(s)
    nums = []
    for part in re.split(r"[^0-9]+", t):
        if part.isdigit():
            nums.append(int(part))
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums[:4])


def read_local_version(root: Path, fallback: str = "") -> str:
    p = Path(root) / "ver.txt"
    if p.is_file():
        try:
            return parse_version(p.read_text(encoding="utf-8", errors="ignore")) or norm_ver(fallback)
        except Exception:
            pass
    return norm_ver(fallback)


def fetch_remote_ver() -> str:
    r = _get(f"{RAW}/{REPO_DIR}/ver.txt", timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"원격 ver.txt 확인 실패 (HTTP {r.status_code})")
    ver = parse_version(r.text)
    if not ver:
        raise RuntimeError("원격 ver.txt에 버전 정보가 없습니다.")
    return ver


def find_remote_exe() -> dict:
    r = _get(f"{API}/releases/latest", timeout=15)
    if r.status_code == 200:
        data = r.json() or {}
        for a in data.get("assets") or []:
            name = a.get("name") or ""
            if name == EXE_NAME or name.lower().endswith(".exe"):
                return {
                    "url": a.get("browser_download_url"),
                    "name": name,
                    "id": f"rel:{data.get('tag_name')}:{a.get('id')}",
                    "size": a.get("size") or 0,
                }
    paths = (
        f"{REPO_DIR}/dist/{EXE_NAME}",
        f"{REPO_DIR}/{EXE_NAME}",
        f"windows/dist/{EXE_NAME}",
    )
    last = "저장소에서 exe를 찾지 못했습니다."
    for rel in paths:
        cr = _get(f"{API}/contents/{rel}?ref={GITHUB_BRANCH}", timeout=15)
        if cr.status_code == 404:
            continue
        cr.raise_for_status()
        info = cr.json() or {}
        url = info.get("download_url")
        if url:
            return {"url": url, "name": info.get("name") or EXE_NAME, "id": f"file:{info.get('sha')}", "size": info.get("size") or 0}
        last = f"{rel} 다운로드 URL 없음"
    raise RuntimeError(last + " GitHub Releases 또는 dist/ 에 exe를 올리세요.")


def check_update(root: Path, frozen: bool = False, current_version: str = "") -> dict:
    local = read_local_version(root, current_version)
    try:
        remote_ver = fetch_remote_ver()
        extra = {"remote_ver": remote_ver, "local_ver": local}
        if frozen:
            extra.update(find_remote_exe())
    except Exception as exc:
        return {
            "ok": False,
            "available": False,
            "local_ver": local,
            "remote_ver": "",
            "frozen": frozen,
            "message": f"업데이트 확인 실패: {exc}",
        }
    available = ver_tuple(remote_ver) > ver_tuple(local)
    return {
        "ok": True,
        "available": available,
        "local_ver": local,
        "remote_ver": remote_ver,
        "frozen": frozen,
        "message": f"새 버전 {remote_ver} 이(가) 있습니다." if available else f"최신 버전입니다. ({local or remote_ver})",
        **extra,
    }


def apply_source_update(root: Path) -> dict:
    root = Path(root)
    copied = 0
    for name in SOURCE_FILES:
        url = f"{RAW}/{REPO_DIR}/{name}"
        r = _get(url, timeout=60)
        if r.status_code == 404:
            continue
        r.raise_for_status()
        dest = root / name
        dest.write_bytes(r.content)
        copied += 1
    if copied == 0:
        return {"ok": False, "message": "내려받은 소스 파일이 없습니다."}
    return {"ok": True, "message": f"소스 업데이트 완료 ({copied}개 파일). 프로그램을 다시 실행하세요."}


def apply_exe_update(root: Path, exe_path: str, info: dict | None = None) -> dict:
    root = Path(root)
    exe_path = Path(exe_path)
    info = info or {}
    url = info.get("url") or info.get("exe_url")
    if not url:
        url = find_remote_exe()["url"]
    r = _get(url, timeout=180, stream=True)
    r.raise_for_status()
    data = r.content
    if not data or data[:2] != b"MZ":
        return {"ok": False, "message": "받은 파일이 Windows exe가 아닙니다. dist/ 또는 Releases를 확인하세요."}
    new_path = exe_path.with_suffix(exe_path.suffix + ".new")
    new_path.write_bytes(data)
    ver_r = _get(f"{RAW}/{REPO_DIR}/ver.txt", timeout=15)
    if ver_r.status_code == 200:
        (root / "ver.txt").write_bytes(ver_r.content)
    bat = root / "_replace_exe.bat"
    bat.write_text(
        "\r\n".join([
            "@echo off",
            "cd /d \"%~dp0\"",
            "timeout /t 2 /nobreak >nul",
            ":RETRY",
            f'del /f /q "{exe_path.name}"',
            f'if exist "{exe_path.name}" (timeout /t 1 /nobreak >nul & goto RETRY)',
            f'move /y "{new_path.name}" "{exe_path.name}"',
            f'start "" "%cd%\\{exe_path.name}"',
            'del "%~f0"',
            "",
        ]),
        encoding="ascii",
    )
    return {
        "ok": True,
        "message": "새 exe를 받았습니다. 종료 후 자동으로 교체·재실행됩니다.",
        "replace_bat": str(bat),
    }


def apply_update(root: Path, frozen: bool = False, exe_path: str = "", info: dict | None = None) -> dict:
    try:
        if frozen:
            if not exe_path:
                return {"ok": False, "message": "실행 중인 exe 경로를 알 수 없습니다."}
            return apply_exe_update(root, exe_path, info)
        return apply_source_update(root)
    except Exception as exc:
        return {"ok": False, "message": f"업데이트 실패: {exc}"}


def launch_replace_bat(bat: str, cwd: Path):
    env = os.environ.copy()
    for k in list(env):
        if k.startswith("_PYI") or k in ("PYTHONHOME", "PYTHONPATH"):
            env.pop(k, None)
    subprocess.Popen(["cmd", "/c", bat], cwd=str(cwd), env=env)
