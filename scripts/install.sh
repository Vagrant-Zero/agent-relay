#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="$PWD/dist/Agent Meter Preview.app"
installed_app="$HOME/Applications/Agent Meter Preview.app"
cli_link="$HOME/.local/bin/agent-meter"
if [[ ! -d "$source_app" ]]; then
  print -u2 -- '请先运行 ./scripts/build.sh'
  exit 1
fi
if [[ -e "$cli_link" && ! -L "$cli_link" ]]; then
  print -u2 -- "已有其他可执行文件：$cli_link；请先选择不同的安装位置。"
  exit 1
fi
if [[ -L "$cli_link" && "$(readlink "$cli_link")" != "$installed_app/Contents/MacOS/agent-meter" ]]; then
  print -u2 -- "已有其他命令链接：$cli_link；未覆盖。"
  exit 1
fi
if [[ -e "$installed_app" ]]; then
  existing_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed_app/Contents/Info.plist")"
  if [[ "$existing_id" != 'dev.local.agent-meter.preview' ]]; then
    print -u2 -- '目标位置属于其他应用，未覆盖。'
    exit 1
  fi
fi
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
install_stage="$(mktemp -d "$HOME/Applications/.agent-meter-install.XXXXXX")"
trap 'rm -rf "$install_stage"' EXIT
/usr/bin/ditto "$source_app" "$install_stage/Agent Meter Preview.app"
codesign --verify --deep --strict "$install_stage/Agent Meter Preview.app"
if [[ -e "$installed_app" ]]; then
  mv "$installed_app" "$install_stage/previous.app"
fi
mv "$install_stage/Agent Meter Preview.app" "$installed_app"
ln -sfn "$installed_app/Contents/MacOS/agent-meter" "$cli_link"
print -r -- "已安装：$installed_app"
print -r -- "CLI：$cli_link"
print -r -- '若 agent-meter 不在 PATH 中，可使用上面的完整路径。'
