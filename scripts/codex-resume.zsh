# Source after the existing cx/cxa/cxb definitions.
# Authentication follows the chosen account; resume locates the original history.
codex() {
  local profile_home
  profile_home="$(_codex_home_for "$CODEX_PROFILE")" || return 1
  local meter_cli="$HOME/Applications/Agent Meter Preview.app/Contents/MacOS/agent-meter"
  if [[ ! -x "$meter_cli" ]]; then
    print -u2 -- "Agent Meter 未安装，无法保证跨账号恢复。请重新安装。"
    return 1
  fi
  "$meter_cli" run --profile "$profile_home" -- "$@"
}
