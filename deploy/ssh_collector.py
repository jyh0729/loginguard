#!/usr/bin/env python3
"""EC2 서버에 실제로 들어오는 SSH 로그인 시도를 LoginGuard API로 보내는 수집기.

서버의 sshd 로그(journald)를 계속 읽다가 로그인 시도가 보이면
계정 이름·IP·성공/실패를 /predict 로 보낸다 → 관제 화면에 실시간으로 뜨고 판정·로그가 남는다.

  sudo python3 ssh_collector.py                 # journalctl -u sshd -f 를 읽음 (EC2)
  python3 ssh_collector.py --stdin < auth.log   # 테스트: 파일·표준입력에서 읽음

표준 라이브러리만 쓴다 (서버에 pip 설치 불필요). 비밀번호는 로그에도 없고 보내지도 않는다.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request

IP = r"(?P<ip>[0-9a-fA-F:.]+)"
PATTERNS = [  # (정규식, 성공 여부)
    (re.compile(rf"Invalid user (?P<user>\S*) from {IP} port \d+"), False),
    (re.compile(rf"Failed (?:password|publickey|none) for (?:invalid user )?(?P<user>\S+) from {IP} port \d+"), False),
    (re.compile(rf"Connection closed by authenticating user (?P<user>\S+) {IP} port \d+ \[preauth\]"), False),
    (re.compile(rf"Accepted (?:password|publickey|keyboard-interactive/pam) for (?P<user>\S+) from {IP} port \d+"), True),
]


def parse(line: str) -> dict | None:
    """sshd 로그 한 줄 → {'user', 'ip', 'success'} (로그인 시도가 아니면 None)"""
    for pat, ok in PATTERNS:
        m = pat.search(line)
        if m:
            return {"user": m.group("user") or "(empty)", "ip": m.group("ip"), "success": ok}
    return None


def send(api: str, ev: dict) -> dict | None:
    body = {"user_id": ev["user"][:128], "ip": ev["ip"], "country": "-", "asn": 0, "device_type": "unknown",
            "browser": "ssh", "os": "-", "success": ev["success"], "timestamp": time.time()}
    req = urllib.request.Request(api.rstrip("/") + "/predict", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except Exception as e:  # API가 아직 안 떴거나 잘못된 IP 형식 등: 한 건 버리고 계속
        print(f"[collector] 전송 실패 {ev}: {e}", file=sys.stderr, flush=True)
        return None


def lines(use_stdin: bool):
    if use_stdin:
        yield from sys.stdin
        return
    p = subprocess.Popen(["journalctl", "-u", "sshd", "-f", "-n", "0", "-o", "cat"],
                         stdout=subprocess.PIPE, text=True)
    yield from p.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://127.0.0.1:80")
    ap.add_argument("--stdin", action="store_true")
    a = ap.parse_args()
    print(f"[collector] 시작 → {a.api}", flush=True)
    for line in lines(a.stdin):
        ev = parse(line)
        if not ev:
            continue
        r = send(a.api, ev)
        if r:
            print(f"[collector] {ev['ip']} user={ev['user']} success={ev['success']} "
                  f"→ {r['decision']} ({r['risk_score']})", flush=True)


if __name__ == "__main__":
    main()
