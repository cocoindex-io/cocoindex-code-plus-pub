#!/bin/sh
# The ccx plugin's tests-for hook (specs: cocoindex-code-plus
# specs/product/cli/tests_for.md). `ccx tests-for --claude-hook`:
#
# - after an edit of a .rs, .py or .go file (PostToolUse Edit, Write,
#   MultiEdit; Codex's apply_patch): the tests of the definitions the edit
#   changed and one command that runs them, once per file content and once
#   per set of tests, within about 1.5 s or nothing;
# - before `git commit`, `git push`, `gh pr create`, a test run (`cargo test`,
#   `pytest`, `go test`, `dotnet test`, `npm test`, `./build.sh --test`, ...)
#   or reduce's `script/ship.py` / `script/gate.py` (PreToolUse Bash): the
#   command for the whole diff's tests when neither the session's transcript
#   nor the command itself ran them, and, once, the tests an edit hook gave
#   the session that have not run since. Advisory: it never holds the
#   command up.
#
# Each answer leads with the one command to run, then at most two lines of
# why.
#
# CCX_TESTS_FOR=0 turns it off. It always exits 0 and prints nothing on
# failure: a tool hook must never hold up or fail the agent. With `codex`
# the script itself picks the events Codex's matcher cannot tell apart. An
# event it does not hand to the CLI (switched off, no `ccx`) is one line of
# ~/.cache/ccx/test-hooks.jsonl, as every decision of the CLI is.
set -u

input=$(cat)
field() {
  printf '%s' "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1
}
# One decision line, the CLI's fields; never fails.
log_skip() {
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/ccx"
  mkdir -p "$dir" 2>/dev/null || return 0
  json() { if [ -n "$1" ]; then printf '"%s"' "$1"; else printf null; fi; }
  printf '{"ts": %s, "session_id": %s, "agent_id": %s, "transcript_path": %s, "tool_use_id": %s, "tool": %s, "kind": "%s", "decision": "%s", "by": "script"}\n' \
    "$(date +%s)" "$(json "$(field session_id)")" "$(json "$(field agent_id)")" \
    "$(json "$(field transcript_path)")" "$(json "$(field tool_use_id)")" \
    "$(json "$(field tool_name)")" "$1" "$2" >>"$dir/test-hooks.jsonl" 2>/dev/null || true
}
case "$(field hook_event_name):$(field tool_name)" in
  PostToolUse:Edit | PostToolUse:Write | PostToolUse:MultiEdit)
    case "$(field file_path)" in *.rs | *.py | *.go) kind=edit ;; *) exit 0 ;; esac
    ;;
  PostToolUse:apply_patch)
    case "$input" in *'.rs'* | *'.py'* | *'.go'*) kind=edit ;; *) exit 0 ;; esac
    ;;
  PreToolUse:Bash)
    # The CLI's CHECKPOINT decides; this only keeps other commands from
    # starting it: committing, shipping, gating, a test run, in any repo.
    case "$input" in
      *'git commit'* | *'git -C '*commit* | *'git push'* | *'git -C '*push* | *'gh pr create'* | \
        *ship.py* | *gate.py* | *'uild.sh'*test* | *'uild.cmd'*test* | *'uild.ps1'*test* | \
        *'cargo test'* | *'cargo nextest'* | *'cargo +'*test* | *pytest* | *'go test'* | *'go -C '*test* | \
        *'dotnet test'* | *'npm test'* | *'npm run test'* | *'pnpm '*test* | *'yarn '*test* | \
        *'bun test'* | *'npx jest'* | *'npx vitest'* | *mvn*test* | *mvn*verify* | *gradle*test* | \
        *'make test'*) kind=checkpoint ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
case "${CCX_TESTS_FOR:-}" in 0 | off | false | no | OFF | False | NO) log_skip "$kind" skip:off; exit 0 ;; esac
command -v ccx >/dev/null 2>&1 || { log_skip "$kind" skip:no_cli; exit 0; }
# An older CLI has no `tests-for` command: its usage error goes to /dev/null.
printf '%s' "$input" | ccx tests-for --claude-hook 2>/dev/null
exit 0
