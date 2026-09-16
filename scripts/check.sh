#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_python="${METER_TEST_PYTHON:-python3}"
"$test_python" -c 'import sys; assert sys.version_info >= (3, 11), "Tests require Python 3.11+; set METER_TEST_PYTHON"'
product_dir="$(swift build -c release --arch arm64 --show-bin-path)"
"$product_dir/AgentMeterChecks"
"$test_python" verification/test_cli.py
"$test_python" verification/test_quota_layout.py
"$test_python" verification/test_quit.py
"$test_python" verification/test_auto_refresh.py
"$test_python" verification/test_native_bridge.py
METER_TEST_CLI="$PWD/dist/Agent Relay.app/Contents/MacOS/agent-relay" "$test_python" verification/test_sessions.py
check_dir="$(mktemp -d)"
trap 'rm -rf "$check_dir"' EXIT
cp verification/appearance_checks.swift "$check_dir/main.swift"
swiftc -target arm64-apple-macos26.0 Sources/AgentMeterApp/Appearance.swift "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
