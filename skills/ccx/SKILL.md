---
name: ccx
description: "This skill should be used when querying a codebase indexed by a remote CocoIndex Code Plus query server — semantic search, AST structural grep, or reading files/listing paths at an indexed git ref. Use it to get codebase information whenever everyday local tools fall short: fuzzy/conceptual search with no exact term to grep, structure-oriented code queries (matching syntax, not text lines), or corpora that are large, not checked out locally, at another ref, or spread across repos. Also use it when the user asks about ccx, cocoindex-code-plus, or the query server / MCP endpoint. Trigger phrases include 'search the codebase', 'find code related to', 'grep for the pattern', 'ccx', 'cocoindex-code-plus'."
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

## When to reach for ccx

Use ccx to get codebase information whenever the everyday local tools (`rg`,
file reads, IDE search) fall short:

- **Fuzzy / conceptual search** — you don't know the exact term, so text grep
  has nothing to anchor on ("where is retry handled?", "how are embeddings
  stored?") → `ccx search`.
- **Structure-oriented grep** — the question is about code *shape*, not text
  lines: a def vs. a call, a `catch` that re-throws the same variable it caught,
  every `isinstance` on a type, a nested generic that `>>` breaks for regex
  → `ccx grep`.
- **Large / remote / multi-repo corpus** — the repo isn't checked out locally,
  you need a branch or tag other than your checkout, or the question spans
  several indexed repos (`--repo`, `--git-ref`, `--all-repos`).

The one query *not* to route through ccx: a plain literal-identifier lookup in a
small repo you already have checked out — local `rg` answers that directly, and
a `ccx grep` with no structure (a bare identifier, no metavariable) just floods
unstructured hits.

## Setup (the agent owns reaching the server)

`ccx` needs two things, both env-driven (or a `.env` found from the working
directory upward, auto-loaded — already-exported vars win):

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server URL (e.g. `https://ccx.example.com`) |
| `CCX_API_TOKEN` | the API token, sent as `Authorization: Bearer` |

Before running queries, confirm the server is reachable:

```bash
ccx status        # prints server health, URL, version, uptime
```

Note `ccx status` checks **reachability only** — the health endpoint is
auth-exempt, so it passes even with a missing or wrong token. The first real
query is what confirms auth (a bad token returns `HTTP 401`).

If `ccx` is not installed, or `status` fails with a connection error, or the
env vars are unset, **do not guess credentials** — see
[references/management.md](references/management.md) for install + configuration,
and surface the missing piece to the user (the server URL and token are theirs to
provide).

## Repo & ref scoping (applies to every query command)

- **Repo auto-detection.** Commands auto-scope to the repo of the current git
  checkout, detected from its `origin` GitHub/GitLab remote (resolved to an
  `<owner>/<repo>` name). Override with `--repo <owner>/<repo>`. Without such an
  origin, `search` falls back to **all indexed repos** (with a stderr note);
  `--all-repos` asks for that explicitly.
- **Ref defaulting.** Every query command is ref-scoped, and `--git-ref` is
  **optional everywhere**: when omitted, the server uses your checked-out branch
  if it's indexed, else the repo's default branch — and prints a
  `Using git ref …` note to stderr so you know which ref answered. Trust this
  default; there is no need to run `ccx repositories` first just to discover a
  ref. Pass `--git-ref` only to target a *different* ref — a bare branch/tag
  name works (`main`, `v1.2`); the qualified `heads/<branch>` / `tags/<tag>`
  form is only needed when a branch and tag share a name. An unknown ref errors
  with the list of indexed refs.
- **CWD subtree scoping.** Run from a *subdirectory* of the checkout and
  `search`/`grep` default `--path` to that subtree (a stderr note names the
  glob). To cover the whole repo, run from the repo root or pass `--path '*'`.
  Don't mistake subtree-narrowed emptiness for "not in the codebase".

## Semantic search

Describe the concept, behavior, or functionality to find — not exact syntax.

```bash
ccx search how are vector embeddings stored      # auto-scopes to the current repo + branch
ccx search user authentication flow
ccx search error handling retry logic
```

- **Scope.** `--repo <owner>/<repo>` targets another repo; `--all-repos` searches
  every indexed repo; `--git-ref <ref>` targets a non-default ref (requires a
  repo scope, so not with `--all-repos`).
- **Filters.** `--lang <language>` restricts by source language and `--path
  '<glob>'` by path — both repeatable.
- **Results.** `-k` / `--top-k <N>` returns more results (default 5); `--offset`
  paginates. If every result looks relevant, there are likely more — raise `-k`.

```bash
ccx search "rate limiter" --all-repos
ccx search foo --repo cocoindex-io/cocoindex --git-ref main -k 10
ccx search parse config --lang python --path 'src/**'
```

Each result prints `[score] <repo> <file> (Lstart-Lend)` and the code. To read
more context around a hit, use `ccx read-file` (below) or your editor's file tools.

## AST structural grep

`ccx grep` matches a **by-example pattern against the code's syntax tree (AST)**,
not text — so it ignores formatting and never matches code inside comments.
Requires `-l/--language`.

```bash
ccx grep 'foo(\*)' -l python                  # calls to foo(...), any arguments
ccx grep 'def \_(\*):' -l python              # every function def (incl. async, decorated)
ccx grep 'isinstance(\_, \_)' -l python --path 'src/**'
```

The essentials, in one breath: write the code you're looking for, and replace the
parts that vary with **metavariables** — `\` is the only special character. Two
anonymous forms cover most patterns:

| Form | Matches |
|---|---|
| `\_` | exactly **one** node, any — a single slot (a receiver, one operand) |
| `\*` | a **run** of zero-or-more sibling nodes — the default inside `( )`/`[ ]`/`{ }` (`\+` one-or-more, `\?` optional) |
| `\/re/` | one node whose text matches the regex `re` (e.g. `\/get_.*/`) |
| `\NAME` | like `\_`, but *named* — only needed to report the capture, or reused later to require *equal* text (backreference) |
| `\{{ INNER \}}` | a node that *contains* `INNER` somewhere inside (any depth) |

Inside brackets, prefer `\*`: an argument list is several nodes, so
`cached_fn(\_)` matches only single-argument calls while `cached_fn(\*)` matches
them all. Reach for `\NAME` only when the name does work:

```bash
ccx grep '\_.filter(\*).map(\*)' -l rust           # a .filter(...).map(...) chain, any receiver
ccx grep 'catch (\E) \{{ throw \E \}}' -l java     # catch that re-throws the SAME var (backref \E)
ccx grep 'DenseMap<\_, \_>' -l c++                 # nested generic; structural, so >> just works
```

Two mistakes to avoid (observed in real agent usage):

- **Never escape literal code.** `\` *introduces* pattern constructs; it is not
  a shell/sed-style escape. `class Call(\_):` is right; `class Call\(\_\):` is
  wrong — `\(…\)` is the explicit metavariable delimiter, so escaping the parens
  turns them into a metavar and the pattern silently matches nothing.
- **A string literal is one atomic node.** `\*` and `\NAME` can't reach *inside*
  it. Match a string exactly (`app.get("/project/files")`), or match variable
  string content with a regex metavar whose regex covers the quotes:
  `app.get(\/"\/project.*"/)`.

**An empty result is information, not a near-miss.** Structural match is literal
about structure — a wrong guess returns nothing rather than something fuzzy. So
when a grep comes back empty, *loosen the structure*, don't abandon it:

1. Replace the parts you're least sure of with `\_` / `\*` / `\?`, or a name
   you're unsure of with `\/re/` (e.g. `\/get_.*/(\*)`).
2. Unsure whether `X` is *defined* or only *called* here? `X(\*)` matches both
   the def header and every call site.
3. Still nothing → the shape genuinely isn't there; pivot to `ccx search` for
   the concept.

(Wrapping the whole pattern in `\{{ … \}}` does **not** broaden a top-level
match, and dropping to a bare identifier with no metavariable just floods hits.)

Key model: a pattern matches a **fragment**, child-aligned; incidental trailing
`;`/`,` are ignored, but closers (`)`, `}`) are significant. **For the full
pattern language, verified recipes for common queries, and the gotchas (why
`try \{{ … \}}` needs the `:`, qualified names, fragment spans), read
[references/grep-syntax.md](references/grep-syntax.md) before writing non-trivial
patterns.**

- **Pagination.** `-k`/`--limit` (default 100) and `--offset` (a skip count); a
  truncation note on stderr means there are more matches.

## File access (ref-scoped)

Read files and list paths exactly as they exist in an indexed ref. Repo and ref
are auto-detected like every other command (`--repo` / `--git-ref` to override).

```bash
ccx read-file README.md                                  # print a file
ccx read-file src/app.py --offset 40 --limit 20          # a line window (--offset = 1-based line here)

ccx find-files "*.py"                                    # list files matching a glob
ccx find-files                                           # list all indexed files
ccx find-files "src/**" --case insensitive               # smart (default) | sensitive | insensitive
```

Prefer these over a semantic `search` when you already know the path or want exact
file contents at a ref (e.g. to read more context around a search/grep hit).
Note `--offset` is a 1-based *line number* for `read-file`, but a pagination
*skip count* for `grep`/`find-files`.

## Repo & ref metadata

```bash
ccx repositories                                 # the current repo's indexed refs + commit shas
ccx repositories cocoindex-io/cocoindex          # a specific repo ("(default)" marks the default branch)
```

Use this to see *what is indexed* — which repos/refs exist, at which commits —
e.g. before targeting a non-default ref. It is **not** a required preamble:
the ref default (above) already picks the right ref for the common case.

## When a query returns nothing useful

- **`No results.` / `No matches.`** — the query or pattern found nothing. For
  `search`, rephrase conceptually or raise `-k`/`--offset`. For `grep`, follow
  the loosening ladder above — a wrong structural guess returns empty, so
  re-check [references/grep-syntax.md](references/grep-syntax.md) gotchas before
  concluding the code isn't there. Also check stderr: a CWD-subtree note means
  you searched only part of the repo (`--path '*'` widens).
- **"index not built yet" (HTTP 503)** — the server hasn't populated the index for
  that repo/ref yet. This is a *server-side* state; the CLI can't fix it. Tell the
  user and retry later, or pick an already-indexed ref (`ccx repositories`).
- **HTTP 401** — missing/invalid `CCX_API_TOKEN` (note `ccx status` does not
  catch this). See [references/management.md](references/management.md).
- **Unknown/unindexed ref** — the error lists the indexed refs; pick one or drop
  `--git-ref` to use the default.

## For agents & MCP

Everything is non-interactive and env-driven, so an agent or CI job can run `ccx`
directly: errors exit non-zero, notes go to stderr, results to stdout. The query
server also exposes an **MCP** endpoint (`<CCX_SERVER_URL>/mcp`) with the same
tools at parity — the preferred path for MCP-capable agents (no CLI install, no
output parsing). See [references/management.md](references/management.md#mcp).
