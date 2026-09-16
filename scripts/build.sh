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
staging_dir="$(mktemp -d "$PWD/dist/.agent-meter-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/Agent Meter Preview.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $release_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $release_version" "$app_dir/Contents/Info.plist"
cp "$product_dir/AgentMeterPreview" "$app_dir/Contents/MacOS/AgentMeterPreview"
cp "$product_dir/agent-meter" "$app_dir/Contents/MacOS/agent-meter"
cp "$product_dir/agent-meter-bridge" "$app_dir/Contents/MacOS/agent-meter-bridge"
codesign --force --sign - "$app_dir/Contents/MacOS/agent-meter-bridge"
codesign --force --sign - "$app_dir/Contents/MacOS/agent-meter"
codesign --force --sign - "$app_dir"
final_app="$PWD/dist/Agent Meter Preview.app"
if [[ -e "$final_app" ]]; then
  mv "$final_app" "$staging_dir/previous.app"
fi
mv "$app_dir" "$final_app"
print -r -- "$final_app"
