#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Ruckus Unleashed Downloader - Python GUI (v0.0.1)
Unleashed 200.x dedicated downloader
"""

import os
import re
import sys
import time
import queue
import shutil
import threading
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, date
from html import unescape
from pathlib import Path
from urllib.parse import unquote

import urllib3
import requests
from bs4 import BeautifulSoup

import tkinter as tk
from tkinter import ttk, messagebox

import updater as gh_updater
gh_updater.configure(
    repo_dir="windows/Ruckus_Unleashed_Downloader",
    app_py="Ruckus_Unleashed_Downloader.py",
    exe_name="Ruckus_Unleashed_Downloader.exe",
    source_files=(
        "Ruckus_Unleashed_Downloader.py",
        "get_ruckus_cookie.py",
        "run_unleashed_downloader.bat",
        "python_uninstaller.bat",
        "ver.txt",
        "updater.py",
    ),
)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VERSION = "v0.0.1"
BASE_URL = "https://support.ruckuswireless.com"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
ALLOWED_GROUPS = {
    "RUCKUS Indoor APs",
    "RUCKUS Outdoor APs",
    "RUCKUS ICX Switches",
    "Virtual SmartZone (vSZ)",
    "RUCKUS Unleashed",
}

if getattr(sys, "frozen", False):
    APP_DIR = Path(sys.executable).resolve().parent
else:
    APP_DIR = Path(__file__).resolve().parent

COOKIE_FILE = APP_DIR / "cookies.txt"


def app_path(name: str) -> Path:
    if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        bundled = Path(sys._MEIPASS) / name
        if bundled.exists():
            return bundled
    return APP_DIR / name


def load_cookie_module():
    sys.path.insert(0, str(app_path("get_ruckus_cookie.py").parent))
    import get_ruckus_cookie as cookie_mod  # noqa: WPS433
    return cookie_mod


def check_cookie_status(path: Path = COOKIE_FILE) -> int:
    """
    반환 값:
      0: 쿠키 없음 (파일 미존재 또는 읽기 실패)
      1: 쿠키는 존재하나 생성/수정일이 오늘 날짜가 아니거나 만료됨
      2: 오늘 생성되었고 유효함
    """
    if not path.exists():
        return 0

    # 파일 수정 시간이 오늘 날짜인지 확인
    file_mtime = datetime.fromtimestamp(path.stat().st_mtime).date()
    if file_mtime != date.today():
        return 1

    now = int(time.time())
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return 0

    valid_cookie_found = False
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 7 and parts[5].strip() == "production_ruckus_support":
            try:
                exp = int(parts[4].strip() or "0")
            except ValueError:
                return 1
            if exp > now:
                valid_cookie_found = True
                break

    return 2 if valid_cookie_found else 1


def cookie_valid(path: Path = COOKIE_FILE) -> bool:
    if not path.exists():
        return False
    now = int(time.time())
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return False
    for line in lines:
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 7 and parts[5].strip() == "production_ruckus_support":
            try:
                exp = int(parts[4].strip() or "0")
            except ValueError:
                return False
            return exp > now
    return False


def session_from_cookies() -> requests.Session:
    sess = requests.Session()
    sess.verify = False
    sess.headers.update({"User-Agent": UA})
    if not COOKIE_FILE.exists():
        return sess
    for line in COOKIE_FILE.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line.strip() or (line.startswith("#") and not line.startswith("#HttpOnly_")):
            continue
        parts = line.split("\t")
        if len(parts) >= 7:
            domain = parts[0].lstrip("#HttpOnly_").lstrip(".")
            sess.cookies.set(parts[5], parts[6], domain=domain)
    return sess


def clean_product_name(name: str) -> str:
    name = re.sub(r"(?i)^(Ruckus|ZoneFlex|SmartZone)\s+", "", name)
    return re.sub(r"\s+", "_", name).strip("_")


def prefix_filename(filename: str, product_name: str) -> str:
    if product_name and (re.match(r"^\d+[\d.]+\.bl7$", filename) or filename == "rcks_fw.bl7"):
        return f"{product_name}_{filename}"
    return filename


def fetch_products(sess: requests.Session):
    return [{"group": "RUCKUS Unleashed", "id": "82", "name": "RUCKUS Unleashed"}]


def fetch_versions(sess: requests.Session, product_id: str):
    url = f"{BASE_URL}/products/{product_id}/filtered_products?type=software"
    html = sess.get(url, timeout=30).text
    soup = BeautifulSoup(html, "html.parser")
    versions = []
    box = soup.select_one("#product_software_version")
    if not box:
        return versions
    for opt in box.find_all("option"):
        val = (opt.get("value") or "").strip()
        text = opt.get_text(strip=True)
        if val and "Choose A Version" not in text:
            versions.append(val)
    return versions


def collect_software_urls(sess: requests.Session, product_id: str, versions):
    urls = []
    seen = set()
    for ver in versions:
        q = f"?version={ver}&type=software" if ver else "?type=software"
        url = f"{BASE_URL}/products/{product_id}/filtered_products{q}"
        html = sess.get(url, timeout=30).text
        for href in re.findall(r'href="(/software/\d+-[^"]+)"', html):
            full = BASE_URL + href
            if full not in seen:
                seen.add(full)
                urls.append(full)
    return urls


def is_truncated_name(name: str) -> bool:
    if not name:
        return True
    return "..." in name or name.endswith("…")


REAL_FILE_EXT = (
    ".img", ".bl7", ".ximg", ".zip", ".bin", ".tar", ".gz", ".tgz",
    ".pkg", ".exe", ".ova", ".vhd", ".qcow2", ".iso",
)


def looks_like_real_file(name: str) -> bool:
    if not name or is_truncated_name(name):
        return False
    lower = name.lower()
    return any(lower.endswith(ext) for ext in REAL_FILE_EXT)


def name_from_url(url: str) -> str:
    if not url:
        return ""
    from urllib.parse import urlparse, parse_qs

    parsed = urlparse(url)
    qs = parse_qs(parsed.query)
    for key, vals in qs.items():
        if key.lower() in ("response-content-disposition", "content-disposition") and vals:
            m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', vals[0], re.I)
            if m:
                return unquote(m.group(1).strip().strip('"'))
    base = unquote(parsed.path.rstrip("/").split("/")[-1])
    m = re.match(r"^\d+-(.+)$", base)
    return m.group(1) if m else base


def parse_detail(sess: requests.Session, page_url: str, product_name: str):
    html = sess.get(page_url, timeout=30).text
    soup = BeautifulSoup(html, "html.parser")
    title = soup.title.get_text(" ", strip=True) if soup.title else "N/A"
    title = unescape(title.split("|")[0].strip())
    filename = ""
    href_name = ""
    dt = soup.find("dt", string=re.compile(r"File Name", re.I))
    if dt:
        dd = dt.find_next_sibling("dd")
        if dd:
            a = dd.find("a")
            if a:
                filename = a.get_text(strip=True)
                href_name = name_from_url(a.get("href") or "")
            else:
                filename = dd.get_text(strip=True)
    if is_truncated_name(filename) and href_name and not is_truncated_name(href_name):
        filename = href_name
    if is_truncated_name(filename):
        from_page = name_from_url(page_url)
        if from_page and not is_truncated_name(from_page):
            filename = from_page
    if not filename:
        filename = name_from_url(page_url) or "download.bin"
    filename = prefix_filename(filename, product_name)
    size = "N/A"
    dt = soup.find("dt", string=re.compile(r"File Size", re.I))
    if dt:
        dd = dt.find_next_sibling("dd")
        if dd:
            size = dd.get_text(strip=True)
    return {
        "page_url": page_url,
        "filename": filename,
        "title": title,
        "size": size,
        "clean_prod": product_name,
    }


def parse_details_parallel(sess_factory, urls, product_name, workers=8):
    results = []
    if not urls:
        return results

    def work(url):
        sess = sess_factory()
        return parse_detail(sess, url, product_name)

    with ThreadPoolExecutor(max_workers=min(workers, len(urls))) as pool:
        futs = [pool.submit(work, u) for u in urls]
        for fut in as_completed(futs):
            try:
                item = fut.result()
                if item and not re.search(r"(?i)Software\s*Link", item["filename"]):
                    results.append(item)
            except Exception:
                pass
    results.sort(key=lambda x: x["filename"].lower())
    return results


def find_curl() -> str:
    exe = shutil.which("curl.exe") or shutil.which("curl")
    return exe or "curl.exe"


def hidden_kwargs():
    kw = {}
    if os.name == "nt":
        kw["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        si.wShowWindow = 0
        kw["startupinfo"] = si
    return kw


def download_one(file_item, dest_dir: Path, status: dict, cancel: threading.Event):
    if cancel.is_set():
        status["status"] = "중지됨"
        return
    page_url = file_item["page_url"]
    eula = 'utf8=%E2%9C%93&tc_form%5Bagreement%5D=I+%22Understand+and+Agree%22&commit=Download'
    sess = session_from_cookies()
    html = sess.get(page_url, timeout=30).text
    m = re.search(r'action="(/software_downloads/[^"]+)"', html)
    if not m:
        m = re.search(r'action="(/documents_downloads/[^"]+)"', html)
    if m:
        endpoint = BASE_URL + m.group(1) + "?" + eula
    else:
        endpoint = page_url.replace("/software/", "/software_downloads/") + "?" + eula

    curl = find_curl()
    head_raw = ""
    try:
        head_raw = subprocess.check_output(
            [curl, "-k", "-s", "-I", "-L", "--max-redirs", "5",
             "-b", str(COOKIE_FILE), "-H", f"User-Agent: {UA}",
             "-H", f"Referer: {page_url}", endpoint],
            text=True,
            encoding="utf-8",
            errors="ignore",
            timeout=30,
            **hidden_kwargs(),
        )
    except Exception:
        head = sess.head(endpoint, allow_redirects=False, timeout=30)
        loc = head.headers.get("Location") or ""
        cd = head.headers.get("Content-Disposition") or ""
        head_raw = f"Location: {loc}\nContent-Disposition: {cd}\n"

    locations = [m.group(1).strip() for m in re.finditer(r"(?i)^Location:\s*(\S+)", head_raw, re.M)]
    loc = ""
    for cand in reversed(locations):
        if "amazonaws.com" in cand or looks_like_real_file(name_from_url(cand)) or "filename=" in cand:
            loc = cand
            break
    if not loc and locations:
        loc = locations[-1]
    if loc and not loc.startswith("http"):
        loc = BASE_URL + loc
    final_url = loc or endpoint

    extracted = ""
    mcd = re.search(r'(?i)Content-Disposition:.*filename\*?=(?:UTF-8\'\')?"?([^";\r\n]+)"?', head_raw)
    if mcd:
        extracted = unquote(mcd.group(1).strip().strip('"'))
    loc_name = name_from_url(final_url)
    if looks_like_real_file(loc_name):
        extracted = loc_name
    elif is_truncated_name(extracted) and loc_name:
        extracted = loc_name

    save_name = file_item.get("filename") or ""
    if looks_like_real_file(extracted):
        save_name = extracted
    elif extracted and (is_truncated_name(save_name) or not looks_like_real_file(save_name)):
        save_name = extracted
    save_name = prefix_filename(save_name, file_item.get("clean_prod") or "")
    save_name = re.sub(r'[<>:"/\\|?*]', "_", save_name).strip()
    save_path = dest_dir / save_name
    status["filename"] = save_name
    status["status"] = "다운로드 중..."
    status["percent"] = 0

    cmd = [
        curl, "-k", "-L", "-C", "-", "--retry", "5", "--retry-delay", "3",
        "-b", str(COOKIE_FILE), "-c", str(COOKIE_FILE),
        "-H", f"User-Agent: {UA}",
        "-H", f"Referer: {page_url}",
        "-o", str(save_path),
        final_url,
    ]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="ignore",
            **hidden_kwargs(),
        )
        status["pid"] = proc.pid
        while True:
            if cancel.is_set():
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except Exception:
                    proc.kill()
                status["status"] = "중지됨"
                return
            line = proc.stderr.readline() if proc.stderr else ""
            if line:
                tokens = line.strip().split()
                if tokens and tokens[0].isdigit():
                    pct = int(tokens[0])
                    if pct <= 100:
                        status["percent"] = pct
                        if len(tokens) >= 4:
                            status["sizeinfo"] = f"{tokens[3]} / {tokens[1]}"
            if proc.poll() is not None:
                break
        code = proc.returncode
    except Exception:
        status["status"] = "오류"
        return

    if cancel.is_set():
        status["status"] = "중지됨"
        return
    if save_path.exists():
        size = save_path.stat().st_size
        if size > 0 and (code in (0, 18, 33) or status.get("percent", 0) >= 99):
            status["percent"] = 100
            status["status"] = "완료"
            status["sizeinfo"] = f"{size / (1024 * 1024):.2f} MB"
            return
    status["status"] = "실패"


class ProgressWindow(tk.Toplevel):
    def __init__(self, master, items, dest_dir):
        super().__init__(master)
        self.title("다운로드 진행 상황")
        self.resizable(False, False)
        self.cancel = threading.Event()
        self.done = False
        self.rows = []
        self.jobs = []

        height = min(900, 80 + 56 * len(items))
        self.geometry(f"720x{height}")

        for i, item in enumerate(items):
            st = {"filename": item["filename"], "percent": 0, "status": "대기 중...", "sizeinfo": item["size"]}
            frm = ttk.Frame(self)
            frm.pack(fill="x", padx=16, pady=6)
            lbl = ttk.Label(frm, text=f"[{i+1}/{len(items)}] 대기 중: {item['filename']}")
            lbl.pack(anchor="w")
            bar = ttk.Progressbar(frm, maximum=100)
            bar.pack(fill="x", pady=4)
            self.rows.append((lbl, bar, st))
            self.jobs.append((item, st))

        self.protocol("WM_DELETE_WINDOW", self.on_close)
        threading.Thread(target=self._run, args=(dest_dir,), daemon=True).start()
        self.after(200, self._tick)

    def _run(self, dest_dir):
        with ThreadPoolExecutor(max_workers=3) as pool:
            futs = [pool.submit(download_one, item, dest_dir, st, self.cancel) for item, st in self.jobs]
            for fut in as_completed(futs):
                try:
                    fut.result()
                except Exception:
                    pass
        self.done = True

    def _tick(self):
        finished = 0
        total = len(self.rows)
        for i, (lbl, bar, st) in enumerate(self.rows):
            bar["value"] = max(0, min(100, st.get("percent", 0)))
            lbl["text"] = f"[{i+1}/{total}] [{st.get('status')}] [{st.get('sizeinfo','')}] {st.get('filename')}"
            if st.get("status") in ("완료", "실패", "오류", "중지됨"):
                finished += 1
        if self.done:
            self.destroy()
            return
        self.after(200, self._tick)

    def on_close(self):
        if not self.done:
            self.cancel.set()
        self.destroy()


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"Ruckus Unleashed Downloader {VERSION} (GUI)")
        self.geometry("850x760")
        self.minsize(850, 760)
        self.resizable(False, False)
        self.configure(bg="#F0F0F0")

        self.products = []
        self.versions = []
        self.files = []
        self.sort_col = None
        self.sort_asc = True
        self.select_all = False
        self.busy = False

        self._build()
        self.after(100, self._startup)
        self.after(400, self._silent_update_check)

    def _win_button(self, parent, text, command, bg="#F0F0F0", bold=False, width=None, height=None):
        font = ("맑은 고딕", 9, "bold") if bold else ("맑은 고딕", 9)
        btn = tk.Button(
            parent,
            text=text,
            command=command,
            bg=bg,
            activebackground=bg,
            fg="#000000",
            font=font,
            relief="raised",
            bd=1,
            highlightthickness=0,
            cursor="hand2",
        )
        if width:
            btn.configure(width=width)
        if height:
            btn.configure(height=height)
        return btn

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            try:
                style.theme_use("xpnative")
            except tk.TclError:
                try:
                    style.theme_use("clam")
                except tk.TclError:
                    pass
        style.configure("TFrame", background="#F0F0F0")
        style.configure("TLabel", background="#F0F0F0", font=("맑은 고딕", 9))
        style.configure("TLabelframe", background="#F0F0F0")
        style.configure("TLabelframe.Label", background="#F0F0F0", font=("맑은 고딕", 9, "bold"))
        style.configure("TCombobox", font=("맑은 고딕", 9))
        style.configure("File.Treeview", rowheight=20, font=("맑은 고딕", 9), background="#FFFFFF", fieldbackground="#FFFFFF", indent=0)
        style.configure("File.Treeview.Heading", font=("맑은 고딕", 9, "bold"))
        style.layout("File.Treeview.Item", [
            ("Treeitem.padding", {"sticky": "nswe", "children": [
                ("Treeitem.image", {"side": "left", "sticky": ""}),
                ("Treeitem.focus", {"side": "left", "sticky": "", "children": [
                    ("Treeitem.text", {"side": "left", "sticky": ""}),
                ]}),
            ]}),
        ])
        style.configure("Status.TLabel", background="#F0F0F0", font=("맑은 고딕", 9))

        upd = tk.Frame(self, bg="#F0F0F0")
        upd.place(x=15, y=8, width=820, height=30)
        self._win_button(upd, "업데이트 확인", self.on_check_update).pack(side="left")
        self.lbl_upd = tk.Label(upd, text="", bg="#F0F0F0", fg="#666666", font=("맑은 고딕", 9), anchor="w")
        self.lbl_upd.pack(side="left", padx=10)
        self.btn_apply_upd = tk.Button(
            upd,
            text="업데이트",
            command=self._do_update,
            bg="#d9534f",
            activebackground="#c9302c",
            fg="white",
            activeforeground="white",
            font=("맑은 고딕", 9, "bold"),
            relief="flat",
            bd=0,
            padx=12,
            pady=2,
            cursor="hand2",
        )

        g1 = ttk.LabelFrame(self, text=" 1. Ruckus 계정 세션 관리 ")
        g1.place(x=15, y=44, width=805, height=75)
        ttk.Label(g1, text="Email:").place(x=15, y=28)
        self.ent_user = ttk.Entry(g1, width=24, font=("맑은 고딕", 9))
        self.ent_user.place(x=65, y=26, width=170, height=23)
        self.ent_user.insert(0, os.environ.get("RUCKUS_USER", ""))
        ttk.Label(g1, text="PW:").place(x=242, y=28)
        self.ent_pass = ttk.Entry(g1, width=18, show="*", font=("맑은 고딕", 9))
        self.ent_pass.place(x=274, y=26, width=130, height=23)
        self.ent_pass.insert(0, os.environ.get("RUCKUS_PASS", ""))
        self._win_button(g1, "로그인 및 세션 갱신", self.on_login).place(x=412, y=25, width=130, height=27)
        self._win_button(g1, "쿠키 삭제", self.on_clear_cookie).place(x=548, y=25, width=85, height=27)
        self.lbl_session = tk.Label(g1, text="세션 상태: 확인 중...", bg="#F0F0F0", font=("맑은 고딕", 9), anchor="w")
        self.lbl_session.place(x=640, y=28, width=155, height=20)

        g2 = ttk.LabelFrame(self, text=" 2. Unleashed 버전 선택 ")
        g2.place(x=15, y=129, width=805, height=90)
        ttk.Label(g2, text="제품 선택:").place(x=15, y=28)
        self.cmb_prod = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_prod.place(x=85, y=25, width=320, height=23)
        self.cmb_prod.bind("<<ComboboxSelected>>", lambda e: self.on_product_change())
        ttk.Label(g2, text="버전 선택:").place(x=420, y=28)
        self.cmb_ver = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_ver.place(x=490, y=25, width=180, height=23)
        self._win_button(g2, "파일 목록 조회", self.on_fetch_files).place(x=680, y=24, width=110, height=27)
        self.lbl_info = tk.Label(g2, text="Unleashed 버전을 불러오는 중입니다...", bg="#F0F0F0", fg="blue", font=("맑은 고딕", 9), anchor="w")
        self.lbl_info.place(x=15, y=58, width=655, height=20)

        g3 = ttk.LabelFrame(self, text=" 3. 다운로드 가능 파일 목록 (검색 및 정렬 가능) ")
        g3.place(x=15, y=229, width=805, height=456)
        ttk.Label(g3, text="결과 내 검색:").place(x=15, y=25)
        self.ent_search = ttk.Entry(g3, font=("맑은 고딕", 9))
        self.ent_search.place(x=95, y=23, width=695, height=23)
        self.ent_search.bind("<KeyRelease>", lambda e: self.refresh_list())

        cols = ("filename", "size", "title")
        box = tk.Frame(g3, bg="white", highlightthickness=1, highlightbackground="#D0D0D0")
        box.place(x=15, y=55, width=775, height=310)
        self.tree = ttk.Treeview(
            box,
            columns=cols,
            show="tree headings",
            selectmode="browse",
            height=16,
            style="File.Treeview",
        )
        self.tree.heading("#0", text="")
        self.tree.column("#0", width=32, minwidth=32, stretch=False, anchor="center")
        self.img_off, self.img_on = self._make_check_images(13)
        self.tree.heading("filename", text="파일명", command=lambda: self.sort_by("filename"))
        self.tree.heading("size", text="용량 (Size)", command=lambda: self.sort_by("size"))
        self.tree.heading("title", text="소프트웨어 타이틀 (Title)", command=lambda: self.sort_by("title"))
        self.tree.column("filename", width=420, minwidth=200, stretch=False)
        self.tree.column("size", width=90, minwidth=80, stretch=False)
        self.tree.column("title", width=520, minwidth=200, stretch=False)
        self.tree.bind("<Button-1>", self.on_tree_click)
        self.tree.bind("<Shift-MouseWheel>", self.on_tree_shift_wheel)
        ys = ttk.Scrollbar(box, orient="vertical", command=self.tree.yview)
        xs = ttk.Scrollbar(box, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        box.grid_rowconfigure(0, weight=1)
        box.grid_columnconfigure(0, weight=1)

        self._win_button(g3, "전체 선택/해제", self.toggle_select_all).place(x=15, y=375, width=110, height=28)
        self._win_button(
            g3,
            "선택 파일 다운로드 실행 (최대 3개 병렬)",
            self.on_download,
            bg="LightSkyBlue",
            bold=True,
        ).place(x=540, y=372, width=250, height=33)

        self.status = tk.StringVar(value="준비 완료.")
        status_bar = tk.Frame(self, bg="#F0F0F0", relief="sunken", bd=1)
        status_bar.place(x=0, y=700, width=850, height=24)
        ttk.Label(status_bar, textvariable=self.status, style="Status.TLabel", anchor="w").pack(fill="x", padx=8)

    def set_session_label(self, text, ok=None):
        self.lbl_session["text"] = text
        if ok is True:
            self.lbl_session["fg"] = "green"
        elif ok is False:
            self.lbl_session["fg"] = "red"
        else:
            self.lbl_session["fg"] = "#333333"

    def _startup(self):
        self.status.set("환경 확인 중...")
        try:
            load_cookie_module()
        except Exception as exc:
            messagebox.showerror("오류", f"get_ruckus_cookie.py 를 불러오지 못했습니다.\n{exc}")
            
        status_code = check_cookie_status()
        
        if status_code == 2:
            self.set_session_label("세션: 유효함", True)
            self.load_products_async()
        elif status_code == 1:
            self.set_session_label("세션: 쿠키 삭제후 로그인", False)
            self.status.set("오늘 발급된 쿠키가 아닙니다. 로그인을 다시 진행해주세요.")
            self.lbl_info["text"] = "제품을 불러오려면 로그인이 필요합니다."
        else:  # status_code == 0
            self.set_session_label("세션: 쿠키없음. 로그인", False)
            self.status.set("계정 정보를 입력하고 로그인을 진행해주세요.")
            self.lbl_info["text"] = "제품을 불러오려면 로그인이 필요합니다."

    def _silent_update_check(self):
        threading.Thread(target=self._check_update_worker, args=(False,), daemon=True).start()

    def on_check_update(self):
        self.lbl_upd["text"] = "업데이트 확인 중..."
        threading.Thread(target=self._check_update_worker, args=(True,), daemon=True).start()

    def _check_update_worker(self, prompt):
        frozen = bool(getattr(sys, "frozen", False))
        info = gh_updater.check_update(APP_DIR, frozen=frozen, current_version=VERSION, exe_path=sys.executable if frozen else "")
        self._update_info = info
        self.after(0, lambda: self._show_update(info, prompt))

    def _set_apply_visible(self, show):
        if not hasattr(self, "btn_apply_upd"):
            return
        if show:
            if not self.btn_apply_upd.winfo_ismapped():
                self.btn_apply_upd.pack(side="left")
        else:
            self.btn_apply_upd.pack_forget()

    def _show_update(self, info, prompt):
        if not info.get("ok"):
            self.lbl_upd["text"] = info.get("message") or "업데이트 확인 실패"
            self._set_apply_visible(False)
            return
        if info.get("available"):
            self.lbl_upd["text"] = info.get("message") or "새 버전이 있습니다."
            self._set_apply_visible(True)
        else:
            self.lbl_upd["text"] = "최신 버전입니다."
            self._set_apply_visible(False)

    def _do_update(self):
        info = getattr(self, "_update_info", None) or {}
        frozen = bool(getattr(sys, "frozen", False))
        self.lbl_upd["text"] = "업데이트 받는 중..."
        self._set_apply_visible(False)

        def work():
            result = gh_updater.apply_update(
                APP_DIR,
                frozen=frozen,
                exe_path=sys.executable if frozen else "",
                info=info,
                expected_sha=info.get("remote") or "",
            )
            self.after(0, lambda: self._after_update(result, frozen))

        threading.Thread(target=work, daemon=True).start()

    def _after_update(self, result, frozen):
        if not result.get("ok"):
            self.lbl_upd["text"] = result.get("message") or "업데이트 실패"
            self._set_apply_visible(True)
            return
        self.lbl_upd["text"] = result.get("message") or "업데이트 완료"
        self._set_apply_visible(False)
        bat = result.get("replace_bat")
        if bat:
            try:
                gh_updater.launch_replace_bat(bat, APP_DIR)
            except Exception as exc:
                self.lbl_upd["text"] = str(exc)
                return
            self.destroy()
            return
        self.destroy()

    def on_login(self):
        user = self.ent_user.get().strip()
        pw = self.ent_pass.get().strip()
        if not user or not pw:
            messagebox.showwarning("알림", "이메일과 비밀번호를 모두 입력해주세요.")
            return
        self.status.set("로그인 시도 중...")
        self.update_idletasks()

        def work():
            try:
                if COOKIE_FILE.exists():
                    COOKIE_FILE.unlink()
                mod = load_cookie_module()
                ok = mod.export_wget_cookies(user, pw, str(COOKIE_FILE))
            except Exception:
                ok = False
            self.after(0, lambda: self._login_done(ok))

        threading.Thread(target=work, daemon=True).start()

    def _login_done(self, ok):
        if ok and cookie_valid():
            self.set_session_label("세션: 유효함 (성공)", True)
            self.status.set("로그인 성공!")
            self.load_products_async()
        else:
            self.set_session_label("세션: 로그인 실패", False)
            messagebox.showerror("오류", "로그인에 실패했습니다. 계정 정보를 확인하세요.")

    def on_clear_cookie(self):
        if not messagebox.askyesno("쿠키 삭제", "저장된 로그인 쿠키를 삭제할까요?"):
            return
        try:
            if COOKIE_FILE.exists():
                COOKIE_FILE.unlink()
        except OSError:
            pass
        self.products = []
        self.versions = []
        self.files = []
        self.cmb_prod["values"] = []
        self.cmb_ver["values"] = []
        self.cmb_prod.set("")
        self.cmb_ver.set("")
        self.refresh_list()
        self.set_session_label("세션: 쿠키 없음", False)
        self.status.set("쿠키를 삭제했습니다. 다시 로그인하세요.")
        self.lbl_info["text"] = "버전을 불러오려면 로그인이 필요합니다."

    def load_products_async(self):
        self.status.set("Unleashed 버전 로딩 중...")

        def work():
            try:
                products = fetch_products(session_from_cookies())
                err = None
            except Exception as exc:
                products, err = [], str(exc)
            self.after(0, lambda: self._products_done(products, err))

        threading.Thread(target=work, daemon=True).start()

    def _products_done(self, products, err):
        self.products = products
        labels = [f"[{p['group']}] {p['name']}" for p in products]
        self.cmb_prod["values"] = labels
        if labels:
            self.cmb_prod.current(0)
            self.status.set("Unleashed 제품 선택 완료.")
            self.on_product_change()
        else:
            self.status.set("제품 목록을 불러오지 못했습니다." + (f" {err}" if err else ""))

    def on_product_change(self):
        idx = self.cmb_prod.current()
        if idx < 0 or idx >= len(self.products):
            return
        prod = self.products[idx]
        self.lbl_info["text"] = f"선택된 제품 ID: {prod['id']} | 카테고리: {prod['group']}"
        self.status.set("지원 버전 파싱 중...")

        def work():
            try:
                vers = fetch_versions(session_from_cookies(), prod["id"])
                err = None
            except Exception as exc:
                vers, err = [], str(exc)
            self.after(0, lambda: self._versions_done(vers, err))

        threading.Thread(target=work, daemon=True).start()

    def _versions_done(self, vers, err):
        self.versions = vers
        values = ["ALL (전체 버전)"] + vers
        self.cmb_ver["values"] = values
        self.cmb_ver.current(0)
        self.lbl_info["text"] = f"Unleashed 버전 {len(vers)}개"
        self.status.set("버전 파싱 완료." if not err else f"버전 파싱 실패: {err}")

    def on_fetch_files(self):
        idx = self.cmb_prod.current()
        if idx < 0:
            return
        prod = self.products[idx]
        vidx = self.cmb_ver.current()
        if vidx <= 0:
            target_vers = list(self.versions)
        else:
            target_vers = [self.cmb_ver.get()]
        self.status.set("소프트웨어 항목 분석 중... (버전별 일괄 조회)")
        self.files = []
        self.refresh_list()
        name = clean_product_name(prod["name"])

        def work():
            try:
                sess = session_from_cookies()
                urls = collect_software_urls(sess, prod["id"], target_vers or [""])
                files = parse_details_parallel(session_from_cookies, urls, name)
                err = None
            except Exception as exc:
                files, err = [], str(exc)
            self.after(0, lambda: self._files_done(files, err))

        threading.Thread(target=work, daemon=True).start()

    def _files_done(self, files, err):
        for f in files:
            f["checked"] = False
        self.files = files
        self.select_all = False
        self.refresh_list()
        if err:
            self.status.set(f"파일 목록 실패: {err}")
        else:
            self.status.set(f"총 {len(files)}개 소프트웨어 항목 파싱 완료 (전체 버전 순회).")

    def visible_files(self):
        kw = self.ent_search.get().strip().lower()
        if not kw:
            return list(self.files)
        out = []
        for f in self.files:
            blob = f"{f['filename']} {f['size']} {f['title']}".lower()
            if kw in blob:
                out.append(f)
        return out

    def _make_check_images(self, size=18):
        def draw(checked):
            img = tk.PhotoImage(width=size, height=size)
            img.put("#FFFFFF", to=(0, 0, size, size))
            border = "#333333"
            for i in range(size):
                img.put(border, to=(i, 0))
                img.put(border, to=(i, size - 1))
                img.put(border, to=(0, i))
                img.put(border, to=(size - 1, i))
            if checked:
                for i in range(3, size - 3):
                    img.put("#1A6CC8", to=(i, 3, i + 1, size - 3))
            return img
        return draw(False), draw(True)

    def _box_image(self, checked):
        return self.img_on if checked else self.img_off

    def refresh_list(self):
        for iid in self.tree.get_children():
            self.tree.delete(iid)
        for f in self.visible_files():
            checked = bool(f.get("checked"))
            self.tree.insert(
                "",
                "end",
                iid=str(id(f)),
                text="",
                image=self._box_image(checked),
                values=(f["filename"], f["size"], f["title"]),
            )

    def _file_by_iid(self, iid):
        vals = self.tree.item(iid, "values")
        if not vals:
            return None
        name = vals[0]
        for f in self.files:
            if f["filename"] == name:
                return f
        return None

    def on_tree_shift_wheel(self, event):
        self.tree.xview_scroll(-1 if event.delta > 0 else 1, "units")
        return "break"

    def on_tree_click(self, event):
        region = self.tree.identify_region(event.x, event.y)
        col = self.tree.identify_column(event.x)
        iid = self.tree.identify_row(event.y)
        if not iid:
            return
        if region in ("tree", "cell") and col in ("#0", "#1"):
            if col == "#0":
                self._toggle_file(iid)
                return "break"

    def _toggle_file(self, iid):
        f = self._file_by_iid(iid)
        if not f:
            return
        f["checked"] = not bool(f.get("checked"))
        self.tree.item(iid, image=self._box_image(f["checked"]))

    def sort_by(self, col):
        if self.sort_col == col:
            self.sort_asc = not self.sort_asc
        else:
            self.sort_col = col
            self.sort_asc = True
        self.files.sort(key=lambda x: str(x.get(col, "")).lower(), reverse=not self.sort_asc)
        self.refresh_list()

    def toggle_select_all(self):
        visible = self.visible_files()
        if not visible:
            return
        self.select_all = not self.select_all
        for f in visible:
            f["checked"] = self.select_all
        self.refresh_list()

    def on_download(self):
        chosen = [f for f in self.files if f.get("checked")]
        if not chosen:
            messagebox.showwarning("알림", "다운로드할 파일을 선택하세요.")
            return
        win = ProgressWindow(self, chosen, APP_DIR)
        self.wait_window(win)
        cancelled = any(st.get("status") == "중지됨" for _, st in win.jobs) if hasattr(win, "jobs") else False
        if cancelled:
            messagebox.showinfo("알림", "사용자에 의해 다운로드가 중단되었습니다.")
        else:
            messagebox.showinfo("완료", "선택한 모든 파일의 다운로드 작업이 완료되었습니다.")


def main():
    app = App()
    app.mainloop()


if __name__ == "__main__":
    main()
