# Optional zsh integration. Source once, after any existing Codex wrappers.
# Every invocation reads Agent Meter's current selection, including in existing shells.
function _agent_meter_cli() {
  local meter_cli
  if [[ -n "${AGENT_METER_CLI:-}" ]]; then
    [[ -x "$AGENT_METER_CLI" ]] || { print -u2 -- 'AGENT_METER_CLI 不可执行。'; return 127; }
    print -r -- "$AGENT_METER_CLI"; return
  fi
  for meter_cli in \
    "$HOME/Applications/Agent Meter Preview.app/Contents/MacOS/agent-meter" \
    "/Applications/Agent Meter Preview.app/Contents/MacOS/agent-meter"; do
    if [[ -x "$meter_cli" ]]; then print -r -- "$meter_cli"; return; fi
  done
  meter_cli="$(whence -p agent-meter)"
  if [[ -n "$meter_cli" && -x "$meter_cli" ]]; then print -r -- "$meter_cli"; return; fi
  print -u2 -- '未找到 Agent Meter；请重新安装应用。'
  return 127
}
function codex() {
  local meter_cli
  meter_cli="$(_agent_meter_cli)" || return $?
  "$meter_cli" run -- "$@"
}

# Preserve explicit a/b shortcuts for users of the older profile switcher.
# They choose a profile for this invocation; plain codex follows the app selection.
if (( $+functions[_codex_home_for] )); then
  function cxa() {
    local meter_cli profile_home
    meter_cli="$(_agent_meter_cli)" || return $?
    profile_home="$(_codex_home_for a)" || return $?
    "$meter_cli" run --profile "$profile_home" -- "$@"
  }
  function cxb() {
    local meter_cli profile_home
    meter_cli="$(_agent_meter_cli)" || return $?
    profile_home="$(_codex_home_for b)" || return $?
    "$meter_cli" run --profile "$profile_home" -- "$@"
  }
fi
