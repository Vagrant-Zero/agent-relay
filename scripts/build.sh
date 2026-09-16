#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export MACOSX_DEPLOYMENT_TARGET=26.0
release_version="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -- '版本号必须为 X.Y.Z'; exit 1
fi
swift build -c release --arch arm64
product_dir="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$PWD/dist"
staging_dir="$(mktemp -d "$PWD/dist/.agent-relay-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Agent Relay.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cp scripts/codex-resume.zsh "$app_dir/Contents/Resources/codex.zsh"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $release_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $release_version" "$app_dir/Contents/Info.plist"
cp "$product_dir/AgentRelay" "$app_dir/Contents/MacOS/AgentRelay"
cp "$product_dir/agent-relay" "$app_dir/Contents/MacOS/agent-relay"
cp "$product_dir/agent-relay-bridge" "$app_dir/Contents/MacOS/agent-relay-bridge"
codesign --force --sign - "$app_dir/Contents/MacOS/agent-relay-bridge"
codesign --force --sign - "$app_dir/Contents/MacOS/agent-relay"
codesign --force --sign - "$app_dir"
final_app="$PWD/dist/Agent Relay.app"
if [[ -e "$final_app" ]]; then
  mv "$final_app" "$staging_dir/previous.app"
fi
mv "$app_dir" "$final_app"
print -r -- "$final_app"
