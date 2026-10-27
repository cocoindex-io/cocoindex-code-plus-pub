#!/bin/sh
# The ccx plugin's red-test hook (specs: cocoindex-code-plus
# specs/product/cli/red_test.md). After a Bash call whose output shows failing
# tests (nextest `FAIL [`, `TRY n FAIL [`, cargo `test result: FAILED`,
# `---- name stdout ----`, pytest `FAILED path::name`, go `--- FAIL: Name`,
# `gate: FAILED`), `ccx red-test --claude-hook` adds a few lines of
# context per failing test (three at most, four lines each): where it
# stopped (the function holding the panic's line), what it exercises (for a
# test new or changed on the branch, read from its working-tree body), the
# PRs merged in the day before the checkout's base that changed those (the
# likely culprits), and any fix already open or merged past the base. It
# reads the local clone and the index under about 2 s. This script starts
# the CLI only when the output carries one of those markers.
# CCX_RED_TEST=0 turns it off. It always exits 0 and prints nothing on
# failure: a tool hook must never hold up or fail the agent. A failing run
# it does not hand to the CLI (switched off, no `ccx`) is one line of
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
  printf '{"ts": %s, "session_id": %s, "agent_id": %s, "transcript_path": %s, "tool_use_id": %s, "tool": "Bash", "kind": "red", "decision": "%s", "by": "script"}\n' \
    "$(date +%s)" "$(json "$(field session_id)")" "$(json "$(field agent_id)")" \
    "$(json "$(field transcript_path)")" "$(json "$(field tool_use_id)")" "$1" \
    >>"$dir/test-hooks.jsonl" 2>/dev/null || true
}
[ "$(field hook_event_name)" = PostToolUse ] || exit 0
case "$input" in
  *'FAIL ['* | *'test result: FAILED'* | *' stdout ----'* | *'gate: FAILED'* | *'FAILED '*'::'* | *'... FAILED'* | *'--- FAIL: '*) ;;
  *) exit 0 ;;
esac
case "${CCX_RED_TEST:-}" in 0 | off | false | no | OFF | False | NO) log_skip skip:off; exit 0 ;; esac
command -v ccx >/dev/null 2>&1 || { log_skip skip:no_cli; exit 0; }
# An older CLI has no `red-test` command: its usage error goes to /dev/null.
printf '%s' "$input" | ccx red-test --claude-hook 2>/dev/null
exit 0
