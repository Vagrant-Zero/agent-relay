#!/usr/bin/env python3
"""Observe an isolated desktop test without recording credentials or raw RPC."""

import hashlib
import json
import os
import select
import signal
import subprocess
import sys
import threading
import time


REAL_CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex"
METHODS = {"initialize", "account/read", "account/rateLimits/read", "getAuthStatus"}


def fingerprint(value):
    if not value:
        return None
    return hashlib.sha256(str(value).encode()).hexdigest()[:12]


def main():
    if "app-server" not in sys.argv[1:]:
        os.execv(REAL_CODEX, [REAL_CODEX, *sys.argv[1:]])

    trace_path = os.environ["AGENT_METER_VERIFY_TRACE"]
    trace_lock = threading.Lock()
    request_lock = threading.Lock()
    pending = {}

    def record(event, **fields):
        item = {"event": event, "time": time.time(), "probe_pid": os.getpid(), **fields}
        line = (json.dumps(item, ensure_ascii=False) + "\n").encode()
        with trace_lock:
            fd = os.open(trace_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.write(fd, line)
            finally:
                os.close(fd)

    child = subprocess.Popen(
        [REAL_CODEX, *sys.argv[1:]],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr.buffer,
        bufsize=0,
    )
    record("spawn", child_pid=child.pid, codex_home=os.environ.get("CODEX_HOME"))

    def stop(_signum, _frame):
        if child.poll() is None:
            child.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    stopping = threading.Event()

    def input_lines():
        # Never leave a daemon thread holding sys.stdin.buffer's lock during
        # interpreter shutdown (Python aborts instead of completing finalization).
        pending_input = bytearray()
        while not stopping.is_set():
            if not select.select([sys.stdin.fileno()], [], [], 0.2)[0]:
                continue
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                if pending_input:
                    yield bytes(pending_input)
                return
            pending_input.extend(chunk)
            while b'\n' in pending_input:
                line, _, rest = pending_input.partition(b'\n')
                pending_input = bytearray(rest)
                yield bytes(line) + b'\n'

    def forward_requests():
        try:
            for line in input_lines():
                try:
                    message = json.loads(line)
                    method = message.get("method")
                    request_id = message.get("id")
                    if method in METHODS and request_id is not None:
                        with request_lock:
                            pending[str(request_id)] = method
                        record("request", method=method)
                except (ValueError, AttributeError):
                    pass
                remaining = memoryview(line)
                while remaining:
                    written = os.write(child.stdin.fileno(), remaining)
                    remaining = remaining[written:]
        except (BrokenPipeError, OSError):
            pass
        finally:
            try:
                child.stdin.close()
            except OSError:
                pass

    reader = threading.Thread(target=forward_requests, daemon=True)
    reader.start()
    try:
        for line in child.stdout:
            try:
                message = json.loads(line)
                with request_lock:
                    method = pending.pop(str(message.get("id")), None)
                if method:
                    result = message.get("result") or {}
                    if "error" in message:
                        record("response", method=method, success=False,
                               error_code=(message.get("error") or {}).get("code"))
                    elif method == "account/read":
                        account = result.get("account") or {}
                        record("response", method=method, success=True,
                               account_type=account.get("type"),
                               email_fingerprint=fingerprint(account.get("email")),
                               plan=account.get("planType"))
                    elif method == "account/rateLimits/read":
                        record("response", method=method, success=True,
                               account_fingerprint=fingerprint(result.get("accountId")),
                               limits_present=bool(result.get("rateLimits")),
                               reset_credits_present=result.get("rateLimitResetCredits") is not None)
                    elif method == "getAuthStatus":
                        record("response", method=method, success=True,
                               auth_method=result.get("authMethod"))
                    else:
                        record("response", method=method, success=True)
            except (ValueError, AttributeError):
                pass
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
    except BrokenPipeError:
        stop(None, None)
    finally:
        stopping.set()
        try:
            code = child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            code = child.wait()
        reader.join(timeout=3)
        record("exit", child_pid=child.pid, exit_code=code)


if __name__ == "__main__":
    main()
