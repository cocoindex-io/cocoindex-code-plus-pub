#!/bin/sh
# The ccx plugin's tests-for hook (specs: cocoindex-code-plus
# specs/product/cli/tests_for.md). `ccx tests-for --claude-hook`:
#
# - after an edit of a .rs, .py or .go file (PostToolUse Edit, Write,
#   MultiEdit; Codex's apply_patch): the tests of the definitions the edit
#   changed and one command that runs them, once per file content and once
#   per set of tests, within about 1.5 s or nothing;
# - before `git commit`, `script/ship.py` or `script/gate.py` (PreToolUse
#   Bash): the command for the whole diff's tests when the session's
#   transcript shows no test command that ran them.
#
# CCX_TESTS_FOR=0 turns it off. It always exits 0 and prints nothing on
# failure: a tool hook must never hold up or fail the agent. With `codex`
# the script itself picks the events Codex's matcher cannot tell apart.
set -u

case "${CCX_TESTS_FOR:-}" in 0 | off | false | no | OFF | False | NO) exit 0 ;; esac
input=$(cat)
field() {
  printf '%s' "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1
}
case "$(field hook_event_name):$(field tool_name)" in
  PostToolUse:Edit | PostToolUse:Write | PostToolUse:MultiEdit)
    case "$(field file_path)" in *.rs | *.py | *.go) ;; *) exit 0 ;; esac
    ;;
  PostToolUse:apply_patch)
    case "$input" in *'.rs'* | *'.py'* | *'.go'*) ;; *) exit 0 ;; esac
    ;;
  PreToolUse:Bash)
    case "$input" in *'git commit'* | *'git -C '*commit* | *ship.py* | *gate.py*) ;; *) exit 0 ;; esac
    ;;
  *) exit 0 ;;
esac
command -v ccx >/dev/null 2>&1 || exit 0
# An older CLI has no `tests-for` command: its usage error goes to /dev/null.
printf '%s' "$input" | ccx tests-for --claude-hook 2>/dev/null
exit 0
