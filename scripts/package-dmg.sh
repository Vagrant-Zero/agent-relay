#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_dir="$PWD/dist/Agent Relay.app"
[[ -d "$app_dir" ]] || { print -u2 -- '请先运行 ./scripts/build.sh'; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
for binary in AgentRelay agent-relay agent-relay-bridge; do
  [[ "$(lipo -archs "$app_dir/Contents/MacOS/$binary")" == arm64 ]] || { print -u2 -- '发布包必须只包含 arm64'; exit 1; }
done
codesign --verify --deep --strict "$app_dir"
stage="$(mktemp -d "$PWD/dist/.dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/content"
ditto "$app_dir" "$stage/content/Agent Relay.app"
ln -s /Applications "$stage/content/Applications"
cat > "$stage/content/安装说明.txt" <<'TXT'
Agent Relay · macOS 26+ · Apple Silicon

将 Agent Relay.app 拖到 Applications 后打开。
这是采用临时签名的未公证预览版。首次打开若被系统阻止，请在
“系统设置 → 隐私与安全性”中核对应用来源后选择“仍要打开”。
无需关闭系统安全保护。

使用账号功能需要另外安装并登录官方 Codex CLI。
桌面账号切换还需要受支持版本的官方 Codex 应用；具体范围见项目 README。
TXT
filename="Agent-Relay-$version-macos-arm64.dmg"
hdiutil create -volname 'Agent Relay' -srcfolder "$stage/content" -format UDZO "$stage/$filename"
hdiutil verify "$stage/$filename"
mv -f "$stage/$filename" "dist/$filename"
(cd dist && shasum -a 256 "$filename" > "$filename.sha256")
print -r -- "$PWD/dist/$filename"
