#!/bin/sh
# The ccx plugin's prompt brief (specs: cocoindex-code-plus
# specs/product/cli/prompt_brief.md). On UserPromptSubmit, `ccx brief
# --claude-hook` names the code the task most likely touches and the changes
# it names, in about 3 KB, from one server call (POST /code/v0/brief) that
# answers in about 0.4 s, within about 1.5 s at most; a brief not ready by
# then is left for the agent's next tool call, and this script's PreToolUse
# entry delivers it. That entry runs at every tool call, so it starts the CLI
# only when a brief is waiting for this agent. CCX_BRIEF=0 turns it off. It
# always exits 0 and prints nothing on failure: a prompt hook must never
# hold up or fail a prompt.
set -u

case "${CCX_BRIEF:-}" in 0 | off | false | no | OFF | False | NO) exit 0 ;; esac
input=$(cat)
field() {
  printf '%s' "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1
}
event=$(field hook_event_name)
case "$event" in
  UserPromptSubmit) ;;
  PreToolUse)
    session=$(field session_id)
    agent=$(field agent_id)
    case "$session" in "" | *[!a-zA-Z0-9_-]*) exit 0 ;; esac
    case "$agent" in *[!a-zA-Z0-9_-]*) exit 0 ;; esac
    pending="${XDG_CACHE_HOME:-$HOME/.cache}/ccx/brief-state/$session-${agent:-main}.pending"
    [ -e "$pending" ] || exit 0
    ;;
  *) exit 0 ;;
esac
command -v ccx >/dev/null 2>&1 || exit 0
# An older CLI has no `brief` command: its usage error goes to /dev/null.
printf '%s' "$input" | ccx brief --claude-hook 2>/dev/null
exit 0
