#!/bin/sh
# The ccx plugin's one hook. Claude Code runs it at an agent's repository
# searches (PreToolUse and PostToolUse on Grep, grep, rg, git grep) and when a
# session or subagent starts. It reads the hook event on stdin and prints at
# most one line of context, as JSON, when the checkout is indexed in ccx.
#
# Division of labour: this script only keeps the per-agent markers that make
# each kind of hint fire once per agent (Claude Code's `once` applies to skill
# hooks only), and leaves every judgement to `ccx indexed --claude-hook`: the
# CLI owns the server, the credential, the cache and the wording. It always
# exits 0: a hook that fails must never interrupt the agent.
set -u

input=$(cat)
field() {
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}
event=$(field hook_event_name)
session=$(field session_id)
agent=$(field agent_id)
source=$(field source)
[ -n "$event" ] || exit 0

case "$event" in
  PreToolUse) kind=grep ;;
  PostToolUse) kind=result ;;
  SessionStart) kind=start ;;
  SubagentStart) kind=subagent_start ;;
  *) exit 0 ;;
esac

state="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/ccx-claude-hook}/markers"
mkdir -p "$state" 2>/dev/null || exit 0
prefix="$state/${session:-nosession}-${agent:-main}"

# Compaction summarises earlier context away and /clear empties it: let
# every hint fire again.
if [ "$event" = SessionStart ] && { [ "$source" = compact ] || [ "$source" = clear ]; }; then
  rm -f "$state/${session:-nosession}-"* 2>/dev/null
fi

marker="$prefix-$kind"
[ -e "$marker" ] && exit 0
# "Could not tell" (server down, not logged in) is retried after five minutes,
# not at every search.
retry="$prefix-retry"
if [ -e "$retry" ] && [ -n "$(find "$retry" -mmin -5 2>/dev/null)" ]; then
  exit 0
fi

command -v ccx >/dev/null 2>&1 || exit 0
output=$(printf '%s' "$input" | ccx indexed --claude-hook 2>/dev/null)
status=$?
case "$status" in
  0)
    # Indexed. Output means this moment earned its hint; silence means it did
    # not (a normal result), and the next such moment may.
    if [ -n "$output" ]; then
      reported_kind=$(printf '%s' "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
      case "$reported_kind" in
        indexing | grep | result | start | subagent_start) marker="$prefix-$reported_kind" ;;
        "") ;; # Older CLIs identify the kind by the event.
        *) ;; # Newer CLIs fall back to the event marker.
      esac
      # Claim this (agent, kind) once, even when tool hooks run in parallel.
      (set -C; : >"$marker") 2>/dev/null || exit 0
      printf '%s\n' "$output"
    fi
    ;;
  1)
    # Not indexed: final for this agent, whatever the event.
    for k in grep result start subagent_start indexing; do : >"$prefix-$k"; done
    ;;
  *)
    : >"$retry"
    ;;
esac
# Markers from sessions long gone.
find "$state" -type f -mmin +1440 -delete 2>/dev/null
exit 0
