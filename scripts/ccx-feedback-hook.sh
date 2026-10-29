#!/bin/sh
# Older CLIs and failed feedback collection must never block session completion.
command -v ccx >/dev/null 2>&1 || exit 0
ccx feedback hook 2>/dev/null
exit 0
