#!/usr/bin/env python3
"""Read account identity and quota through the official CLI; emit no tokens."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import selectors
import subprocess
import time

from verify_desktop_profiles import expected_identity, fingerprint


def check(profile):
    profile = profile.expanduser().resolve()
    expected = expected_identity(profile)
    env = dict(os.environ)
    for key in ("CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY"):
        env.pop(key, None)
    env["CODEX_HOME"] = str(profile)
    proc = subprocess.Popen(["/opt/homebrew/bin/codex", "app-server"], env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    buffer = b""
    inbox = []

    def send(message):
        proc.stdin.write((json.dumps(message) + "\n").encode())
        proc.stdin.flush()

    def response(request_id):
        nonlocal buffer
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            while inbox:
                message = inbox.pop(0)
                if message.get("id") == request_id:
                    return message
            if not selector.select(timeout=0.2):
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Official app server exited before replying")
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if line:
                    inbox.append(json.loads(line))
        raise TimeoutError("Official app server did not reply within 25 seconds")

    try:
        send({"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "agent_meter_verification", "version": "0.0.0"}}})
        response(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "account/read", "params": {"refreshToken": False}})
        account_response = response(2)
        account = (account_response.get("result") or {}).get("account") or {}
        send({"id": 3, "method": "account/rateLimits/read"})
        limits_response = response(3)
        limits = limits_response.get("result") or {}
        return {
            "profile": profile.name,
            "cli_identity_matches": fingerprint(account.get("email")) == expected["email_fingerprint"],
            "quota_request_succeeded": "result" in limits_response,
            "quota_account_matches": fingerprint(limits.get("accountId")) == expected["account_fingerprint"],
            "rate_limits_present": bool(limits.get("rateLimits")),
            "reset_credit_count_available": (limits.get("rateLimitResetCredits") or {}).get("availableCount") is not None,
            "error_code": (limits_response.get("error") or {}).get("code"),
        }
    finally:
        selector.close()
        proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("profiles", nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(check, args.profiles))
    output = json.dumps(results, indent=2) + "\n"
    if args.output:
        args.output.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
