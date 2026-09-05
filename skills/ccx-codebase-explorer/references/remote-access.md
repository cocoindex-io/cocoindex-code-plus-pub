# `ccx read-file` / `find-files` — read & list files at an indexed ref

These fetch file **contents** and **paths** exactly as they exist in an indexed
ref, over HTTP. Their job is reaching code you **don't have on disk** — a repo
that isn't checked out locally, or a **different ref** than your working tree.

**When you already have the repo checked out at the ref you care about, use your
normal file tools instead** — they're faster (no round-trip) and read the same
bytes. Reach for these only for remote / cross-ref / not-checked-out access.

Repo and ref are auto-detected like every query command (`--repo` / `--git-ref`
to override).

## read-file

```bash
ccx read-file README.md                                 # print a file at the ref
ccx read-file src/app.py --offset 40 --limit 20         # a line window
ccx read-file src/app.py --git-ref v1.2                 # the file as of another ref
```

`--offset` is a **1-based line number** here (a line window), unlike `grep`/
`find-files` where it's a pagination skip count.

## find-files

```bash
ccx find-files "*.py"                                    # paths matching a glob
ccx find-files                                           # all indexed files
ccx find-files "src/**" --case insensitive              # smart (default) | sensitive | insensitive
```

Useful to see what exists at a ref you don't have locally (e.g. before a
`--git-ref`-scoped `read-file`), or to compare paths across refs.
