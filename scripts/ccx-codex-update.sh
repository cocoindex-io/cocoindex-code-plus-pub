#!/bin/sh
# Install or update the ccx plugin for the OpenAI Codex CLI, and trust its
# hooks (docs/cli.md → "The plugin under Codex").
#
#   sh ccx-codex-update.sh [MARKETPLACE_SOURCE]
#
# MARKETPLACE_SOURCE (first install only): this repository's path or
# `cocoindex-io/cocoindex-code-plus-pub`; default the GitHub one.
#
# Codex copies a plugin when it is added and never refreshes the copy on its
# own, and any change to the plugin's files leaves every one of its hooks
# untrusted, which Codex skips without a word. So an update is three steps,
# all here: refresh the marketplace, add the plugin again, trust its hooks
# (what `/hooks` in the interactive CLI does; only ccx@ccx's hooks, as they
# now are). Run it again after every update of the plugin.
set -eu

source=${1:-cocoindex-io/cocoindex-code-plus-pub}
command -v codex >/dev/null 2>&1 || { echo "ccx: codex is not on PATH" >&2; exit 1; }
ccx_bin=$(command -v ccx 2>/dev/null) || { echo "ccx: the ccx CLI is not on PATH" >&2; exit 1; }
py=$(sed -n '1s/^#!//p' "$ccx_bin")

if codex plugin marketplace list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx ccx; then
  # A Git marketplace is a snapshot: refresh it. A local one reads the folder.
  codex plugin marketplace upgrade ccx >/dev/null 2>&1 || true
else
  codex plugin marketplace add "$source"
fi
codex plugin add ccx@ccx
if [ -n "$py" ] && [ -x "$py" ] && "$py" -c 'from cocoindex_code_plus.codex_hook import trust_hooks' 2>/dev/null; then
  "$py" -m cocoindex_code_plus.codex_hook trust "$PWD"
else
  echo "ccx: this ccx CLI cannot trust Codex hooks; upgrade it, or run codex and type /hooks to trust them." >&2
  exit 1
fi
