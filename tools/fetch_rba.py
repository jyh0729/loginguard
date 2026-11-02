"""RBA 로그인 데이터셋을 받아 앞에서부터 N행만 CSV로 저장한다 (서버에서 직접 실행).

압축 파일(약 1.1GB) 안의 CSV 전체(약 9GB)를 풀지 않고, 압축을 읽으면서 필요한 행만 꺼낸다.
그래서 디스크를 적게 쓰고 빠르다. 표준 라이브러리만 사용.

  python tools/fetch_rba.py --rows 2000000 --out data/rba.csv
"""
from __future__ import annotations

import argparse
import io
import os
import shutil
import sys
import time
import urllib.request
import zipfile

URL = "https://zenodo.org/records/6782156/files/rba-dataset.zip?download=1"


def download(url: str, dest: str):
    t0 = time.time()
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        done = 0
        while chunk := r.read(8 * 1024 * 1024):
            f.write(chunk)
            done += len(chunk)
            if total:
                print(f"\r[fetch] {done / 1e6:,.0f} / {total / 1e6:,.0f} MB", end="", file=sys.stderr, flush=True)
    print(f"\n[fetch] 다운로드 {time.time() - t0:.0f}초", file=sys.stderr)


def extract_head(zip_path: str, out: str, rows: int):
    with zipfile.ZipFile(zip_path) as z:
        name = next(n for n in z.namelist() if n.endswith(".csv"))
        with z.open(name) as src, open(out, "w", encoding="utf-8", newline="") as dst:
            text = io.TextIOWrapper(src, encoding="utf-8", newline="")
            dst.write(text.readline())                      # 헤더
            for i, line in enumerate(text):
                if i >= rows:
                    break
                dst.write(line)
    print(f"[fetch] {name} 앞 {rows:,}행 → {out}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=2_000_000)
    ap.add_argument("--out", default="data/rba.csv")
    ap.add_argument("--url", default=os.getenv("RBA_URL", URL))
    ap.add_argument("--keep-zip", action="store_true")
    a = ap.parse_args()
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    zip_path = a.out + ".zip"
    if a.url.startswith("file://"):
        shutil.copy(a.url[7:], zip_path)
    else:
        download(a.url, zip_path)
    extract_head(zip_path, a.out, a.rows)
    if not a.keep_zip:
        os.remove(zip_path)


if __name__ == "__main__":
    main()
