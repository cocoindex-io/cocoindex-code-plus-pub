#!/bin/sh
# The ccx plugin's edit notes and ship check (specs: cocoindex-code-plus
# specs/product/cli/edit_notes.md). Never a refusal; at most one
# additionalContext; always exits 0 and prints nothing on failure.
#
# - Edit, MultiEdit, Write, NotebookEdit (PreToolUse): names the recent pull
#   request behind the lines the edit takes out (or the one it undoes) and,
#   at the agent's first edit of a file, other live work on that file:
#   another worktree's uncommitted change, another branch's recent commit, a
#   pull request merged since the session started, an open pull request.
# - Bash (PostToolUse): the files the call changed in its checkout get the
#   same notes, once per file. CCX_EDIT_NOTES_BASH=0 turns that off.
# - script/ship.py, gh pr create, git push of a branch (PreToolUse): other
#   work changing at least half of the branch's files, and dated decisions
#   the branch deletes from Markdown. CCX_SHIP_CHECK=0 turns that off.
#
# It runs the CLI's module with the ccx interpreter, without the CLI's
# start-up (about 0.1 s for an edit). CCX_EDIT_NOTES=0 turns everything off;
# CCX_EDIT_NOTES_GH=0 keeps it from refreshing its cached list of open pull
# requests (one `gh pr list` at most every 10 minutes).
set -u

case "${CCX_EDIT_NOTES:-}" in 0 | off | false | no | OFF | False | NO) exit 0 ;; esac
ccx_bin=$(command -v ccx 2>/dev/null) || exit 0
py=$(sed -n '1s/^#!//p' "$ccx_bin" 2>/dev/null)
if [ -n "$py" ] && [ -x "$py" ]; then
  "$py" -m cocoindex_code_plus.edit_notes 2>/dev/null
else
  # An older CLI has no `edit-notes` command: its usage error goes to /dev/null.
  ccx edit-notes --claude-hook 2>/dev/null
fi
exit 0
