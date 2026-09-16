#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
cp scripts/IconGenerator.swift "$stage/main.swift"
swiftc -target arm64-apple-macos26.0 Sources/AgentMeterApp/Appearance.swift "$stage/main.swift" -o "$stage/render-icon"
"$stage/render-icon" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o Resources/AppIcon.icns
