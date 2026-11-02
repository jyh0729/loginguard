"""SSH 수집기 로그 파싱 테스트 (실제 sshd 로그 형식)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deploy"))
from ssh_collector import parse  # noqa: E402


def test_invalid_user():
    assert parse("Invalid user admin from 45.135.232.10 port 51234") == {"user": "admin", "ip": "45.135.232.10", "success": False}


def test_failed_password_and_preauth():
    assert parse("Failed password for invalid user oracle from 103.20.1.7 port 40022 ssh2")["user"] == "oracle"
    assert parse("Failed password for root from 103.20.1.7 port 40022 ssh2")["user"] == "root"
    r = parse("Connection closed by authenticating user root 218.92.0.11 port 33012 [preauth]")
    assert r == {"user": "root", "ip": "218.92.0.11", "success": False}


def test_accepted_and_ipv6():
    assert parse("Accepted publickey for ec2-user from 2001:db8::5 port 5022 ssh2: ED25519 SHA256:x") == \
        {"user": "ec2-user", "ip": "2001:db8::5", "success": True}


def test_noise_ignored():
    for line in ["Received disconnect from 1.2.3.4 port 22:11: Bye Bye [preauth]",
                 "Disconnected from invalid user admin 1.2.3.4 port 5555 [preauth]",
                 "Server listening on 0.0.0.0 port 22."]:
        assert parse(line) is None
