#!/bin/sh
# The ccx plugin's one hook. Claude Code runs it at an agent's repository
# searches, direct source reads (sed, awk, head, tail, cat, Read), and session or
# subagent starts. It reads the hook event on stdin and prints at
# most one line of context, as JSON, when the checkout is indexed in ccx.
#
# Division of labour: this script only keeps the per-agent markers that make
# each kind of hint fire once per agent (Claude Code's `once` applies to skill
# hooks only), and leaves every judgement to `ccx indexed --claude-hook`: the
# CLI owns the server, the credential, the cache and the wording. A grep
# for one definition gets that definition after its output (kind
# definition, no marker; CCX_HOOK_DEFINITION=0 turns it off). Range reads
# and history lookups (kinds read, history, change) keep no marker: the CLI
# runs a Bash one as the ccx command that prints the same or more (an
# `allow` with `updatedInput`; CCX_HOOK_REWRITE=0 turns that off), as it
# runs a grep as `ccx grep --exact-as` where that prints the same lines,
# widens
# a windowed Read to the definitions it cuts (CCX_HOOK_WIDEN=0 turns that
# off), else
# blocks the first one of each kind per agent with the ccx command to run
# instead, allows it run again, and hints at every later one
# (CCX_HOOK_BLOCK=0 turns blocking off). It always exits 0: a hook that fails
# must never interrupt the agent.
#
# Codex runs it too (codex/hooks.json passes `codex`). Codex sends the same
# event shapes for its shell tool (`Bash`), but its hooks have no `if`: for
# Codex this script keeps the commands Claude Code's `if` entries match, and
# every compound command (the CLI parses its parts), and leaves the rest
# before the CLI starts.
set -u

host=${1:-claude}
input=$(cat)
field() {
  # Keep escaped JSON characters inside the value. A quoted directory in a
  # Bash command must not hide the shell expression that follows it.
  printf '%s' "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\(\\.[^"\\]*\)*\)".*/\1/p' | head -n 1
}
if [ "$host" = codex ] && [ "$(field tool_name)" = Bash ]; then
  case "$(field hook_event_name):$(field command)" in
    *:*'&'* | *:*'|'* | *:*';'* | *:*'$('* | *:*'`'* | *:*'\n'*) ;;
    *:grep\ * | *:rg\ * | *:git\ grep\ *) ;;
    PreToolUse:gh\ * | PreToolUse:git\ log\ * | PreToolUse:git\ -C\ *) ;;
    PreToolUse:sed\ * | PreToolUse:head\ * | PreToolUse:cat\ * | PreToolUse:awk\ * | PreToolUse:tail\ *) ;;
    *) exit 0 ;;
  esac
fi
event=$(field hook_event_name)
session=$(field session_id)
agent=$(field agent_id)
source=$(field source)
[ -n "$event" ] || exit 0
# IDs become file names and compaction glob prefixes. Reject path and glob syntax.
case "$session" in *[!a-zA-Z0-9_-]*) exit 0 ;; esac
case "$agent" in *[!a-zA-Z0-9_-]*) exit 0 ;; esac

# SessionStart's environment file reaches later Bash commands. Keep the
# observation cache separate for each Claude Code session, including resume.
if [ "$event" = SessionStart ] && [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$session" ]; then
  case "$session" in
    *[!a-zA-Z0-9_-]*) ;; # Never put untrusted shell syntax in the env file.
    *) printf "export CCX_SESSION_ID='%s'\n" "$session" >> "$CLAUDE_ENV_FILE" 2>/dev/null ;;
  esac
fi

case "$event" in
  PreToolUse)
    kind=grep
    tool_name=$(field tool_name)
    if [ "$tool_name" = Read ]; then
      kind=read
      # A windowed Read goes to the CLI at every call. A whole-file Read
      # earns one line only when the file is longer than the 2,000 lines
      # Read returns, once per file per session (kind read_whole, its
      # marker per file): counted here, so a short file never starts the CLI.
      case "$input" in
        *'"offset"'* | *'"limit"'*) ;;
        *)
          read_path=$(field file_path)
          [ -n "$read_path" ] && [ -f "$read_path" ] || exit 0
          read_lines=$(wc -l <"$read_path" 2>/dev/null) || exit 0
          [ "${read_lines:-0}" -gt 2000 ] 2>/dev/null || exit 0
          kind=read_whole
          whole_key=$(printf '%s' "$read_path" | cksum | cut -d' ' -f1)
          ;;
      esac
    fi
    # Keep the event marker separate for host-history commands. The CLI
    # classifies their exact command shape and reports the final kind.
    command_text=$(field command)
    case "$command_text" in
      gh\ *|git\ log\ *--grep*) kind=change ;;
      git\ -C\ *) kind=unknown ;;
      git\ log\ *) kind=history ;;
      sed\ *|head\ *|cat\ *|awk\ *|tail\ *) kind=read ;;
    esac
    # A shell expression may earn a different kind from its first command.
    # Do not let a guessed grep marker hide a later host-history search.
    # The CLI parses shell segments and claims the returned marker below.
    case "$command_text" in
      *'&'*|*'|'*|*';'*|*'$('*|*'`'*|*'\n'*) kind=unknown ;;
    esac
    ;;
  PostToolUse)
    kind=result
    # A grep for a definition may earn the definition at every call, after
    # the result hint is spent too: the CLI judges it (kind definition).
    case "$(field command)$(field pattern)" in
      *'fn '*|*'struct '*|*'enum '*|*'trait '*|*'type '*|*'const '*|*'static '*|*'mod '*|*'class '*|*'def '*|*'interface '*|*'function '*|*'union '*|*'macro_rules!'*|*'impl '*|*' ='*) definition=1 ;;
    esac
    ;;
  SessionStart) kind=start ;;
  SubagentStart) kind=subagent_start ;;
  *) exit 0 ;;
esac

state="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/ccx-claude-hook}/markers"
mkdir -p "$state" 2>/dev/null || exit 0

# Claude Code starts this script once per handler whose `if` matches a part
# of the command, and once per handler for a command it cannot split (a
# substitution, a loop): up to ten parallel runs of one tool call. The first
# run answers; the others exit before the CLI starts.
tool_use_id=$(field tool_use_id)
case "$event:$tool_use_id" in
  PreToolUse:?* | PostToolUse:?*)
    case "$tool_use_id" in
      *[!a-zA-Z0-9_-]*) ;;
      *) (set -C; : >"$state/call-$event-$tool_use_id") 2>/dev/null || exit 0 ;;
    esac
    ;;
esac
# Older scripts set all five hint markers after a 404. A new namespace
# leaves those final markers behind without confusing them with earned hints.
prefix="$state/${session:-nosession}-${agent:-main}-v2"

# Compaction summarises earlier context away and /clear empties it: let
# every hint fire again.
if [ "$event" = SessionStart ] && { [ "$source" = compact ] || [ "$source" = clear ]; }; then
  rm -f "$state/${session:-nosession}-"* 2>/dev/null
fi

marker="$prefix-$kind${whole_key:+-$whole_key}"
# Kinds the CLI answers at every call: no marker spends them. A grep it
# runs as ccx (grep_rewrite) is one; the grep hint stays once per agent.
every_call() {
  case "$1" in read | history | change | grep_rewrite | definition) return 0 ;; esac
  return 1
}
# A grep (`git grep` too) goes to the CLI at every call, so it can be rewritten
# (CCX_HOOK_REWRITE=0 turns that off); a spent hint is then not printed.
if [ "$kind" = grep ] && [ -e "$marker" ]; then
  case "${CCX_HOOK_REWRITE:-}" in 0 | off | false | no) exit 0 ;; esac
  case "$event:$command_text" in
    PreToolUse:grep\ * | PreToolUse:rg\ * | PreToolUse:git\ grep\ *) ;;
    *) exit 0 ;;
  esac
fi
if [ "$kind" != unknown ] && [ "$kind" != grep ] && ! every_call "$kind" && [ -e "$marker" ]; then
  # A spent result hint leaves only the definition to earn.
  [ "$kind" = result ] && [ -n "${definition:-}" ] || exit 0
  CCX_HOOK_RESULT_SPENT=1
  export CCX_HOOK_RESULT_SPENT
fi
# "Could not tell" (server down, not logged in) is retried after five minutes,
# not at every search.
retry="$prefix-retry"
if [ -e "$retry" ] && [ -n "$(find "$retry" -mmin -5 2>/dev/null)" ]; then
  exit 0
fi

# An absent repository may be added by the operator. Keep its retry window
# separate from the cannot-tell window.
absent_retry="$prefix-not-indexed-retry"
if [ -e "$absent_retry" ] && [ -n "$(find "$absent_retry" -mmin -15 2>/dev/null)" ]; then
  exit 0
fi

command -v ccx >/dev/null 2>&1 || exit 0
# CCX_HOOK_HOST tells the CLI which agent's words to use (how to wait for
# `ccx ask` differs between Claude Code and Codex).
output=$(printf '%s' "$input" | CCX_HOOK_HOST="$host" ccx indexed --claude-hook 2>/dev/null)
status=$?
case "$status" in
  0)
    # Indexed. Output means this moment earned its hint; silence means it did
    # not (a normal result), and the next such moment may.
    if [ -n "$output" ]; then
      reported_kind=$(printf '%s' "$output" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
      case "$reported_kind" in
        indexing | grep | result | start | subagent_start | change | history | read | grep_rewrite | definition) marker="$prefix-$reported_kind" ;;
        "") ;; # Older CLIs identify the kind by the event.
        *) ;; # Newer CLIs fall back to the event marker.
      esac
      # Claim this (agent, kind) once, even when tool hooks run in parallel.
      if ! every_call "${reported_kind:-$kind}"; then
        (set -C; : >"$marker") 2>/dev/null || exit 0
      fi
      if [ "$host" = codex ]; then
        # Codex refuses an output with a field it does not know: the kind
        # is for this script only.
        printf '%s\n' "$output" | sed 's/, "kind": "[^"]*"//'
      else
        printf '%s\n' "$output"
      fi
    fi
    ;;
  1)
    # Leave every hint available when the repository becomes indexed.
    : >"$absent_retry"
    ;;
  *)
    : >"$retry"
    ;;
esac
# Markers from sessions long gone.
find "$state" -type f -mmin +1440 -delete 2>/dev/null
exit 0
