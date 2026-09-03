---
name: ccx
description: "This skill should be used when querying a codebase indexed by a remote CocoIndex Code Plus query server — semantic search, AST structural grep, symbol navigation (find a symbol's definitions and references), reading files/listing paths at an indexed git ref, or asking a natural-language question about the code and getting a written, citation-backed answer (`ccx query`). Use it to get codebase information whenever everyday local tools fall short: fuzzy/conceptual search with no exact term to grep, structure-oriented code queries (matching syntax, not text lines), resolved where-is-this-defined / who-calls-this lookups, or corpora that are large, not checked out locally, at another ref, or spread across repos. Also use it when the user asks about ccx, cocoindex-code-plus, or the query server / MCP endpoint. Trigger phrases include 'search the codebase', 'find code related to', 'grep for the pattern', 'where is X defined', 'find all references/usages/call sites', 'ask the codebase a question', 'ccx query', 'ccx', 'cocoindex-code-plus'."
---

# ccx — Query an Indexed Codebase (Semantic Search + AST Grep + Symbol Navigation)

`ccx` is the client CLI for **CocoIndex Code Plus**. It queries a codebase that a
**remote query server** has indexed into Postgres + pgvector — semantic search,
AST structural grep, symbol definitions/references, read-only file access, and
(where enabled) a cited written answer to a question — over HTTP. The CLI holds
no index and needs no license; it just talks to a server.

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
- **Symbol navigation** — "where is `X` defined?", "who calls / imports / uses
  `X`?": a **resolved** cross-file answer (alias- and re-export-aware, not a
  text match) → `ccx defs` / `ccx refs`. Covers Python, TS/JS (incl. TSX), C/C++,
  C#, and Rust.
- **Large / remote / multi-repo corpus** — the repo isn't checked out locally,
  you need a branch or tag other than your checkout, or the question spans
  several indexed repos (`--repo`, repeatable for `search` and `query`;
  `--git-ref`).
- **A question, not a lookup** — the deliverable is a written, cited
  explanation ("how does re-embedding get decided, end to end?", "compare auth
  in these two services"), or the question is too broad for one search or
  pattern → `ccx query` (slower; see below).

The one query *not* to route through ccx: a plain literal-identifier lookup in a
small repo you already have checked out — local `rg` answers that directly, and
a `ccx grep` with no structure (a bare identifier, no metavariable) just floods
unstructured hits. (But when the identifier question is really a *symbol*
question — its definition, or its true use sites rather than every textual
occurrence — `ccx defs` / `ccx refs` beat both.)

## Repo & ref scoping (applies to every query command)

- **Repo auto-detection.** Commands auto-scope to the repo of the current git
  checkout, detected from its `origin` GitHub/GitLab remote (resolved to an
  `<owner>/<repo>` name). Override with `--repo <owner>/<repo>` (repeatable for
  `search` and `query`, up to the server's per-search cap). Without such an
  origin the command **errors** with guidance rather than guessing — pass
  `--repo`;
  `ccx repos` lists the indexed repos you can target. There is no global
  "search everything" mode.
- **Ref defaulting.** Every query command is ref-scoped, and `--git-ref` is
  **optional everywhere**: when omitted, the server uses your checked-out branch
  if it's indexed, else the repo's default branch — and prints a
  `Using git ref …` note to stderr so you know which ref answered. Trust this
  default; there is no need to run `ccx git-refs` first just to discover a
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

- **Scope.** `--repo <owner>/<repo>` targets another repo — repeat it to search
  several at once (one cross-repo-ranked list); `--git-ref <ref>` targets a
  non-default ref (single-repo scope only).
- **Filters.** `--lang <language>` restricts by source language and `--path
  '<glob>'` by path — both repeatable.
- **Results.** Ranked by relevance — the most relevant come **first**, so if the
  top hit already answers the question, stop there; don't fetch more just to be
  safe. `-k` / `--top-k <N>` returns more (default 5) and `--offset` paginates —
  raise `-k` only when every result still looks relevant (then there are likely
  more).

```bash
ccx search "rate limiter" --repo acme/api --repo acme/worker
ccx search foo --repo cocoindex-io/cocoindex --git-ref main -k 10
ccx search parse config --lang python --path 'src/**'
```

Each result prints `[score] <repo> <file> (Lstart-Lend)` and the code. To read
more context around a hit, open the file with your normal file tools (or, for a
ref you don't have checked out, `ccx read-file` — see remote-access reference).

## AST structural grep

`ccx grep` matches a **by-example pattern against the code's syntax tree (AST)**,
not text — so it ignores formatting and never matches code inside comments.
Requires `-l/--language`.

```bash
ccx grep 'foo(\*)' -l python                  # calls to foo(...), any arguments
ccx grep 'def \_(\*) \*:' -l python           # every function def (async, decorated, `-> T` too)
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

- **Never escape literal code — including inside strings.** `\` *introduces*
  pattern constructs; it is not a shell/sed/regex escape. `class Call(\_):` is
  right, `class Call\(\_\):` is wrong (`\(…\)` is the metavariable delimiter, so
  the escaped parens become a metavar → silently matches nothing). The same trap
  bites string content: write `".."`, not `"\.\."`.
- **Matching is at lexer-token boundaries — a string literal is one atomic
  node.** `\*` and `\NAME` can't reach *inside* it, and a literal string in the
  pattern matches only the **full** literal: `open("config")` does *not* match
  `open("app_config.yaml")`. For partial string content use a regex metavar
  whose regex covers the quotes: `open(\/".*config.*"/)`. And to find code that
  *handles* a concept — not one exact literal — reach for `ccx search`, not a
  string-literal grep.

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
`;`/`,` are ignored, but closers (`)`, `}`) are significant. The output shows
**exactly the span the pattern covers** — extend the pattern to see more:
`def parse_config(\*) \*:` prints only the header, while
`def parse_config(\*) \*: \*` prints the whole function including its body. That
`\*` before the colon absorbs a `-> T` return annotation — `def f(\*):` matches
**only** un-annotated defs (zero hits in a typed codebase), a silent miss. **For the full
pattern language, verified recipes for common queries, and the gotchas (why
`try \{{ … \}}` needs the `:`, qualified names, fragment spans), read
[references/grep-syntax.md](references/grep-syntax.md) before writing non-trivial
patterns.**

- **Pagination.** `-k`/`--limit` (default 100) and `--offset` (a skip count); a
  truncation note on stderr means there are more matches.

## Symbol navigation (`ccx defs` / `ccx refs`)

Where is a symbol **defined**, and who **uses** it — answered from a resolved
symbol graph the indexer builds (cross-file, alias- and re-export-aware), not
from text matching. Covers **Python, TS/JS incl. TSX, C/C++, C#, and Rust**;
for other languages fall back to `grep`/`search`.

```bash
ccx defs QueryService                        # definitions of the base name
ccx defs db.Repo.find --qualified-name       # exact dotted qualified name
ccx defs Config --kind class --lang python   # filter: --kind / --lang / --path
ccx refs QueryService                        # uses, by base name (broad recall)
ccx refs src/db.py Repo.find                 # uses of EXACTLY this definition (see below)
ccx refs QueryService --role call            # only calls (roles: call, import, type_use, …)
```

The canonical flow is **defs → refs**, a copy-paste. Each `ccx defs` row's detail
line ends with a paste-ready command — `uses: ccx refs PATH ENTITY_ID` (carrying
`--repo`/`--git-ref` when you scoped explicitly); run it verbatim, adding
`--role` and friends as needed:

```
$ ccx defs find
src/db.py:42:4 [method] python:db.Repo.find
  lang=python  uses: ccx refs src/db.py Repo.find

$ ccx refs src/db.py Repo.find --role call
```

Run the printed command — don't compose the second token yourself: the
headline's pack-tagged dotted name (`python:db.Repo.find`, module-qualified) is
**not** the entity id (`Repo.find`, file-relative). A bare `ccx refs NAME` is the broad alternative
(every definition with that unqualified name, plus unresolved mentions). If a
single argument looks like half of a forgotten pair (a path, or a dotted /
`#`-suffixed id), `refs` errors with the fix instead of running a broad query
you didn't intend; `--base-name` forces name mode when a base name genuinely
contains such characters.

Reading `refs` output — each row carries:

- a **role** (`call`, `import`, `type_use`, `inherit`, `implement`,
  `field_access`, `alias`, `decorates`, `use`) — filter with `--role`;
- a **resolution**: `resolved` is a definite reference; `ambiguous` means
  several candidates survived and each is its own row (the tool enumerates
  rather than guessing — so one source position can appear on several rows,
  and row count ≠ site count); `name_only` is a mention whose target couldn't
  be resolved (external import, dynamic receiver) — listed with the kinds it
  could have been (`--no-include-unresolved` drops these);
- possibly a `via_alias` marker: a supplementary row for the alias/re-export
  hop the primary reference went through. Resolved rows print their target as
  the same two-token `PATH ENTITY_ID` form, so any target you see in output
  pastes straight back into `ccx refs`.

**Check the stderr coverage note before trusting absence.** It reports when the
symbol index for this ref is *not built*, *skipped* (ref too large to resolve),
*partial* (some files failed to parse), or *lags the ref head* — in every one of
those, a missing symbol may simply be unindexed. Absence is not completeness.
A stale exact target (definition renamed/removed since the `defs` call) errors
with `target_not_found` — re-run `ccx defs` for a current target.

## Ask a question, get a cited answer (`ccx query`)

Every command above returns *material* — hits, matches, symbol rows — for you to
read. `ccx query` returns a **written answer with citations**: a server-side
agent does the searching, grepping, and reading for you and writes up what it
found. Scoping is the same as `search`: the current checkout by default,
`--repo` repeatable, `--git-ref` for a single repo.

```bash
ccx query "how does the indexer decide what to re-embed?"
ccx query "compare how these two services authenticate" --repo acme/a --repo acme/b
```

Reach for it when the deliverable is an **explanation** ("how does X work end to
end?", "why does Y happen?", "compare A and B" — above all across repos), or the
question is too broad to reduce to one search or pattern. When the deliverable
is a **location or code to read** — which file to change, where a symbol lives,
its call sites — stay with `search`/`grep`/`defs`/`refs`: they answer in a
second or two, while `query` runs seconds to minutes. Run one `query` at a time
(the server caps concurrent agentic queries); a question already answered — by
anyone, even rephrased — may return instantly from the answer cache.

- **Read it as evidence, not proof.** Citations look like `[s0:path#L40-L52]`;
  `s0` resolves on stderr as `s0: <owner>/<repo> @ <ref> (commit <sha>)`, and
  the line numbers are at that commit. Before acting on a claim, open those
  lines at that commit — `git show <sha>:<path>`, or your working tree when it
  is at that commit; for a repo you don't have, `ccx read-file` with that
  `--repo`/`--git-ref` (the ref's indexed head — the same commit unless the
  index has moved since). A claim its lines don't support is dropped, not
  repeated.
- **`--json`** emits the exact response model (`answer`, `resolved_scopes`,
  `usage`; `usage.result_cache_hit` says whether the cache answered); `--stats`
  adds a one-line cost/reuse summary on stderr.
- **It may be off, busy, or out of time.** `agent_query_unavailable` means the
  deployment hasn't enabled it: answer with the other commands, tell the user
  their platform team decides, and don't try again this session.
  `agent_query_busy` (concurrency cap) and `deadline_exceeded` (the
  investigation outran the server's deadline): fall back to the other commands
  for this question — at most one later retry, never a loop.

## Reading & listing files at a ref (remote / cross-ref)

`ccx read-file` and `ccx find-files` fetch file contents and paths at an indexed
ref. They're for code you **don't have on disk** — a repo not checked out locally,
or a **different ref** than your working tree. **When the repo is checked out at
the ref you care about, use your normal file tools instead** (faster, same bytes).
Full usage: [references/remote-access.md](references/remote-access.md).

## Repo & ref metadata

`ccx git-refs [<owner>/<repo>]` lists what's indexed — a repo's refs and their
commit shas (`(default)` marks the default branch). Reach for it only to target a
non-default ref; the ref default already handles the common case.

Note the two different senses of "ref": `ccx git-refs` lists **git** refs
(branches and tags), while `ccx refs` finds where a **symbol** is used.

## When a query returns nothing useful

- **`No results.` / `No matches.`** — the query or pattern found nothing. For
  `search`, rephrase conceptually or raise `-k`/`--offset`. For `grep`, follow
  the loosening ladder above — a wrong structural guess returns empty, so
  re-check [references/grep-syntax.md](references/grep-syntax.md) gotchas before
  concluding the code isn't there. Also check stderr: a CWD-subtree note means
  you searched only part of the repo (`--path '*'` widens).
- **`No definitions.` / `No references.`** — first read the stderr coverage
  note (index not built / ref skipped / partial parse / snapshot lag →
  absence proves nothing); then check the language is covered (Python,
  TS/JS/TSX, C/C++, C#, Rust). A `defs` miss on a dotted name usually means
  `--qualified-name` was needed (or vice versa — drop it to match the base
  name); a `refs` miss on an exact target may be a stale `entity_id` — re-run
  `ccx defs`.
- **Unknown/unindexed ref** — the error lists the indexed refs; pick one or drop
  `--git-ref` to use the default.

Server/transport failures — `HTTP 503` "index not built yet", `HTTP 401` auth, an
expired login (the error says `Run ccx login`), a connection error, or `ccx` not
installed — are the user's environment, not something
to work around: **never invent a server URL or token**; surface the missing piece to
the user and see [references/management.md](references/management.md) for setup +
troubleshooting.

## For agents & MCP

Everything is non-interactive and env-driven, so an agent or CI job can run `ccx`
directly: errors exit non-zero, notes go to stderr, results to stdout. The query
server also exposes an **MCP** endpoint (`<CCX_SERVER_URL>/mcp`) with the same
tools at parity (`ccx query` is the `query_codebase` tool) — the preferred path
for MCP-capable agents (no CLI install, no output parsing). See
[references/management.md](references/management.md#mcp).
