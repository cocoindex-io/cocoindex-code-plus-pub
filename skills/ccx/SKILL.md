---
name: ccx
description: "This skill should be used when querying a codebase indexed by a remote CocoIndex Code Plus query server — semantic search, AST structural grep, or reading files/listing paths at a specific indexed git ref. Use it whenever code search is needed (explicitly or as part of a task) against a ccx-indexed repo, or when the user asks about ccx, cocoindex-code-plus, or the query server / MCP endpoint. Trigger phrases include 'search the codebase', 'find code related to', 'grep for the pattern', 'ccx', 'cocoindex-code-plus'."
---

# ccx — Query an Indexed Codebase (Semantic Search + AST Grep)

`ccx` is the client CLI for **CocoIndex Code Plus**. It queries a codebase that a
**remote query server** has indexed into Postgres + pgvector — semantic search,
AST structural grep, and read-only file access — over HTTP. The CLI holds no
index and needs no license; it just talks to a server.

This is fundamentally different from the open-source `ccc`: **there is no local
daemon, no `init`, and no indexing here.** The index is built and kept fresh by a
server-side indexer you don't control from the CLI. The agent's job is to *query*,
not to manage the index.

## Setup (the agent owns reaching the server)

`ccx` needs two things, both env-driven (or a `.env` in the working directory,
auto-loaded):

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server URL (e.g. `https://ccx.example.com`) |
| `CCX_API_TOKEN` | the API token, sent as `Authorization: Bearer` |

Before running queries, confirm the server is reachable:

```bash
ccx status        # prints server health, URL, version, uptime
```

If `ccx` is not installed, or `status` fails with a connection/auth error, or the
env vars are unset, **do not guess credentials** — see
[references/management.md](references/management.md) for install + configuration,
and surface the missing piece to the user (the server URL and token are theirs to
provide).

## Repo & ref scoping (applies to every query command)

- **Repo auto-detection.** Most commands auto-scope to the repo of the current git
  checkout, detected from its `origin` GitHub/GitLab remote (resolved to an
  `<owner>/<repo>` name). Override with `--repo <owner>/<repo>`. `search` also
  takes `--all-repos` to search everything.
- **Ref scoping.** `grep`, `read-file`, and `find-files` are **ref-scoped** and
  *require* `--git-ref`, qualified as `heads/<branch>` or `tags/<tag>` (e.g.
  `heads/main`). `search` takes an optional `--git-ref` (needs a repo scope).
- Use `ccx repositories` to discover which refs are indexed before a ref-scoped
  command (see below).

## Semantic search

Describe the concept, behavior, or functionality to find — not exact syntax.

```bash
ccx search how are vector embeddings stored      # auto-scopes to the current repo
ccx search user authentication flow
ccx search error handling retry logic
```

- **Scope.** `--repo <owner>/<repo>` targets another repo; `--all-repos` searches
  every indexed repo; `--git-ref heads/<branch>` restricts to one ref (requires a
  repo scope, so not with `--all-repos`).
- **Results.** `-k` / `--top-k <N>` returns more results (default 5). If every
  result looks relevant, there are likely more — raise `-k`.

```bash
ccx search "rate limiter" --all-repos
ccx search foo --repo cocoindex-io/cocoindex --git-ref heads/main -k 10
```

Each result prints `[score] <repo> <file> (Lstart-Lend)` and the code. To read
more context around a hit, use `ccx read-file` (below) or your editor's file tools.

## AST structural grep

`ccx grep` matches a **by-example pattern against the code's syntax tree (AST)**,
not text — so it ignores formatting and **never matches inside comments or
strings**. Requires `-l/--language` and `--git-ref`.

```bash
ccx grep 'foo(\X)' -l python --git-ref heads/main                  # calls to foo(...), capturing the arg as X
ccx grep 'def \NAME(\(ARGS*\)):' -l python --git-ref heads/main    # every Python function def
ccx grep 'isinstance(\X, \Y)' -l python --git-ref heads/main --path 'src/*.py'
```

The essentials, in one breath: write the code you're looking for, and replace the
parts that vary with **metavariables** — `\` is the only special character.

| Form | Matches |
|---|---|
| `\NAME` | one node, captured as `NAME` (reported back; reuse `\NAME` later to require *equal* text) |
| `\_` | one node, any (anonymous) |
| `\*` | a run of zero-or-more sibling nodes (`\+` one-or-more, `\?` optional) |
| `\/re/` | one node whose text matches the regex `re` |
| `\{{ INNER \}}` | a node that *contains* `INNER` somewhere inside (any depth) |

```bash
ccx grep '\X.filter(\*).map(\*)' -l rust --git-ref heads/main      # a .filter(...).map(...) chain
ccx grep 'catch (\E) \{{ throw \E \}}' -l java --git-ref heads/main # catch that re-throws the SAME var (backref \E)
ccx grep 'DenseMap<\K, \V>' -l c++ --git-ref heads/main            # nested generic; structural, so >> just works
```

Key model: a pattern matches a **fragment**, child-aligned; incidental trailing
`;`/`,` are ignored, but closers (`)`, `}`) are significant. **For the full
pattern language, the shipped vs. not-yet features, and the common gotchas (why
`try \{{ … \}}` needs the `:`, qualified names, fragment spans), read
[references/grep-syntax.md](references/grep-syntax.md) before writing non-trivial
patterns.**

- **Pagination.** `-k`/`--limit` (default 100) and `--offset`; a truncation note
  on stderr means there are more matches.

## File access (ref-scoped)

Read files and list paths exactly as they exist in an indexed ref. Both require
`--git-ref`; the repo is auto-detected (or `--repo`).

```bash
ccx read-file README.md --git-ref heads/main                     # print a file
ccx read-file src/app.py --git-ref heads/main --offset 40 --limit 20   # a line window (1-based --offset)

ccx find-files "*.py" --git-ref heads/main                       # list files matching a glob
ccx find-files --git-ref heads/main                              # list all indexed files
ccx find-files "src/**" --git-ref heads/main --case insensitive  # smart (default) | sensitive | insensitive
```

Prefer these over a semantic `search` when you already know the path or want exact
file contents at a ref (e.g. to read more context around a search/grep hit).

## Repo & ref metadata

```bash
ccx repositories                                 # the current repo's indexed refs + each ref's commit sha
ccx repositories cocoindex-io/cocoindex          # a specific repo
```

Run this first when you need a `--git-ref` value, or to confirm a repo/ref is
indexed at all.

## When a query returns nothing useful

- **`No results.` / `No matches.`** — the query or pattern found nothing. For
  `search`, rephrase conceptually or raise `-k`/`--offset`. For `grep`, the pattern
  is often slightly off — re-check [references/grep-syntax.md](references/grep-syntax.md)
  gotchas before assuming the code isn't there.
- **"index not built yet" (HTTP 503)** — the server hasn't populated the index for
  that repo/ref yet. This is a *server-side* state; the CLI can't fix it. Tell the
  user and retry later, or pick an already-indexed ref (`ccx repositories`).
- **HTTP 401** — missing/invalid `CCX_API_TOKEN`. See
  [references/management.md](references/management.md).
- **Ref not indexed** — `ccx repositories` shows which refs exist; a ref-scoped
  command against an unindexed ref returns empty or an error.

## For agents & MCP

Everything is non-interactive and env-driven, so an agent or CI job can run `ccx`
directly: errors exit non-zero, notes go to stderr, results to stdout. The query
server also exposes an **MCP** endpoint (`<CCX_SERVER_URL>/mcp`) with the same
tools at parity — the preferred path for MCP-capable agents (no CLI install, no
output parsing). See [references/management.md](references/management.md#mcp).
