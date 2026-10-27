#!/bin/sh
# The ccx plugin's edit notes (specs: cocoindex-code-plus
# specs/product/cli/edit_notes.md). At an Edit, MultiEdit, Write or
# NotebookEdit call, names the recent pull request behind the lines the edit
# takes out (or the one it undoes), and, at the agent's first edit of a file,
# other live work on that file: another worktree's uncommitted change, another
# branch's recent commit, a pull request merged since the session started, an
# open pull request. At most one additionalContext, never a refusal, within
# about 0.5 s: it runs the CLI's module with the ccx interpreter, without the
# CLI's start-up. CCX_EDIT_NOTES=0 turns it off; CCX_EDIT_NOTES_GH=0 keeps it
# from refreshing its cached list of open pull requests (one `gh pr list` at
# most every 10 minutes). It always exits 0 and prints nothing on failure.
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
