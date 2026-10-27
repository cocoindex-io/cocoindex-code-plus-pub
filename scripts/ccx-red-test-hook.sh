#!/bin/sh
# The ccx plugin's red-test hook (specs: cocoindex-code-plus
# specs/product/cli/red_test.md). After a Bash call whose output shows failing
# tests (nextest `FAIL [`, `TRY n FAIL [`, cargo `test result: FAILED`,
# `---- name stdout ----`, pytest `FAILED path::name`, `gate: FAILED`),
# `ccx red-test --claude-hook` adds at most five lines of context: per failing
# test, the PRs merged in the day before the checkout's base that most likely
# turned it red, and any fix for it already open or merged past the base. It
# reads the local clone and the change index under about 1.5 s. This script
# starts the CLI only when the output carries one of those markers.
# CCX_RED_TEST=0 turns it off. It always exits 0 and prints nothing on
# failure: a tool hook must never hold up or fail the agent.
set -u

case "${CCX_RED_TEST:-}" in 0 | off | false | no | OFF | False | NO) exit 0 ;; esac
input=$(cat)
event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"\\]*\)".*/\1/p' | head -n 1)
[ "$event" = PostToolUse ] || exit 0
case "$input" in
  *'FAIL ['* | *'test result: FAILED'* | *' stdout ----'* | *'gate: FAILED'* | *'FAILED '*'::'* | *'... FAILED'*) ;;
  *) exit 0 ;;
esac
command -v ccx >/dev/null 2>&1 || exit 0
# An older CLI has no `red-test` command: its usage error goes to /dev/null.
printf '%s' "$input" | ccx red-test --claude-hook 2>/dev/null
exit 0
