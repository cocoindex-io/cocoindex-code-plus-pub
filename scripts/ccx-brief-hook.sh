#!/bin/sh
# The ccx plugin's prompt brief (specs: cocoindex-code-plus
# specs/product/cli/prompt_brief.md). On UserPromptSubmit, `ccx brief
# --claude-hook` names the code the task most likely touches and the changes
# it names, in about 3 KB, from one server call (POST /code/v0/brief) that
# answers in about 0.4 s, within about 1.5 s at most; a brief not ready by
# then is left for the agent's next tool call, and this script's PreToolUse
# entry delivers it. That entry runs at every tool call, so it starts the CLI
# only when a brief is waiting for this agent, or when the call is an Agent
# (Task) call: then the CLI appends a brief of the subagent's own task to the
# prompt it hands the subagent (`updatedInput`; a subagent never gets
# UserPromptSubmit), reading for up to 2 s. CCX_BRIEF=0 turns every brief
# off, CCX_SUBAGENT_BRIEF=0 the subagent's alone. It always exits 0 and
# prints nothing on failure: a prompt hook must never hold up or fail a
# prompt, nor a subagent's start.
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
    # Where the agent works: the next prompt's brief reads the checkout most
    # of its recent paths are in, not only the session's folder.
    tool=$(field tool_name)
    case "$tool" in
      Read | Edit | MultiEdit | Write | NotebookEdit) touched=$(field file_path) ;;
      Bash)
        touched=$(printf '%s' "$input" | grep -o 'cd[[:space:]][[:space:]]*/[^ ;&|"\\]*' | head -n 1 | sed 's/^cd[[:space:]]*//')
        ;;
      *) touched= ;;
    esac
    case "$touched" in
      /*)
        worked="${pending%.pending}.paths"
        mkdir -p "${worked%/*}" 2>/dev/null
        printf '%s\n' "$touched" >>"$worked" 2>/dev/null
        if [ "$(wc -c <"$worked" 2>/dev/null || echo 0)" -gt 65536 ]; then
          tail -n 32 "$worked" >"$worked.tmp" 2>/dev/null && mv "$worked.tmp" "$worked"
        fi
        ;;
    esac
    case "$tool" in
      Agent | Task)
        case "${CCX_SUBAGENT_BRIEF:-}" in
          0 | off | false | no | OFF | False | NO) [ -e "$pending" ] || exit 0 ;;
        esac
        ;;
      *) [ -e "$pending" ] || exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
command -v ccx >/dev/null 2>&1 || exit 0
# An older CLI has no `brief` command: its usage error goes to /dev/null.
printf '%s' "$input" | ccx brief --claude-hook 2>/dev/null
exit 0
