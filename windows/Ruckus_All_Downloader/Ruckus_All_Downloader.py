#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Ruckus All Downloader - 펌웨어/문서 다운로드 (단일 파일, 쿠키 공유)."""

import os
import re
import sys
import time
import shutil
import threading
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, date
from html import unescape
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

import urllib3
import requests
from bs4 import BeautifulSoup

import tkinter as tk
from tkinter import ttk, messagebox

try:
    import updater as gh_updater
    gh_updater.configure(
        repo_dir="windows/Ruckus_All_Downloader",
        app_py="Ruckus_All_Downloader.py",
        exe_name="Ruckus_All_Downloader.exe",
        source_files=(
            "Ruckus_All_Downloader.py",
            "get_ruckus_cookie.py",
            "run_downloader.bat",
            "ver.txt",
            "updater.py",
        ),
    )
except Exception:
    gh_updater = None

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VERSION = "v0.0.1p2"
BASE_URL = "https://support.ruckuswireless.com"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
ALLOWED_GROUPS = {
    "RUCKUS Indoor APs",
    "RUCKUS Outdoor APs",
    "RUCKUS ICX Switches",
    "RUCKUS Edge and virtual Edge",
    "SmartZone (SZ)",
    "Virtual SmartZone (vSZ)",
    "RUCKUS Unleashed",
}

if getattr(sys, "frozen", False):
    APP_DIR = Path(sys.executable).resolve().parent
else:
    APP_DIR = Path(__file__).resolve().parent

COOKIE_FILE = APP_DIR / "cookies.txt"
_ds_sib = Path(__file__).resolve().parent.parent / "datasheet"
DS_SAVE_DIR = (_ds_sib if _ds_sib.is_dir() else APP_DIR) / "datasheet"


def open_save_folder(path: Path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    try:
        if sys.platform.startswith("win"):
            os.startfile(str(path))
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        else:
            subprocess.Popen(["xdg-open", str(path)])
    except Exception as exc:
        messagebox.showerror("오류", f"폴더를 열 수 없습니다.\n{path}\n{exc}")



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
    if not path.exists():
        return 0
    from datetime import datetime, date
    try:
        if datetime.fromtimestamp(path.stat().st_mtime).date() != date.today():
            return 1
    except OSError:
        return 0
    return 2 if cookie_valid(path) else 1


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
    name = re.sub(r'[<>:"/\\|?*]', "_", name)
    return re.sub(r"\s+", "_", name).strip("_") or "Unknown"


def version_folder_name(ver: str) -> str:
    ver = (ver or "").strip()
    if not ver or ver.upper().startswith("ALL"):
        return "unknown"
    return re.sub(r'[<>:"/\\|?*]', "_", ver) or "unknown"


def item_save_dir(kind: str, item: dict, fallback_product="") -> Path:
    prod = item.get("product_folder") or item.get("clean_prod") or fallback_product or "Unknown"
    ver = version_folder_name(item.get("version") or "")
    dest = APP_DIR / kind / prod / ver
    dest.mkdir(parents=True, exist_ok=True)
    return dest


def prefix_filename(filename: str, product_name: str) -> str:
    if product_name and (re.match(r"^\d+[\d.]+\.bl7$", filename) or filename == "rcks_fw.bl7"):
        return f"{product_name}_{filename}"
    return filename


def fw_fetch_products(sess: requests.Session):
    html = sess.get(f"{BASE_URL}/software", timeout=30).text
    soup = BeautifulSoup(html, "html.parser")
    products = []
    for group in soup.find_all("optgroup"):
        label = (group.get("label") or "").strip()
        is_eol = label == "EOL RUCKUS Products"
        if label not in ALLOWED_GROUPS and not is_eol:
            continue
        for opt in group.find_all("option"):
            val = (opt.get("value") or "").strip()
            name = opt.get_text(strip=True)
            if not val or name.startswith("zzz"):
                continue
            if is_eol and not re.search(r"(?i)(Ruckus|SmartZone|ZoneDirector)", name):
                continue
            products.append({"group": label, "id": val, "name": name})
    return products


def fw_fetch_versions(sess: requests.Session, product_id: str):
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
    meta = {}
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
                meta[full] = ver or ""
    return urls, meta


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


def fw_parse_detail(sess: requests.Session, page_url: str, product_name: str):
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


def fw_parse_details_parallel(sess_factory, urls, product_name, version_map=None, workers=8):
    results = []
    version_map = version_map or {}
    if not urls:
        return results

    def work(url):
        sess = sess_factory()
        item = fw_parse_detail(sess, url, product_name)
        if item:
            item["version"] = version_map.get(url, item.get("version") or "")
        return item

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


def fw_download_one(file_item, dest_dir: Path, status: dict, cancel: threading.Event):
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
        "-b", str(COOKIE_FILE),
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


class FirmwareProgressWindow(tk.Toplevel):
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
            futs = [pool.submit(fw_download_one, item, item.get("dest_dir") or dest_dir, st, self.cancel) for item, st in self.jobs]
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


class FirmwareApp(tk.Toplevel):
    def __init__(self, master=None):
        if master is None:
            root = tk.Tk()
            root.withdraw()
            master = root
            self._owns_root = root
        else:
            self._owns_root = None
        super().__init__(master)
        self.title(f"Ruckus All Downloader {VERSION} (GUI)")
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
        self.bind("<FocusIn>", lambda e: self._refresh_session_label())

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

        g1 = ttk.LabelFrame(self, text=" 1. 계정 세션 정보 ")
        g1.place(x=15, y=10, width=805, height=62)
        self.lbl_session = tk.Label(g1, text="세션 : 유효함", bg="#F0F0F0", fg="green", font=("맑은 고딕", 9), anchor="w")
        self.lbl_session.place(x=16, y=16, width=770, height=24)

        g2 = ttk.LabelFrame(self, text=" 2. 제품 및 버전 선택 ")
        g2.place(x=15, y=80, width=805, height=102)
        ttk.Label(g2, text="제품 선택:").place(x=15, y=28)
        self.cmb_prod = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_prod.place(x=85, y=25, width=320, height=23)
        self.cmb_prod.bind("<<ComboboxSelected>>", lambda e: self.on_product_change())
        ttk.Label(g2, text="버전 선택:").place(x=420, y=28)
        self.cmb_ver = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_ver.place(x=490, y=25, width=180, height=23)
        self._win_button(g2, "파일 목록 조회", self.on_fetch_files).place(x=680, y=24, width=110, height=27)
        self.lbl_info = tk.Label(g2, text="제품을 불러오는 중입니다...", bg="#F0F0F0", fg="blue", font=("맑은 고딕", 9), anchor="w")
        self.lbl_info.place(x=16, y=56, width=775, height=24)

        g3 = ttk.LabelFrame(self, text=" 3. 다운로드 가능 파일 목록 (검색 및 정렬 가능) ")
        g3.place(x=15, y=190, width=805, height=500)
        ttk.Label(g3, text="결과 내 검색:").place(x=15, y=25)
        self.ent_search = ttk.Entry(g3, font=("맑은 고딕", 9))
        self.ent_search.place(x=95, y=23, width=695, height=23)
        self.ent_search.bind("<KeyRelease>", lambda e: self.refresh_list())

        cols = ("filename", "size", "title")
        box = tk.Frame(g3, bg="white", highlightthickness=1, highlightbackground="#D0D0D0")
        box.place(x=15, y=55, width=775, height=370)
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

        self._win_button(g3, "전체 선택/해제", self.toggle_select_all).place(x=15, y=435, width=110, height=28)
        self._win_button(g3, "firmware 폴더", self.open_firmware_folder).place(x=140, y=435, width=130, height=28)
        self._win_button(
            g3,
            "선택 파일 다운로드 실행 (최대 3개 병렬)",
            self.on_download,
            bg="LightSkyBlue",
            bold=True,
        ).place(x=540, y=432, width=250, height=33)

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


    def _refresh_session_label(self):
        if not hasattr(self, "lbl_session"):
            return
        try:
            code = check_cookie_status()
        except Exception:
            code = 2 if cookie_valid() else (0 if not COOKIE_FILE.exists() else 1)
        if code == 2:
            self.set_session_label("세션 : 유효함", True)
        elif code == 1:
            self.set_session_label("세션 : 쿠키 삭제후 로그인", False)
        else:
            self.set_session_label("세션 : 쿠키없음. 로그인", False)

    def _startup(self):
        (APP_DIR / "firmware").mkdir(parents=True, exist_ok=True)
        self.set_session_label("세션 : 유효함", True)
        self.load_products_async()

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
            self.set_session_label("세션 상태: 유효함 (성공)", True)
            self.status.set("로그인 성공!")
            self.load_products_async()
        else:
            self.set_session_label("세션 상태: 로그인 실패", False)
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
        self.set_session_label("세션 상태: 쿠키 없음", False)
        self.status.set("쿠키를 삭제했습니다. 다시 로그인하세요.")
        self.lbl_info["text"] = "제품을 불러오려면 로그인이 필요합니다."

    def load_products_async(self):
        self.status.set("제품 카테고리 로딩 중...")

        def work():
            try:
                products = fw_fetch_products(session_from_cookies())
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
            self.status.set(f"제품 목록 ({len(labels)}개) 수집 완료.")
            self.on_product_change()
        else:
            self.status.set("제품 목록을 불러오지 못했습니다." + (f" {err}" if err else ""))

    def on_product_change(self):
        idx = self.cmb_prod.current()
        if idx < 0 or idx >= len(self.products):
            return
        prod = self.products[idx]
        self.lbl_info["text"] = f"{prod['group']} | {prod['name']}"
        self.status.set("지원 버전 파싱 중...")

        def work():
            try:
                vers = fw_fetch_versions(session_from_cookies(), prod["id"])
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
                urls, vmap = collect_software_urls(sess, prod["id"], target_vers or [""])
                files = fw_parse_details_parallel(session_from_cookies, urls, name, vmap)
                for f in files:
                    f["product_folder"] = name
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

    def open_firmware_folder(self):
        open_save_folder(APP_DIR / "firmware")

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
        folder = chosen[0].get("clean_prod") or ""
        if not folder:
            idx = self.cmb_prod.current()
            folder = clean_product_name(self.products[idx]["name"]) if 0 <= idx < len(self.products) else "Unknown"
        for f in chosen:
            f["dest_dir"] = item_save_dir("firmware", f, folder)
        dest = chosen[0]["dest_dir"]
        win = FirmwareProgressWindow(self, chosen, dest)
        self.wait_window(win)
        cancelled = any(st.get("status") == "중지됨" for _, st in win.jobs) if hasattr(win, "jobs") else False
        if cancelled:
            messagebox.showinfo("알림", "사용자에 의해 다운로드가 중단되었습니다.")
        else:
            messagebox.showinfo("완료", "선택한 모든 파일의 다운로드 작업이 완료되었습니다.")


def doc_fetch_products(sess: requests.Session):
    html = sess.get(f"{BASE_URL}/documents", timeout=30).text
    soup = BeautifulSoup(html, "html.parser")
    products = []
    box = soup.select_one("#product_document") or soup
    for group in box.find_all("optgroup"):
        label = (group.get("label") or "").strip()
        if not label:
            continue
        for opt in group.find_all("option"):
            val = (opt.get("value") or "").strip()
            name = opt.get_text(strip=True)
            if not val or name.startswith("zzz"):
                continue
            products.append({"group": label, "id": val, "name": name})
    return products


def doc_fetch_versions(sess: requests.Session, product_id: str):
    url = f"{BASE_URL}/products/{product_id}/filtered_products?type=document"
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


def _page_doc_hrefs(html: str):
    return re.findall(r'href="(/documents/\d+-[^"/]+)"', html)


def collect_document_urls(sess: requests.Session, product_id: str, versions):
    """펌웨어 다운로더와 동일: 선택한 버전(또는 전체 버전)을 하나씩 조회."""
    urls = []
    meta = {}
    seen = set()
    target = list(versions) if versions else [""]
    for ver in target:
        q = f"?version={ver}&type=document" if ver else "?type=document"
        page = 1
        while page <= 80:
            url = f"{BASE_URL}/products/{product_id}/filtered_products{q}"
            if page > 1:
                url = f"{url}&page={page}"
            html = sess.get(url, timeout=30).text
            soup = BeautifulSoup(html, "html.parser")
            rows = soup.select("tr.Document")
            found = []
            if rows:
                for tr in rows:
                    a = tr.find("a", href=re.compile(r"^/documents/\d+-"))
                    if not a:
                        continue
                    href = a.get("href", "").split("?")[0]
                    found.append((href, (tr.get("data-version") or ver or "").strip()))
            else:
                found = [(h, ver) for h in _page_doc_hrefs(html)]
            if not found:
                break
            new_on_page = 0
            for href, row_ver in found:
                full = href if href.startswith("http") else BASE_URL + href
                if full not in seen:
                    seen.add(full)
                    urls.append(full)
                    meta[full] = row_ver
                    new_on_page += 1
            if new_on_page == 0 or not soup_has_next(html, page):
                break
            page += 1
    return urls, meta


def soup_has_next(html: str, page: int) -> bool:
    return bool(re.search(rf"page={page + 1}(?:&|$|\")", html))


def doc_parse_detail(sess: requests.Session, page_url: str):
    html = sess.get(page_url, timeout=30).text
    soup = BeautifulSoup(html, "html.parser")
    title = soup.title.get_text(" ", strip=True) if soup.title else "N/A"
    title = unescape(title.split("|")[0].strip())
    filename = ""
    ftype = ""
    size = "N/A"
    dt = soup.find("dt", string=re.compile(r"File Name", re.I))
    if dt:
        dd = dt.find_next_sibling("dd")
        if dd:
            a = dd.find("a")
            if a:
                filename = (a.get("title") or a.get_text(strip=True) or "").strip()
            else:
                filename = dd.get_text(strip=True)
    dt = soup.find("dt", string=re.compile(r"File Size", re.I))
    if dt:
        dd = dt.find_next_sibling("dd")
        if dd:
            size = dd.get_text(strip=True)
    icon = soup.select_one(".file_type span")
    if icon:
        ftype = icon.get_text(strip=True).upper()
    if not filename:
        filename = unquote(page_url.rstrip("/").split("/")[-1])
    if "..." in filename or filename.endswith("…"):
        if ftype == "PDF" and not filename.lower().endswith(".pdf"):
            filename = filename.replace("...", "").rstrip(".") + ".pdf"
        elif ftype == "ZIP" and not filename.lower().endswith(".zip"):
            filename = filename.replace("...", "").rstrip(".") + ".zip"
    return {
        "page_url": page_url,
        "download_url": page_url.rstrip("/") + "/download",
        "filename": filename,
        "title": title,
        "size": size,
        "ftype": ftype or Path(filename).suffix.lstrip(".").upper() or "FILE",
        "version": "",
        "checked": False,
    }


def doc_parse_details_parallel(sess_factory, urls, version_map=None, workers=8):
    results = []
    version_map = version_map or {}
    if not urls:
        return results

    def work(url):
        item = doc_parse_detail(sess_factory(), url)
        if item:
            item["version"] = version_map.get(url, item.get("version") or "")
        return item

    with ThreadPoolExecutor(max_workers=min(workers, len(urls))) as pool:
        futs = [pool.submit(work, u) for u in urls]
        for fut in as_completed(futs):
            try:
                item = fut.result()
                if item:
                    results.append(item)
            except Exception:
                pass
    results.sort(key=lambda x: ((x.get("version") or ""), (x.get("filename") or "").lower()))
    return results


def _safe_name(name: str) -> str:
    name = re.sub(r'[<>:"/\\|?*]', "_", name).strip()
    return name or "document.bin"


def doc_download_one(file_item, dest_dir: Path, status: dict, cancel: threading.Event):
    if cancel.is_set():
        status["status"] = "중지됨"
        return
    page_url = file_item["page_url"]
    endpoint = file_item.get("download_url") or (page_url.rstrip("/") + "/download")
    save_name = _safe_name(file_item.get("filename") or "document.bin")
    status["filename"] = save_name
    status["status"] = "다운로드 중..."
    status["percent"] = 0

    curl = find_curl()
    save_path = dest_dir / save_name
    cmd = [
        curl, "-k", "-L", "-C", "-", "--retry", "5", "--retry-delay", "3",
        "-b", str(COOKIE_FILE),
        "-H", f"User-Agent: {UA}",
        "-H", f"Referer: {page_url}",
        "-D", "-",
        "-o", str(save_path),
        endpoint,
    ]
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="ignore",
            **hidden_kwargs(),
        )
        status["pid"] = proc.pid
        headers = ""
        while True:
            if cancel.is_set():
                proc.terminate()
                status["status"] = "중지됨"
                return
            if proc.poll() is not None:
                break
            time.sleep(0.2)
            if save_path.exists() and save_path.stat().st_size:
                status["percent"] = min(99, status.get("percent", 10) + 5)
        out, _err = proc.communicate(timeout=5)
        headers = out or ""
        code = proc.returncode
    except Exception:
        status["status"] = "오류"
        return

    mcd = re.search(r'(?i)content-disposition:.*filename\*?=(?:UTF-8\'\')?"?([^";\r\n]+)"?', headers)
    if mcd:
        real = _safe_name(unquote(mcd.group(1).strip().strip('"')))
        if real and real != save_name:
            dest = dest_dir / real
            try:
                if save_path.exists():
                    if dest.exists():
                        dest.unlink()
                    save_path.rename(dest)
                    save_path = dest
                    save_name = real
                    status["filename"] = real
            except OSError:
                pass

    if cancel.is_set():
        status["status"] = "중지됨"
        return
    if save_path.exists() and save_path.stat().st_size > 0 and code in (0, 18, 33, None):
        status["percent"] = 100
        status["status"] = "완료"
        status["sizeinfo"] = f"{save_path.stat().st_size / 1024:.1f} KB"
        return
    status["status"] = "실패"


class DocumentProgressWindow(tk.Toplevel):
    def __init__(self, master, items, dest_dir):
        super().__init__(master)
        self.title("다운로드 진행 상황")
        self.resizable(False, False)
        self.cancel = threading.Event()
        self.done = False
        self.rows = []
        self.jobs = []
        height = min(900, 80 + 56 * max(1, len(items)))
        self.geometry(f"720x{height}")
        for i, item in enumerate(items):
            st = {"filename": item.get("filename", ""), "status": "대기 중...", "percent": 0, "sizeinfo": item.get("size", "")}
            frm = ttk.Frame(self)
            frm.pack(fill="x", padx=16, pady=6)
            lbl = ttk.Label(frm, text=f"[{i+1}/{len(items)}] 대기 중: {item.get('filename','')}")
            lbl.pack(anchor="w")
            bar = ttk.Progressbar(frm, maximum=100)
            bar.pack(fill="x", pady=4)
            self.rows.append((lbl, bar, st))
            self.jobs.append((item, st))
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        threading.Thread(target=self._run, args=(dest_dir,), daemon=True).start()
        self.after(200, self._tick)

    def _run(self, dest_dir):
        with ThreadPoolExecutor(max_workers=min(10, max(1, len(self.jobs)))) as pool:
            futs = [pool.submit(doc_download_one, item, item.get("dest_dir") or dest_dir, st, self.cancel) for item, st in self.jobs]
            for fut in as_completed(futs):
                try:
                    fut.result()
                except Exception:
                    pass
        self.done = True

    def _tick(self):
        total = len(self.rows)
        for i, (lbl, bar, st) in enumerate(self.rows):
            bar["value"] = max(0, min(100, st.get("percent", 0)))
            lbl["text"] = f"[{i+1}/{total}] [{st.get('status')}] [{st.get('sizeinfo','')}] {st.get('filename')}"
        if self.done:
            self.destroy()
            return
        self.after(200, self._tick)

    def on_close(self):
        if not self.done:
            self.cancel.set()
        self.destroy()


class DocumentApp(tk.Toplevel):
    def __init__(self, master=None):
        if master is None:
            root = tk.Tk()
            root.withdraw()
            master = root
            self._owns_root = root
        else:
            self._owns_root = None
        super().__init__(master)
        self.title(f"Ruckus Document Downloader {VERSION} (GUI)")
        self.geometry("850x760")
        self.minsize(850, 760)
        self.resizable(False, False)
        self.configure(bg="#F0F0F0")
        self.products = []
        self.versions = []
        self.files = []
        self.select_all = False
        self._build()
        self.after(100, self._startup)
        self.bind("<FocusIn>", lambda e: self._refresh_session_label())

    def _win_button(self, parent, text, command, bg="#F0F0F0", bold=False):
        font = ("맑은 고딕", 9, "bold") if bold else ("맑은 고딕", 9)
        return tk.Button(
            parent, text=text, command=command, bg=bg, activebackground=bg,
            fg="#000000", font=font, relief="raised", bd=1,
            highlightthickness=0, cursor="hand2",
        )

    def _make_check_images(self, size=13):
        def box(on):
            img = tk.PhotoImage(width=size, height=size)
            img.put("#ffffff", to=(0, 0, size, size))
            for i in range(size):
                img.put("#333333", to=(i, 0))
                img.put("#333333", to=(i, size - 1))
                img.put("#333333", to=(0, i))
                img.put("#333333", to=(size - 1, i))
            if on:
                for i in range(3, size - 3):
                    for j in range(3, size - 3):
                        img.put("#1565c0", to=(i, j))
            return img
        return box(False), box(True)

    def _build(self):
        style = ttk.Style(self)
        for theme in ("vista", "xpnative", "clam"):
            try:
                style.theme_use(theme)
                break
            except tk.TclError:
                continue
        style.configure("TFrame", background="#F0F0F0")
        style.configure("TLabel", background="#F0F0F0", font=("맑은 고딕", 9))
        style.configure("TLabelframe", background="#F0F0F0")
        style.configure("TLabelframe.Label", background="#F0F0F0", font=("맑은 고딕", 9, "bold"))
        style.configure("File.Treeview", rowheight=20, font=("맑은 고딕", 9), indent=0)
        style.configure("Status.TLabel", background="#F0F0F0", font=("맑은 고딕", 9))
        style.layout("File.Treeview.Item", [
            ("Treeitem.padding", {"sticky": "nswe", "children": [
                ("Treeitem.image", {"side": "left", "sticky": ""}),
                ("Treeitem.focus", {"side": "left", "sticky": "", "children": [
                    ("Treeitem.text", {"side": "left", "sticky": ""}),
                ]}),
            ]}),
        ])

        g1 = ttk.LabelFrame(self, text=" 1. 계정 세션 정보 ")
        g1.place(x=15, y=10, width=805, height=62)
        self.lbl_session = tk.Label(g1, text="세션 : 유효함", bg="#F0F0F0", fg="green", font=("맑은 고딕", 9), anchor="w")
        self.lbl_session.place(x=16, y=16, width=770, height=24)

        g2 = ttk.LabelFrame(self, text=" 2. 제품 및 버전 선택 (type=document) ")
        g2.place(x=15, y=80, width=805, height=102)
        ttk.Label(g2, text="제품 선택:").place(x=15, y=28)
        self.cmb_prod = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_prod.place(x=85, y=25, width=320, height=23)
        self.cmb_prod.bind("<<ComboboxSelected>>", lambda e: self.on_product_change())
        ttk.Label(g2, text="버전 선택:").place(x=420, y=28)
        self.cmb_ver = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_ver.place(x=490, y=25, width=180, height=23)
        self._win_button(g2, "문서 목록 조회", self.on_fetch_docs).place(x=680, y=24, width=110, height=27)
        self.lbl_info = tk.Label(g2, text="문서 제품을 불러오는 중입니다...", bg="#F0F0F0", fg="blue", font=("맑은 고딕", 9), anchor="w")
        self.lbl_info.place(x=16, y=56, width=775, height=24)

        g3 = ttk.LabelFrame(self, text=" 3. 다운로드 가능 문서 목록 (PDF / ZIP) ")
        g3.place(x=15, y=190, width=805, height=500)
        ttk.Label(g3, text="결과 내 검색:").place(x=15, y=25)
        self.ent_search = ttk.Entry(g3, font=("맑은 고딕", 9))
        self.ent_search.place(x=95, y=23, width=695, height=23)
        self.ent_search.bind("<KeyRelease>", lambda e: self.refresh_list())

        box = tk.Frame(g3, bg="white", highlightthickness=1, highlightbackground="#D0D0D0")
        box.place(x=15, y=55, width=775, height=370)
        self.img_off, self.img_on = self._make_check_images(13)
        cols = ("filename", "version", "ftype", "size", "title")
        self.tree = ttk.Treeview(
            box, columns=cols, show="tree headings", selectmode="browse",
            height=16, style="File.Treeview",
        )
        self.tree.heading("#0", text="")
        self.tree.column("#0", width=32, minwidth=32, stretch=False, anchor="center")
        self.tree.heading("filename", text="파일명")
        self.tree.heading("version", text="버전")
        self.tree.heading("ftype", text="유형")
        self.tree.heading("size", text="용량")
        self.tree.heading("title", text="문서 제목")
        self.tree.column("filename", width=230, stretch=False)
        self.tree.column("version", width=80, stretch=False)
        self.tree.column("ftype", width=55, stretch=False)
        self.tree.column("size", width=70, stretch=False)
        self.tree.column("title", width=320, stretch=False)
        self.tree.bind("<Button-1>", self.on_tree_click)
        ys = ttk.Scrollbar(box, orient="vertical", command=self.tree.yview)
        xs = ttk.Scrollbar(box, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        box.grid_rowconfigure(0, weight=1)
        box.grid_columnconfigure(0, weight=1)

        self._win_button(g3, "전체 선택/해제", self.toggle_select_all).place(x=15, y=435, width=110, height=28)
        self._win_button(g3, "document 폴더", self.open_document_folder).place(x=140, y=435, width=130, height=28)
        self._win_button(
            g3, "선택 문서 다운로드 실행 (최대 10개 병렬)", self.on_download,
            bg="LightSkyBlue", bold=True,
        ).place(x=520, y=432, width=270, height=33)

        self.status = tk.StringVar(value="준비 완료.")
        bar = tk.Frame(self, bg="#F0F0F0", relief="sunken", bd=1)
        bar.place(x=0, y=700, width=850, height=24)
        ttk.Label(bar, textvariable=self.status, style="Status.TLabel", anchor="w").pack(fill="x", padx=8)

    def set_session_label(self, text, ok=None):
        self.lbl_session["text"] = text
        if ok is True:
            self.lbl_session["fg"] = "green"
        elif ok is False:
            self.lbl_session["fg"] = "red"
        else:
            self.lbl_session["fg"] = "#333333"


    def _refresh_session_label(self):
        if not hasattr(self, "lbl_session"):
            return
        try:
            code = check_cookie_status()
        except Exception:
            code = 2 if cookie_valid() else (0 if not COOKIE_FILE.exists() else 1)
        if code == 2:
            self.set_session_label("세션 : 유효함", True)
        elif code == 1:
            self.set_session_label("세션 : 쿠키 삭제후 로그인", False)
        else:
            self.set_session_label("세션 : 쿠키없음. 로그인", False)

    def _startup(self):
        (APP_DIR / "document").mkdir(parents=True, exist_ok=True)
        self.set_session_label("세션 : 유효함", True)
        self.load_products_async()

    def _silent_update_check(self):
        threading.Thread(target=self._check_update_worker, args=(False,), daemon=True).start()

    def on_check_update(self):
        self.lbl_upd["text"] = "업데이트 확인 중..."
        threading.Thread(target=self._check_update_worker, args=(True,), daemon=True).start()

    def _check_update_worker(self, prompt):
        frozen = bool(getattr(sys, "frozen", False))
        info = gh_updater.check_update(
            APP_DIR,
            frozen=frozen,
            current_version=VERSION,
            exe_path=sys.executable if frozen else "",
        )
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

        def work():
            try:
                if COOKIE_FILE.exists():
                    COOKIE_FILE.unlink()
                ok = load_cookie_module().export_wget_cookies(user, pw, str(COOKIE_FILE))
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
        except OSError as exc:
            messagebox.showerror("쿠키 삭제", str(exc))
            return
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
        self.lbl_info["text"] = "제품을 불러오려면 로그인이 필요합니다."

    def load_products_async(self):
        self.status.set("문서 제품 목록 로딩 중...")

        def work():
            try:
                products = doc_fetch_products(session_from_cookies())
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
            self.status.set(f"문서 제품 {len(labels)}개.")
            self.on_product_change()
        else:
            self.status.set("제품 목록을 불러오지 못했습니다." + (f" {err}" if err else ""))

    def on_product_change(self):
        idx = self.cmb_prod.current()
        if idx < 0 or idx >= len(self.products):
            return
        prod = self.products[idx]
        self.lbl_info["text"] = f"{prod['group']} | {prod['name']}"
        self.status.set("문서 버전 파싱 중...")

        def work():
            try:
                vers = doc_fetch_versions(session_from_cookies(), prod["id"])
                err = None
            except Exception as exc:
                vers, err = [], str(exc)
            self.after(0, lambda: self._versions_done(vers, err))

        threading.Thread(target=work, daemon=True).start()

    def _versions_done(self, vers, err):
        self.versions = vers
        self.cmb_ver["values"] = ["ALL (전체 버전)"] + vers
        self.cmb_ver.current(0)
        self.status.set("버전 파싱 완료." if not err else f"버전 파싱 실패: {err}")

    def on_fetch_docs(self):
        if not cookie_valid():
            messagebox.showwarning("알림", "먼저 로그인해 주세요.")
            return
        idx = self.cmb_prod.current()
        if idx < 0 or idx >= len(self.products):
            return
        prod = self.products[idx]
        ver_idx = self.cmb_ver.current()
        if ver_idx <= 0:
            target_vers = list(self.versions)
            all_mode = True
        else:
            target_vers = [self.cmb_ver.get()]
            all_mode = False
        self.status.set("문서 항목 분석 중... (버전별 일괄 조회)" if all_mode else "문서 항목 분석 중...")
        self.files = []
        self.refresh_list()

        def work():
            try:
                urls, vmap = collect_document_urls(session_from_cookies(), prod["id"], target_vers or [""])
                items = doc_parse_details_parallel(session_from_cookies, urls, vmap)
                folder = clean_product_name(prod["name"])
                for it in items:
                    it["product_folder"] = folder
                err = None
            except Exception as exc:
                items, err = [], str(exc)
            self.after(0, lambda: self._files_done(items, err, all_mode))

        threading.Thread(target=work, daemon=True).start()

    def _files_done(self, items, err, all_mode=False):
        for f in items:
            f["checked"] = False
        self.files = items
        self.select_all = False
        self.refresh_list()
        if err:
            self.status.set(f"문서 목록 실패: {err}")
        elif all_mode:
            self.status.set(f"총 {len(items)}개 문서 항목 파싱 완료 (전체 버전 순회).")
        else:
            self.status.set(f"총 {len(items)}개 문서 항목 파싱 완료.")

    def refresh_list(self):
        q = (self.ent_search.get() or "").lower()
        self.tree.delete(*self.tree.get_children())
        for i, item in enumerate(self.files):
            blob = f"{item.get('filename','')} {item.get('title','')} {item.get('ftype','')} {item.get('version','')}".lower()
            if q and q not in blob:
                continue
            img = self.img_on if item.get("checked") else self.img_off
            self.tree.insert(
                "", "end", iid=str(i), image=img,
                values=(
                    item.get("filename", ""),
                    item.get("version", ""),
                    item.get("ftype", ""),
                    item.get("size", ""),
                    item.get("title", ""),
                ),
            )

    def on_tree_click(self, event):
        row = self.tree.identify_row(event.y)
        col = self.tree.identify_column(event.x)
        if not row:
            return
        if col == "#0":
            idx = int(row)
            if 0 <= idx < len(self.files):
                self.files[idx]["checked"] = not self.files[idx].get("checked")
                self.tree.item(row, image=self.img_on if self.files[idx]["checked"] else self.img_off)
            return "break"

    def toggle_select_all(self):
        self.select_all = not self.select_all
        for item in self.files:
            item["checked"] = self.select_all
        self.refresh_list()

    def open_document_folder(self):
        open_save_folder(APP_DIR / "document")

    def on_download(self):
        chosen = [f for f in self.files if f.get("checked")]
        if not chosen:
            messagebox.showwarning("알림", "다운로드할 문서를 선택하세요.")
            return
        folder = chosen[0].get("product_folder")
        if not folder:
            idx = self.cmb_prod.current()
            folder = clean_product_name(self.products[idx]["name"]) if 0 <= idx < len(self.products) else "Unknown"
        for f in chosen:
            f["dest_dir"] = item_save_dir("document", f, folder)
        dest = chosen[0]["dest_dir"]
        win = DocumentProgressWindow(self, chosen, dest)
        self.wait_window(win)
        cancelled = any(st.get("status") == "중지됨" for _, st in getattr(win, "jobs", []))
        if cancelled:
            messagebox.showinfo("알림", "사용자에 의해 다운로드가 중단되었습니다.")
        else:
            messagebox.showinfo("완료", "선택한 모든 파일의 다운로드 작업이 완료되었습니다.")






DS_SITE = "https://www.ruckusnetworks.com"
DS_PRODUCTS_HOME = "https://www.ruckusnetworks.com/products/"


def ds_abs(href: str) -> str:
    href = unescape((href or "").strip())
    if not href:
        return ""
    return urljoin(DS_SITE + "/", href)


def ds_norm_asset(url: str) -> str:
    url = unescape(url or "").replace("&#x2B;", "+").replace("&amp;", "&")
    return url.strip()


def ds_safe_name(name: str) -> str:
    name = re.sub(r'[<>:"/\\|?*]', "_", (name or "").strip())
    return name or "Data Sheet.pdf"


def ds_filename_from_url(url: str, product_name: str) -> str:
    url = ds_norm_asset(url)
    if "/download/assets/" in url:
        raw = unquote(url.split("/download/assets/")[-1].split("/")[0]).replace("+", " ").strip()
        if raw and raw.lower() not in {"data sheet", "datasheet", "view data sheet"}:
            if Path(raw).suffix.lower() not in {".pdf", ".zip", ".html"}:
                raw += ".pdf"
            return ds_safe_name(raw)
    m = re.search(r"downloadname=([^&]+)", url, re.I)
    if m:
        raw = unquote(m.group(1)).replace("+", " ").strip()
        if raw:
            return ds_safe_name(raw)
    base = (product_name or "Data Sheet").replace("_", " ").strip()
    if not re.search(r"(?i)data\s*sheet", base):
        base = f"{base} Data Sheet"
    if not Path(base).suffix:
        base += ".pdf"
    return ds_safe_name(base)


def ds_dedupe_key(url: str) -> str:
    url = ds_norm_asset(url)
    path = urlparse(url).path.rstrip("/")
    if "/download/assets/" in url:
        return "asset:" + path.split("/")[-1].lower()
    m = re.search(r"downloadname=([^&]+)", url, re.I)
    if m:
        return "file:" + unquote(m.group(1)).lower()
    m = re.search(r"[?&]ID=([^&]+)", url)
    if m:
        return "id:" + unquote(m.group(1)).split(":")[0].lower()
    return "url:" + url.split("?")[0].lower()


def ds_is_pdf_link(url: str) -> bool:
    u = (url or "").lower()
    if u.endswith(".html") or "/datasheets/" in u and u.endswith(".html"):
        return False
    if "webresources.ruckuswireless.com/datasheets/" in u and not u.endswith(".pdf"):
        return False
    return True


def ds_fetch_categories(sess: requests.Session):
    html = sess.get(DS_PRODUCTS_HOME, timeout=30).text
    cats = []
    seen = set()
    for href, name in re.findall(
        r'class="curated-menu-link[^"]*" href="([^"]+)"[^>]*>([^<]+)',
        html,
    ):
        url = ds_abs(href)
        name = unescape(name).strip()
        if not url or "/products/" not in url or not name:
            continue
        key = url.rstrip("/")
        if key in seen:
            continue
        seen.add(key)
        cats.append({"name": name, "url": key + "/"})
    return cats


def ds_is_switch_family(name: str, url: str) -> bool:
    slug = url.rstrip("/").split("/")[-1].lower()
    if slug.startswith("item"):
        return False
    if re.fullmatch(r"icx\d+", slug):
        return True
    if re.search(r"(?i)\bICX\s*\d+\s+Switches\b", name):
        return True
    if re.search(r"(?i)\bICX\s*\d+-", name):
        return False
    return False


def ds_parse_listing(html: str, group: str):
    items = []
    for href, name in re.findall(
        r'<a href="([^"]+)" class="title title-ruckus">([^<]+)</a>',
        html,
    ):
        url = ds_abs(href).rstrip("/")
        name = unescape(name).strip()
        if not url or not name or url.lower().endswith("/compare"):
            continue
        if group == "Ethernet Switches" and not ds_is_switch_family(name, url):
            continue
        items.append({"group": group, "id": url, "name": name, "url": url})
    return items


DS_FIXED_SPECS = (
    {
        "page": "https://www.ruckusnetworks.com/products/",
        "group": "Guides",
        "name": "RUCKUS Product Guide",
        "texts": ("download our product guide",),
        "assets": ("ruckus+product+guide",),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/",
        "group": "Guides",
        "name": "RUCKUS Accessory Guide",
        "texts": ("download our accessory guide",),
        "assets": ("ruckus+accessory+guide",),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/network-control-and-management/cloud-managed/",
        "group": "Cloud-managed Systems",
        "name": "Data Sheet: RUCKUS One",
        "texts": ("download",),
        "assets": ("data+sheet%3a+ruckus+one", "data+sheet:+ruckus+one", "ruckus+one"),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/network-control-and-management/network-controllers/",
        "group": "Network Controllers",
        "name": "RUCKUS SmartZone Family Data Sheet",
        "texts": ("read data sheet",),
        "assets": ("ruckus+smartzone+family+data+sheet",),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/network-control-and-management/controller-less/",
        "group": "Controller-less Systems",
        "name": "RUCKUS Unleashed Data Sheet",
        "texts": ("download the ruckus unleashed data sheet", "unleashed data sheet"),
        "assets": ("unleashed",),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/service-assurance-business-intelligence/",
        "group": "Service Assurance and Business Intelligence",
        "name": "RUCKUS AI Data Sheet",
        "texts": ("download data sheet",),
        "assets": ("ruckus+analytics+data+sheet", "ruckus+ai"),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/optical-transceivers/",
        "group": "Optical Transceivers",
        "name": "RUCKUS Optics Datasheet",
        "texts": ("download data sheet",),
        "assets": ("ethernet+optics", "optics"),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/accessories/",
        "group": "Accessories",
        "name": "RUCKUS Accessory Guide",
        "texts": ("download guide", "ruckus accessory guide"),
        "assets": ("ruckus+accessory+guide",),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/accessories/",
        "group": "Accessories",
        "name": "RUCKUS Fiber Backpack",
        "texts": ("download data sheet",),
        "assets": ("fiber+backpack",),
    },
    {
        "page": "https://www.ruckusnetworks.com/products/accessories/",
        "group": "Accessories",
        "name": "RUCKUS Fiber Node",
        "texts": ("download data sheet", "fiber node"),
        "assets": ("fiber+node", "ds-fibernode.pdf"),
    },
)


def ds_iter_download_anchors(html: str):
    html = html.replace("&#x2B;", "+").replace("&amp;", "&")
    for href, inner in re.findall(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', html, re.I | re.S):
        text = unescape(re.sub(r"<[^>]+>", " ", inner))
        text = re.sub(r"\s+", " ", text).strip()
        yield ds_norm_asset(href), text


def ds_match_fixed(html: str, spec: dict):
    assets = tuple(a.lower() for a in spec.get("assets") or ())
    texts = tuple(t.lower() for t in spec.get("texts") or ())
    found = []
    for href, text in ds_iter_download_anchors(html):
        blob = f"{href} {text}".lower()
        if assets and not any(a in blob for a in assets):
            continue
        if texts and not any(t in text.lower() or t in href.lower() for t in texts):
            if not any(a in href.lower() for a in assets):
                continue
        if href.startswith("http") and ("webresources" in href or href.lower().endswith(".pdf") or "downloadname=" in href.lower()):
            found.append((href, text))
    if found:
        found.sort(key=lambda x: (0 if "/download/assets/" in x[0] else 1, x[0]))
        return found[0]
    for href, text in ds_iter_download_anchors(html):
        if any(a in href.lower() for a in assets):
            return href, text
    return None


def ds_fetch_fixed_docs(sess: requests.Session):
    cache = {}
    extras = []
    seen = set()
    for spec in DS_FIXED_SPECS:
        page = spec["page"]
        if page not in cache:
            try:
                cache[page] = sess.get(page, timeout=30).text
            except Exception:
                cache[page] = ""
        hit = ds_match_fixed(cache[page], spec)
        if not hit:
            continue
        href, text = hit
        key = ds_dedupe_key(href)
        if key in seen:
            continue
        seen.add(key)
        extras.append({
            "group": spec["group"],
            "id": href,
            "name": spec["name"],
            "url": spec["page"],
            "download_url": href,
            "filename": ds_filename_from_url(href, spec["name"]),
            "title": spec["name"],
        })
    return extras


def ds_fetch_products():
    products = []
    seen = set()
    sess = requests.Session()
    sess.headers.update({"User-Agent": UA})
    sess.verify = False
    products.extend(ds_fetch_fixed_docs(sess))
    for p in products:
        seen.add(p.get("download_url") or p["url"])
    allow_groups = {
        "Wireless Access Points",
        "Ethernet Switches",
    }
    for cat in ds_fetch_categories(sess):
        if cat["name"] not in allow_groups:
            continue
        for page in range(1, 8):
            list_url = f"{cat['url']}?pageSize=100&page={page}"
            try:
                html = sess.get(list_url, timeout=30).text
            except Exception:
                break
            batch = ds_parse_listing(html, cat["name"])
            added = 0
            for prod in batch:
                if prod["url"] in seen:
                    continue
                seen.add(prod["url"])
                products.append(prod)
                added += 1
            if added == 0:
                break
    return products


def ds_items_for_product(prod: dict):
    name = clean_product_name(prod["name"])
    if prod.get("download_url"):
        return [{
            "page_url": prod.get("url") or "",
            "download_url": prod["download_url"],
            "filename": prod.get("filename") or ds_filename_from_url(prod["download_url"], name),
            "title": prod.get("title") or prod["name"],
            "size": "PDF",
            "version": "",
            "product_folder": name,
            "checked": False,
        }]
    return ds_parse_page(prod["url"], name)


def ds_parse_page(page_url: str, product_name: str):
    """모델 페이지 상단 'Download Data Sheet'만 사용. 관련 자료/중복/버튼문구 파일명은 제외."""
    sess = requests.Session()
    sess.headers.update({"User-Agent": UA})
    sess.verify = False
    html = sess.get(page_url if page_url.endswith("/") else page_url + "/", timeout=30).text
    items = []
    seen = set()

    def add(url):
        url = ds_norm_asset(url)
        if not url or not ds_is_pdf_link(url):
            return
        key = ds_dedupe_key(url)
        if key in seen:
            return
        seen.add(key)
        fname = ds_filename_from_url(url, product_name)
        title = Path(fname).stem
        items.append({
            "page_url": page_url,
            "download_url": url,
            "filename": fname,
            "title": title,
            "size": "PDF",
            "version": "",
            "product_folder": product_name,
            "checked": False,
        })

    urls = [ds_norm_asset(u) for u in re.findall(r'<a href="([^"]+)"[^>]*>\s*Download Data Sheet\s*<', html, re.I)]
    if not urls:
        urls = [ds_norm_asset(u) for u in re.findall(
            r'<a href="([^"]+)"[^>]*class="[^"]*btn-comm-secondary[^"]*"[^>]*>\s*Download Data Sheet',
            html,
            re.I,
        )]
    official = [u for u in urls if "/download/assets/" in u]
    if official:
        urls = official[:1]
    else:
        urls = urls[:1]
    for url in urls:
        add(url)
    return items


def ds_download_one(file_item, dest_dir: Path, status: dict, cancel: threading.Event):
    if cancel.is_set():
        status["status"] = "중지됨"
        return
    url = file_item.get("download_url") or ""
    save_name = re.sub(r'[<>:"/\\\\|?*]', "_", file_item.get("filename") or "datasheet.pdf").strip()
    dest_dir.mkdir(parents=True, exist_ok=True)
    save_path = dest_dir / save_name
    status["filename"] = save_name
    status["status"] = "다운로드 중..."
    status["percent"] = 10
    try:
        sess = requests.Session()
        sess.headers.update({"User-Agent": UA})
        sess.verify = False
        with sess.get(url, stream=True, timeout=60, allow_redirects=True) as resp:
            resp.raise_for_status()
            cd = resp.headers.get("Content-Disposition") or ""
            m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', cd, re.I)
            if m:
                real = re.sub(r'[<>:"/\\\\|?*]', "_", unquote(m.group(1).strip().strip('"'))).strip()
                if real:
                    save_path = dest_dir / real
                    save_name = real
                    status["filename"] = real
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            with open(save_path, "wb") as fh:
                for chunk in resp.iter_content(65536):
                    if cancel.is_set():
                        status["status"] = "중지됨"
                        return
                    if not chunk:
                        continue
                    fh.write(chunk)
                    done += len(chunk)
                    if total:
                        status["percent"] = min(99, int(done * 100 / total))
        if save_path.exists() and save_path.stat().st_size > 0:
            status["percent"] = 100
            status["status"] = "완료"
            status["sizeinfo"] = f"{save_path.stat().st_size / 1024:.1f} KB"
            return
    except Exception:
        status["status"] = "오류"
        return
    status["status"] = "실패"


class DatasheetProgressWindow(tk.Toplevel):
    def __init__(self, master, items, dest_dir):
        super().__init__(master)
        self.title("다운로드 진행 상황")
        self.resizable(False, False)
        self.cancel = threading.Event()
        self.done = False
        self.rows = []
        self.jobs = []
        height = min(900, 80 + 56 * max(1, len(items)))
        self.geometry(f"720x{height}")
        for i, item in enumerate(items):
            st = {"filename": item.get("filename", ""), "status": "대기 중...", "percent": 0, "sizeinfo": ""}
            frm = ttk.Frame(self)
            frm.pack(fill="x", padx=16, pady=6)
            lbl = ttk.Label(frm, text=f"[{i+1}/{len(items)}] 대기 중: {item.get('filename','')}")
            lbl.pack(anchor="w")
            bar = ttk.Progressbar(frm, maximum=100)
            bar.pack(fill="x", pady=4)
            self.rows.append((lbl, bar, st))
            self.jobs.append((item, st))
        self.protocol("WM_DELETE_WINDOW", self.on_close)
        threading.Thread(target=self._run, args=(dest_dir,), daemon=True).start()
        self.after(200, self._tick)

    def _run(self, dest_dir):
        with ThreadPoolExecutor(max_workers=min(10, max(1, len(self.jobs)))) as pool:
            futs = [
                pool.submit(ds_download_one, item, item.get("dest_dir") or dest_dir, st, self.cancel)
                for item, st in self.jobs
            ]
            for fut in as_completed(futs):
                try:
                    fut.result()
                except Exception:
                    pass
        self.done = True

    def _tick(self):
        total = len(self.rows)
        for i, (lbl, bar, st) in enumerate(self.rows):
            bar["value"] = max(0, min(100, st.get("percent", 0)))
            lbl["text"] = f"[{i+1}/{total}] [{st.get('status')}] [{st.get('sizeinfo','')}] {st.get('filename')}"
        if self.done:
            self.destroy()
            return
        self.after(200, self._tick)

    def on_close(self):
        if not self.done:
            self.cancel.set()
        self.destroy()


class DatasheetApp(tk.Toplevel):
    def __init__(self, master=None):
        if master is None:
            root = tk.Tk()
            root.withdraw()
            self._own_root = root
            super().__init__(root)
        else:
            self._own_root = None
            super().__init__(master)
        self.title(f"Ruckus Datasheet Downloader {VERSION} (GUI)")
        self.geometry("850x760")
        self.minsize(850, 760)
        self.resizable(False, False)
        self.configure(bg="#F0F0F0")
        self.products = []
        self.files = []
        self.select_all = False
        self.bind("<FocusIn>", lambda e: self._refresh_session_label())
        self._build()
        self.after(100, self._startup)
        if self._own_root is not None:
            self.protocol("WM_DELETE_WINDOW", self._close_standalone)

    def _close_standalone(self):
        self.destroy()
        if self._own_root is not None:
            self._own_root.destroy()

    def _win_button(self, parent, text, command, bg="#F0F0F0", bold=False):
        font = ("맑은 고딕", 9, "bold") if bold else ("맑은 고딕", 9)
        return tk.Button(
            parent, text=text, command=command, bg=bg, activebackground=bg,
            fg="#000000", font=font, relief="raised", bd=1,
            highlightthickness=0, cursor="hand2",
        )

    def _make_check_images(self, size=13):
        def box(on):
            img = tk.PhotoImage(width=size, height=size)
            img.put("#ffffff", to=(0, 0, size, size))
            for i in range(size):
                img.put("#333333", to=(i, 0))
                img.put("#333333", to=(i, size - 1))
                img.put("#333333", to=(0, i))
                img.put("#333333", to=(size - 1, i))
            if on:
                for i in range(3, size - 3):
                    for j in range(3, size - 3):
                        img.put("#1565c0", to=(i, j))
            return img
        return box(False), box(True)

    def _build(self):
        style = ttk.Style(self)
        for theme in ("vista", "xpnative", "clam"):
            try:
                style.theme_use(theme)
                break
            except tk.TclError:
                continue
        style.configure("TFrame", background="#F0F0F0")
        style.configure("TLabel", background="#F0F0F0", font=("맑은 고딕", 9))
        style.configure("TLabelframe", background="#F0F0F0")
        style.configure("TLabelframe.Label", background="#F0F0F0", font=("맑은 고딕", 9, "bold"))
        style.configure("File.Treeview", rowheight=20, font=("맑은 고딕", 9), indent=0)
        style.configure("Status.TLabel", background="#F0F0F0", font=("맑은 고딕", 9))
        style.layout("File.Treeview.Item", [
            ("Treeitem.padding", {"sticky": "nswe", "children": [
                ("Treeitem.image", {"side": "left", "sticky": ""}),
                ("Treeitem.focus", {"side": "left", "sticky": "", "children": [
                    ("Treeitem.text", {"side": "left", "sticky": ""}),
                ]}),
            ]}),
        ])

        g1 = ttk.LabelFrame(self, text=" 1. 계정 세션 정보 ")
        g1.place(x=15, y=10, width=805, height=62)
        self.lbl_session = tk.Label(
            g1, text="세션 : 유효함", bg="#F0F0F0", fg="green",
            font=("맑은 고딕", 9), anchor="w",
        )
        self.lbl_session.place(x=16, y=16, width=770, height=24)

        g2 = ttk.LabelFrame(self, text=" 2. 제품 선택 ")
        g2.place(x=15, y=80, width=805, height=102)
        ttk.Label(g2, text="제품 선택:").place(x=15, y=28)
        self.cmb_prod = ttk.Combobox(g2, state="readonly", font=("맑은 고딕", 9))
        self.cmb_prod.place(x=85, y=25, width=500, height=23)
        self.cmb_prod.bind("<<ComboboxSelected>>", lambda e: self.on_product_change())
        self._win_button(g2, "데이터시트 조회", self.on_fetch).place(x=600, y=24, width=180, height=27)
        self.lbl_info = tk.Label(g2, text="제품을 불러오는 중입니다...", bg="#F0F0F0", fg="blue", font=("맑은 고딕", 9), anchor="w")
        self.lbl_info.place(x=16, y=56, width=775, height=24)

        g3 = ttk.LabelFrame(self, text=" 3. 다운로드 가능 데이터시트 목록 ")
        g3.place(x=15, y=190, width=805, height=500)
        ttk.Label(g3, text="결과 내 검색:").place(x=15, y=25)
        self.ent_search = ttk.Entry(g3, font=("맑은 고딕", 9))
        self.ent_search.place(x=95, y=23, width=695, height=23)
        self.ent_search.bind("<KeyRelease>", lambda e: self.refresh_list())

        box = tk.Frame(g3, bg="white", highlightthickness=1, highlightbackground="#D0D0D0")
        box.place(x=15, y=55, width=775, height=370)
        self.img_off, self.img_on = self._make_check_images(13)
        cols = ("filename", "size", "title")
        self.tree = ttk.Treeview(box, columns=cols, show="tree headings", selectmode="browse", height=16, style="File.Treeview")
        self.tree.heading("#0", text="")
        self.tree.column("#0", width=32, minwidth=32, stretch=False, anchor="center")
        self.tree.heading("filename", text="파일명")
        self.tree.heading("size", text="유형")
        self.tree.heading("title", text="제목")
        self.tree.column("filename", width=320, stretch=False)
        self.tree.column("size", width=70, stretch=False)
        self.tree.column("title", width=350, stretch=False)
        self.tree.bind("<Button-1>", self.on_tree_click)
        ys = ttk.Scrollbar(box, orient="vertical", command=self.tree.yview)
        xs = ttk.Scrollbar(box, orient="horizontal", command=self.tree.xview)
        self.tree.configure(yscrollcommand=ys.set, xscrollcommand=xs.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        ys.grid(row=0, column=1, sticky="ns")
        xs.grid(row=1, column=0, sticky="ew")
        box.grid_rowconfigure(0, weight=1)
        box.grid_columnconfigure(0, weight=1)

        self._win_button(g3, "전체 선택/해제", self.toggle_select_all).place(x=15, y=435, width=110, height=28)
        self._win_button(g3, "datasheet 폴더", self.open_datasheet_folder).place(x=140, y=435, width=130, height=28)
        self._win_button(
            g3, "선택 데이터시트 다운로드 실행 (최대 10개 병렬)", self.on_download,
            bg="LightSkyBlue", bold=True,
        ).place(x=480, y=432, width=310, height=33)

        self.status = tk.StringVar(value="준비 완료.")
        bar = tk.Frame(self, bg="#F0F0F0", relief="sunken", bd=1)
        bar.place(x=0, y=700, width=850, height=24)
        ttk.Label(bar, textvariable=self.status, style="Status.TLabel", anchor="w").pack(fill="x", padx=8)

    def set_session_label(self, text, ok=None):
        self.lbl_session["text"] = text
        if ok is True:
            self.lbl_session["fg"] = "green"
        elif ok is False:
            self.lbl_session["fg"] = "red"
        else:
            self.lbl_session["fg"] = "#333333"

    def _refresh_session_label(self):
        if not hasattr(self, "lbl_session"):
            return
        try:
            code = check_cookie_status()
        except Exception:
            code = 2 if cookie_valid() else (0 if not COOKIE_FILE.exists() else 1)
        if code == 2:
            self.set_session_label("세션 : 유효함", True)
        elif code == 1:
            self.set_session_label("세션 : 쿠키 삭제후 로그인", False)
        else:
            self.set_session_label("세션 : 쿠키없음. 로그인", False)

    def _startup(self):
        (DS_SAVE_DIR).mkdir(parents=True, exist_ok=True)
        self.set_session_label("세션 : 유효함", True)
        self.status.set("홈페이지 제품 목록을 불러오는 중...")

        def work():
            try:
                products = ds_fetch_products()
                err = None
            except Exception as exc:
                products, err = [], str(exc)
            self.after(0, lambda: self._products_done(products, err))

        threading.Thread(target=work, daemon=True).start()

    def _products_done(self, products, err):
        self.products = products
        labels = ["ALL (전체)"] + [f"[{p['group']}] {p['name']}" for p in products]
        self.cmb_prod["values"] = labels
        if products:
            self.cmb_prod.current(0)
            self.status.set(f"데이터시트 제품 {len(products)}개.")
            self.on_product_change()
        else:
            self.status.set("제품 목록을 불러오지 못했습니다." + (f" {err}" if err else ""))

    def on_product_change(self):
        idx = self.cmb_prod.current()
        if idx == 0:
            self.lbl_info["text"] = f"ALL | 전체 {len(self.products)}개"
            return
        real = idx - 1
        if real < 0 or real >= len(self.products):
            return
        prod = self.products[real]
        self.lbl_info["text"] = f"{prod['group']} | {prod['name']}"

    def on_fetch(self):
        idx = self.cmb_prod.current()
        if idx < 0:
            return
        targets = list(self.products) if idx == 0 else (
            [self.products[idx - 1]] if 0 <= idx - 1 < len(self.products) else []
        )
        if not targets:
            return
        self.status.set("데이터시트 항목 분석 중...")
        self.files = []
        self.refresh_list()

        def work():
            items = []
            seen = set()
            err = None
            try:
                if len(targets) == 1:
                    batch = ds_items_for_product(targets[0])
                    items.extend(batch)
                else:
                    with ThreadPoolExecutor(max_workers=8) as pool:
                        futs = [pool.submit(ds_items_for_product, prod) for prod in targets]
                        done = 0
                        total = len(futs)
                        for fut in as_completed(futs):
                            done += 1
                            try:
                                batch = fut.result() or []
                            except Exception:
                                batch = []
                            for it in batch:
                                key = ds_dedupe_key(it.get("download_url") or it.get("filename") or "")
                                if key in seen:
                                    continue
                                seen.add(key)
                                items.append(it)
                            self.after(0, lambda d=done, t=total: self.status.set(f"데이터시트 항목 분석 중... ({d}/{t})"))
            except Exception as exc:
                err = str(exc)
            self.after(0, lambda: self._files_done(items, err))

        threading.Thread(target=work, daemon=True).start()

    def _files_done(self, items, err):
        self.files = items
        self.select_all = False
        self.refresh_list()
        if err:
            self.status.set(f"데이터시트 목록 실패: {err}")
        else:
            self.status.set(f"총 {len(items)}개 데이터시트 항목 파싱 완료.")

    def refresh_list(self):
        q = (self.ent_search.get() or "").lower()
        self.tree.delete(*self.tree.get_children())
        for i, item in enumerate(self.files):
            blob = f"{item.get('filename','')} {item.get('title','')}".lower()
            if q and q not in blob:
                continue
            img = self.img_on if item.get("checked") else self.img_off
            self.tree.insert("", "end", iid=str(i), image=img, values=(item.get("filename", ""), item.get("size", ""), item.get("title", "")))

    def on_tree_click(self, event):
        row = self.tree.identify_row(event.y)
        col = self.tree.identify_column(event.x)
        if not row:
            return
        if col == "#0":
            idx = int(row)
            if 0 <= idx < len(self.files):
                self.files[idx]["checked"] = not self.files[idx].get("checked")
                self.tree.item(row, image=self.img_on if self.files[idx]["checked"] else self.img_off)
            return "break"

    def toggle_select_all(self):
        self.select_all = not self.select_all
        for item in self.files:
            item["checked"] = self.select_all
        self.refresh_list()

    def open_datasheet_folder(self):
        open_save_folder(DS_SAVE_DIR)

    def on_download(self):
        chosen = [f for f in self.files if f.get("checked")]
        if not chosen:
            messagebox.showwarning("알림", "다운로드할 데이터시트를 선택하세요.")
            return
        for f in chosen:
            folder = f.get("product_folder") or "Unknown"
            dest = DS_SAVE_DIR / folder
            dest.mkdir(parents=True, exist_ok=True)
            f["dest_dir"] = dest
        win = DatasheetProgressWindow(self, chosen, chosen[0]["dest_dir"])
        self.wait_window(win)
        cancelled = any(st.get("status") == "중지됨" for _, st in getattr(win, "jobs", []))
        if cancelled:
            messagebox.showinfo("알림", "사용자에 의해 다운로드가 중단되었습니다.")
        else:
            messagebox.showinfo("완료", "선택한 모든 파일의 다운로드 작업이 완료되었습니다.")



class UnifiedApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"Ruckus_All_Downloader {VERSION}")
        self.geometry("980x500")
        self.minsize(980, 500)
        self.resizable(False, False)
        self.configure(bg="#F0F0F0")
        self.fw_win = None
        self.doc_win = None
        self.ds_win = None
        (APP_DIR / "firmware").mkdir(parents=True, exist_ok=True)
        (APP_DIR / "document").mkdir(parents=True, exist_ok=True)
        DS_SAVE_DIR.mkdir(parents=True, exist_ok=True)
        self._build()
        self.after(100, self.refresh_session)
        if gh_updater:
            self.after(400, self._silent_update_check)

    def _win_button(self, parent, text, command, bg="#F0F0F0", bold=False):
        font = ("맑은 고딕", 9, "bold") if bold else ("맑은 고딕", 9)
        return tk.Button(
            parent, text=text, command=command, bg=bg, activebackground=bg,
            fg="#000000", font=font, relief="raised", bd=1,
            highlightthickness=0, cursor="hand2",
        )

    def _big_btn(self, parent, text, command, bg="#1A6CC8"):
        return tk.Button(
            parent, text=text, command=command, bg=bg, activebackground=bg,
            fg="white", activeforeground="white", font=("맑은 고딕", 13, "bold"),
            relief="raised", bd=1, cursor="hand2",
        )

    def set_session_label(self, text, ok=None):
        self.lbl_session["text"] = text
        if ok is True:
            self.lbl_session["fg"] = "green"
        elif ok is False:
            self.lbl_session["fg"] = "red"
        else:
            self.lbl_session["fg"] = "#333333"

    def session_ok(self):
        return check_cookie_status() == 2

    def refresh_session(self):
        code = check_cookie_status()
        if code == 2:
            self.set_session_label("세션 : 유효함", True)
            self.status.set("쿠키가 유효합니다. 펌웨어 또는 문서 다운로드를 선택할 수 있습니다.")
        elif code == 1:
            self.set_session_label("세션 : 쿠키 삭제후 로그인", False)
            self.status.set("쿠키가 만료되었습니다. 쿠키 삭제후 로그인을 다시 진행해주세요.")
        else:
            self.set_session_label("세션 : 쿠키없음. 로그인", False)
            self.status.set("계정 정보를 입력하고 로그인을 진행해주세요.")

    def _build(self):
        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            try:
                style.theme_use("clam")
            except tk.TclError:
                pass
        style.configure("Status.TLabel", background="#F0F0F0", font=("맑은 고딕", 9))
        tk.Label(
            self, text="Ruckus_All_Downloader", bg="#F0F0F0", fg="#222222",
            font=("맑은 고딕", 16, "bold"),
        ).place(x=20, y=12, width=940, height=30)

        upd = tk.Frame(self, bg="#F0F0F0")
        upd.place(x=20, y=46, width=940, height=30)
        self._win_button(upd, "업데이트 확인", self.on_check_update).pack(side="left")
        self.lbl_upd = tk.Label(upd, text="", bg="#F0F0F0", fg="#666666", font=("맑은 고딕", 9), anchor="w")
        self.lbl_upd.pack(side="left", padx=10)
        self.btn_apply_upd = tk.Button(
            upd, text="업데이트", command=self._do_update,
            bg="#d9534f", activebackground="#c9302c", fg="white", activeforeground="white",
            font=("맑은 고딕", 9, "bold"), relief="flat", bd=0, padx=12, pady=2, cursor="hand2",
        )

        g1 = ttk.LabelFrame(self, text=" Ruckus Support 사이트 계정 로그인 ")
        g1.place(x=20, y=82, width=940, height=70)
        ttk.Label(g1, text="Email:").place(x=15, y=18)
        self.ent_user = ttk.Entry(g1, font=("맑은 고딕", 9))
        self.ent_user.place(x=65, y=16, width=200, height=23)
        self.ent_user.insert(0, os.environ.get("RUCKUS_USER", ""))
        ttk.Label(g1, text="PW:").place(x=275, y=18)
        self.ent_pass = ttk.Entry(g1, show="*", font=("맑은 고딕", 9))
        self.ent_pass.place(x=310, y=16, width=150, height=23)
        self.ent_pass.insert(0, os.environ.get("RUCKUS_PASS", ""))
        self._win_button(g1, "로그인 및 세션 갱신", self.on_login).place(x=475, y=15, width=140, height=27)
        self._win_button(g1, "쿠키 삭제", self.on_clear_cookie).place(x=625, y=15, width=85, height=27)
        self.lbl_session = tk.Label(g1, text="세션 : 확인 중...", bg="#F0F0F0", font=("맑은 고딕", 9), anchor="w")
        self.lbl_session.place(x=720, y=18, width=200, height=22)

        self._big_btn(self, "펌웨어 다운로드", self.open_firmware).place(x=90, y=175, width=380, height=52)
        self._big_btn(self, "문서 다운로드", self.open_document, bg="#2e7d32").place(x=510, y=175, width=380, height=52)
        self._big_btn(self, "데이터시트 다운로드", self.open_datasheet, bg="#6f42c1").place(x=90, y=240, width=800, height=52)
        self.status = tk.StringVar(value="준비 완료.")
        bar = tk.Frame(self, bg="#F0F0F0", relief="sunken", bd=1)
        bar.place(x=0, y=476, width=980, height=24)
        ttk.Label(bar, textvariable=self.status, style="Status.TLabel", anchor="w").pack(fill="x", padx=8)

    def _alive(self, win):
        try:
            return win is not None and win.winfo_exists()
        except tk.TclError:
            return False

    def open_firmware(self):
        if not self.session_ok():
            messagebox.showwarning("알림", "로그인 및 세션 갱신을 먼저 진행하세요.")
            return
        if self._alive(self.fw_win):
            self.fw_win.lift()
            self.fw_win.focus_force()
            return
        self.fw_win = FirmwareApp(self)
        self.fw_win.protocol("WM_DELETE_WINDOW", lambda: self._close("fw"))

    def open_document(self):
        if not self.session_ok():
            messagebox.showwarning("알림", "로그인 및 세션 갱신을 먼저 진행하세요.")
            return
        if self._alive(self.doc_win):
            self.doc_win.lift()
            self.doc_win.focus_force()
            return
        self.doc_win = DocumentApp(self)
        self.doc_win.protocol("WM_DELETE_WINDOW", lambda: self._close("doc"))

    def open_datasheet(self):
        if not self.session_ok():
            messagebox.showwarning("알림", "로그인 및 세션 갱신을 먼저 진행하세요.")
            return
        if self._alive(self.ds_win):
            self.ds_win.lift()
            self.ds_win.focus_force()
            return
        self.ds_win = DatasheetApp(self)
        self.ds_win.protocol("WM_DELETE_WINDOW", lambda: self._close("ds"))

    def _close(self, which):
        win = {"fw": self.fw_win, "doc": self.doc_win, "ds": getattr(self, "ds_win", None)}.get(which)
        if self._alive(win):
            win.destroy()
        if which == "fw":
            self.fw_win = None
        elif which == "doc":
            self.doc_win = None
        else:
            self.ds_win = None

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
                ok = load_cookie_module().export_wget_cookies(user, pw, str(COOKIE_FILE))
            except Exception:
                ok = False
            self.after(0, lambda: self._login_done(ok))

        threading.Thread(target=work, daemon=True).start()

    def _login_done(self, ok):
        if ok and cookie_valid():
            self.set_session_label("세션: 유효함 (성공)", True)
            self.status.set("로그인 성공!")
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
        self.set_session_label("세션: 쿠키 없음", False)
        self.status.set("쿠키를 삭제했습니다. 다시 로그인하세요.")

    def _silent_update_check(self):
        threading.Thread(target=self._check_update_worker, args=(False,), daemon=True).start()

    def on_check_update(self):
        if not gh_updater:
            self.lbl_upd["text"] = "updater.py 가 없습니다."
            return
        self.lbl_upd["text"] = "업데이트 확인 중..."
        threading.Thread(target=self._check_update_worker, args=(True,), daemon=True).start()

    def _check_update_worker(self, prompt):
        if not gh_updater:
            return
        frozen = bool(getattr(sys, "frozen", False))
        info = gh_updater.check_update(
            APP_DIR, frozen=frozen, current_version=VERSION,
            exe_path=sys.executable if frozen else "",
        )
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
        if not gh_updater:
            return
        info = getattr(self, "_update_info", None) or {}
        frozen = bool(getattr(sys, "frozen", False))
        self.lbl_upd["text"] = "업데이트 받는 중..."
        self._set_apply_visible(False)

        def work():
            result = gh_updater.apply_update(
                APP_DIR, frozen=frozen,
                exe_path=sys.executable if frozen else "",
                info=info, expected_sha=info.get("remote") or "",
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


def main():
    UnifiedApp().mainloop()


if __name__ == "__main__":
    main()
