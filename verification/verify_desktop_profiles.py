#!/usr/bin/env python3
"""Exercise the installed official desktop app with isolated UI state.

This is a compatibility probe, not the product's switching implementation.
It does not copy credentials or change the user's CLI profile selector.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


APP = Path("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
PROBE = Path(__file__).with_name("codex_stdio_probe.py").resolve()


def fingerprint(value):
    return hashlib.sha256(str(value).encode()).hexdigest()[:12] if value else None


def expected_identity(profile):
    auth_file = profile / "auth.json"
    if not auth_file.is_file():
        return {"email_fingerprint": None, "account_fingerprint": None,
                "name_fingerprint": None}
    auth = json.loads(auth_file.read_text())
    tokens = auth.get("tokens") or {}
    body = tokens["id_token"].split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    return {"email_fingerprint": fingerprint(claims.get("email")),
            "account_fingerprint": fingerprint(tokens.get("account_id")),
            "name_fingerprint": fingerprint(claims.get("name"))}


def events(path):
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except ValueError:
            pass
    return result


def run_cycle(root, profile, index, settle_seconds):
    expected = expected_identity(profile)
    run_key = "%s-%s" % (time.time_ns(), index)
    trace = root / ("trace-%s.jsonl" % run_key)
    stderr_path = root / ("desktop-%s.stderr" % run_key)
    env = dict(os.environ)
    for key in ("CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY",
                "CODEX_APP_SERVER_WS_URL", "ELECTRON_RUN_AS_NODE"):
        env.pop(key, None)
    env.update({
        "CODEX_HOME": str(profile),
        "CODEX_ELECTRON_USER_DATA_PATH": str(root / "app-data"),
        "CODEX_CLI_PATH": str(PROBE),
        "CODEX_APP_SERVER_FORCE_CLI": "1",
        "AGENT_METER_VERIFY_TRACE": str(trace),
    })
    stderr_fd = os.open(str(stderr_path), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    started = time.time()
    proc = subprocess.Popen(
        [str(APP), "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1"],
        cwd=str(root), env=env, stdin=subprocess.DEVNULL,
        stdout=stderr_fd, stderr=stderr_fd, start_new_session=True,
    )
    os.close(stderr_fd)
    print(json.dumps({"phase": "started", "profile": profile.name,
                      "pid": proc.pid, "trace": str(trace)}), flush=True)
    result = {"profile": profile.name, "desktop_pid": proc.pid,
              "expected": expected, "graceful_quit": False}
    try:
        matched_at = None
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline and proc.poll() is None:
            observed = events(trace)
            account_reads = [e for e in observed if e.get("method") == "account/read"
                             and e.get("event") == "response" and e.get("success")]
            if any(e.get("email_fingerprint") == expected["email_fingerprint"]
                   for e in account_reads):
                if matched_at is None:
                    matched_at = time.monotonic()
                if time.monotonic() - matched_at >= settle_seconds:
                    break
            time.sleep(0.2)
        observed = events(trace)
        spawns = [e for e in observed if e["event"] == "spawn"]
        reads = [e for e in observed if e.get("method") == "account/read"
                 and e["event"] == "response"]
        limits = [e for e in observed if e.get("method") == "account/rateLimits/read"
                  and e["event"] == "response"]
        result.update({
            "profile_directory_matches": bool(spawns) and all(
                e.get("codex_home") == str(profile) for e in spawns),
            "desktop_account_matches": any(e.get("success") and
                e.get("email_fingerprint") == expected["email_fingerprint"] for e in reads),
            "account_observations": reads,
            "rate_limit_observations": limits,
            "startup_seconds": round(time.time() - started, 2),
            "early_exit_code": proc.poll(),
        })
        if proc.poll() is None:
            ui = subprocess.run(["node", str(PROBE.with_name("desktop_ui_probe.mjs")),
                                 str(stderr_path)], capture_output=True, text=True, timeout=20)
            if ui.returncode == 0:
                result["ui_observations"] = json.loads(ui.stdout)
                result["ui_account_matches"] = any(
                    page.get("profileMenuOpened") and (
                        expected["email_fingerprint"] in page.get("emailFingerprints", [])
                        or (expected["name_fingerprint"] is not None and
                            expected["name_fingerprint"] == page.get("profileNameFingerprint")))
                    for page in result["ui_observations"])
            else:
                result["ui_inspection_failed"] = True
        print(json.dumps({"phase": "observed", "profile": result["profile"],
                          "desktop_account_matches": result.get("desktop_account_matches"),
                          "ui_account_matches": result.get("ui_account_matches"),
                          "profile_directory_matches": result.get("profile_directory_matches")}), flush=True)
    finally:
        if proc.poll() is None:
            quit_result = subprocess.run([str(root / "quit-app"), str(proc.pid)],
                                         capture_output=True, text=True, timeout=10)
            result["quit_request"] = quit_result.stdout.strip()
            try:
                proc.wait(timeout=15)
                result["graceful_quit"] = quit_result.stdout.strip() == "quit-requested"
            except subprocess.TimeoutExpired:
                result["quit_timed_out"] = True
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
        time.sleep(1)
        observed = events(trace)
        child_ids = {e["child_pid"] for e in observed if e["event"] == "spawn"}
        exited = {e["child_pid"] for e in observed if e["event"] == "exit"}
        result["app_server_exit_observed"] = bool(child_ids) and child_ids <= exited
        result["exit_code"] = proc.returncode
        (root / ("result-%s.json" % run_key)).write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"phase": "stopped", "profile": result["profile"],
                          "graceful_quit": result.get("graceful_quit"),
                          "app_server_exit_observed": result.get("app_server_exit_observed")}), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scratch", type=Path)
    parser.add_argument("--profiles", nargs="+", required=True, type=Path)
    parser.add_argument("--settle-seconds", type=float, default=5)
    args = parser.parse_args()
    if args.scratch is None:
        args.scratch = Path(tempfile.mkdtemp(prefix="agent-meter-desktop-verify-"))
    args.scratch.mkdir(mode=0o700, parents=True, exist_ok=True)
    (args.scratch / "app-data").mkdir(mode=0o700, exist_ok=True)
    if not (args.scratch / "quit-app").is_file():
        subprocess.run(["xcrun", "swiftc", str(PROBE.with_name("quit_app.swift")),
                        "-o", str(args.scratch / "quit-app")], check=True, timeout=60)
    results = []
    for index, profile in enumerate(args.profiles):
        result = run_cycle(args.scratch.resolve(), profile.expanduser().resolve(), index,
                           args.settle_seconds)
        results.append(result)
        if not result.get("desktop_account_matches") or not result.get("graceful_quit"):
            break
    (args.scratch / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    passed = len(results) == len(args.profiles) and all(
        r.get("profile_directory_matches") and r.get("desktop_account_matches")
        and r.get("graceful_quit") and r.get("app_server_exit_observed")
        and (r["expected"]["email_fingerprint"] is None or r.get("ui_account_matches"))
        for r in results)
    print(json.dumps({"passed": passed, "report": str(args.scratch / "results.json")}))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
