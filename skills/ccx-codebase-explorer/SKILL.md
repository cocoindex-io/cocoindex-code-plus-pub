---
name: ccx-codebase-explorer
description: "Explore, navigate, and explain a codebase through the ccx CLI, which queries a server-side code index: semantic search, AST structural grep, resolved symbol definitions and references, and `ccx ask`, a written answer with citations. Use it proactively, before falling back to grep and file reads, whenever the user wants to understand or find code: how a feature, request, or subsystem works end to end; a walkthrough or onboarding tour of a repo; where something is implemented; where a symbol is defined and every place it is used or called; code matching a concept with no exact term to grep; code with a particular syntactic shape; or anything in a repo that is large, not checked out locally, at another branch or tag, or spread across several repos. Also use it whenever ccx, cocoindex-code-plus, or the query server or its MCP endpoint is mentioned. Skip it only for a literal one-token grep in a small checked-out repo, or for reading a file already at hand."
when_to_use: "Trigger phrases: 'how does X work', 'walk me through', 'explain the architecture', 'I'm new to this repo', 'where is X implemented/defined', 'who calls / uses X', 'find all references / call sites', 'find code that handles', 'search the codebase', 'on branch/tag Y', 'in repo Z', 'ccx', 'cocoindex-code-plus'."
---

# ccx — Query an Indexed Codebase (Semantic Search + AST Grep + Symbol Navigation + Ask)

`ccx` is the client CLI for **CocoIndex Code Plus**. It queries a codebase that a
**remote query server** has indexed — semantic search, AST structural grep,
symbol definitions/references, read-only file access, and (where enabled) a
cited written answer to a question — over HTTP. The CLI holds no index: results
describe the server's indexed snapshot, not your disk.

## When to reach for ccx

Reach for ccx **first** — before grepping and reading files — whenever the task
is to understand or find code. The server holds a resolved index of the whole
repo (and of other refs and other repos), so it answers in one call what local
tools reach only after a chain of greps:

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
  several indexed repos (`--repo`, repeatable for `search` and `ask`;
  `--git-ref`).
- **A question, not a lookup** — the deliverable is a written, cited
  explanation ("how does re-embedding get decided, end to end?", "compare auth
  in these two services"), or the question is too broad for one search or
  pattern → `ccx ask` (see below).

Local tools stay the right choice for exactly two things: reading a file that
is already at hand, and a plain literal-identifier lookup in a small repo you
have checked out — local `rg` answers that directly, and a `ccx grep` with no
structure (a bare identifier, no metavariable) just floods unstructured hits.
(But when the identifier question is really a *symbol* question — its
definition, or its true use sites rather than every textual occurrence —
`ccx defs` / `ccx refs` beat both.)

## Repo & ref scoping (applies to every query command)

- **Repo auto-detection.** Commands auto-scope to the repo of the current git
  checkout, detected from its `origin` GitHub/GitLab remote (resolved to an
  `<owner>/<repo>` name). Override with `--repo <owner>/<repo>` (repeatable for
  `search` and `ask`, up to the server's per-search cap). Without such an
  origin the command **errors** with guidance rather than guessing — pass
  `--repo`; `ccx repos` lists the indexed repos you can target, each with the
  refs it is indexed at as `<ref>@<commit>` (pass the part before `@` to
  `--git-ref`). There is no global "search everything" mode.
- **Ref defaulting.** Every query command is ref-scoped, and `--git-ref` is
  **optional everywhere**: when omitted, the server uses your checked-out branch
  if it's indexed, else the repo's default branch (an explicit `--repo` always
  gets that repo's default branch) — and prints a `Using git ref …` note to
  stderr so you know which ref answered (`ask` prints its `s0: … (commit …)`
  scope lines instead). Trust this
  default; there is no need to run `ccx git-refs` first just to discover a
  ref. Pass `--git-ref` only to target a *different* ref — a bare branch/tag
  name works (`main`, `v1.2`); the qualified `heads/<branch>` / `tags/<tag>`
  form is only needed when a branch and tag share a name. An unknown ref errors
  with the list of indexed refs.
- **The indexed ref is a commit snapshot.** Results describe the code at that
  commit, not your working tree — a `Using git ref …` note naming your own
  branch still means the commit the index holds for it. So when your checkout
  has uncommitted or unpushed changes, every path and line number can be stale,
  and a symbol you added since that commit is absent — that is not evidence it
  doesn't exist. Read the note, and confirm a specific location in your working
  tree before acting on it; when you need the exact commit that answered,
  `ccx git-refs` prints it per ref. Keep querying on a dirty checkout, though:
  locating existing code — the common case — survives a line-number offset.
- **CWD subtree scoping.** Run from a *subdirectory* of the checkout and
  `search`/`grep` default `--path` to that subtree (a stderr note names the
  glob). To cover the whole repo, run from the repo root or pass `--path '*'`.
  Don't mistake subtree-narrowed emptiness for "not in the codebase".

## Semantic search

Describe the concept, behavior, or functionality to find — not exact syntax.

```bash
ccx search "how are vector embeddings stored"    # auto-scopes to the current repo + branch
ccx search "user authentication flow"
ccx search "error handling retry logic"
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
  more). An empty or off-target page is a signal to rephrase the concept, or to
  widen a subtree-narrowed `--path` — not to page further.
- **A hit shows that code *talks about* your question, not that it *runs*.**
  Search ranks by resemblance to your words, so a doc, a default, a test, or an
  older or fallback implementation can outrank the code that actually does the
  work. "Where is X handled?" is settled by the hit itself — read it, stop if it
  does X. "Which code actually does X?" is settled by how the path *uses* the
  hit — as the thing it calls, or only as a fallback or one registered option —
  never by how well it reads. A caller already in the results may show it;
  otherwise see *Settling what runs* below.

```bash
ccx search "rate limiter" --repo acme/api --repo acme/worker
ccx search "connection pool sizing" --repo acme/api --git-ref main -k 10
ccx search parse config --lang python --path 'src/**'
```

Each result prints `[score] <repo> <file>` and the code with a line-number
gutter. To read more context around a hit, open the file with your normal file
tools (or, for a ref you don't have checked out, `ccx read-file` — see
remote-access reference).

## AST structural grep

`ccx grep` matches a **by-example pattern against the code's syntax tree (AST)**,
not text — so it ignores formatting and never matches code inside comments.
Requires `-l/--language`; `--path '<glob>'` narrows (repeatable); `-k`/`--limit`
(default 100) and `--offset` page, and a truncation note on stderr means there
are more matches.

```bash
ccx grep 'foo(\*)' -l python                  # foo(...) with any arguments: every call, and the def header
ccx grep 'def \_(\*) \*:' -l python           # every function def (async, decorated, `-> T` too)
ccx grep 'isinstance(\_, \_)' -l python --path 'src/**'
```

The essentials, in one breath: write the code you're looking for, and replace the
parts that vary with **metavariables** — `\` is the only special character. Five
forms cover nearly every pattern, and the two anonymous ones do most of the work:

| Form | Matches |
|---|---|
| `\_` | exactly **one** node, any — a single slot (a receiver, one operand) |
| `\*` | a **run** of zero-or-more sibling nodes — the usual choice inside `( )`/`[ ]`/`{ }` (`\+` one-or-more, `\?` optional) |
| `\/re/` | one node whose text matches the regex `re` (e.g. `\/get_.*/`) |
| `\NAME` | like `\_`, but *named* — only needed to report the capture, or reused later to require *equal* text (backreference) |
| `\{{ INNER \}}` | a node that *contains* `INNER` somewhere inside (any depth) |

Inside brackets, prefer `\*`: an argument list is several nodes, so
`cached_fn(\_)` matches only single-argument calls while `cached_fn(\*)` matches
them all. Reach for `\NAME` only when the name does work:

```bash
ccx grep '\_.filter(\*).map(\*)' -l rust           # a .filter(...).map(...) chain, any receiver
ccx grep 'catch (\E) \{{ throw \E \}}' -l typescript   # catch that re-throws the SAME var (backref \E)
ccx grep 'DenseMap<\_, \_>' -l c++                 # nested generic; structural, so >> just works
```

Two mistakes to avoid:

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
3. Check the scope — a stderr note about a CWD-subtree `--path` means you
   searched part of the repo; `--path '*'` widens.
4. Still nothing → the shape genuinely isn't there; pivot to `ccx search` for
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

## Symbol navigation (`ccx defs` / `ccx refs`)

Where is a symbol **defined**, and who **uses** it — answered from a resolved
symbol graph (cross-file, alias- and re-export-aware), not from text matching.
Covers **Python, TS/JS incl. TSX, C/C++, C#, and Rust**; for other languages
fall back to `grep`/`search`.

```bash
ccx defs QueryService                        # definitions of the base name
ccx defs python:db.Repo.find                 # exact qualified name (the ':' selects the mode)
ccx defs Config --kind class --lang python   # filter: --kind / --lang / --path
ccx refs QueryService                        # uses, by base name (broad recall)
ccx refs python:db.Repo.find                 # every use of this exact qualified name
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
src/api.py:88:12 [call]
  resolved  → src/db.py Repo.find  in handle_get
```

Three precisions of `ccx refs`, broad to exact:

- **Bare name** — `ccx refs NAME`: every definition with that unqualified
  name, plus unresolved mentions.
- **Qualified name** — `ccx refs python:db.Repo.find`: the name a `ccx defs`
  headline shows, every occurrence and overload under it. Every qualified name
  opens with its language tag (the CLI's errors say "pack-tagged"), so the `:`
  selects the mode — no flag needed.
- **One definition** — the pasted `uses:` command, `ccx refs PATH ENTITY_ID`.

Run the printed command — don't compose the second token yourself: the
headline's qualified name (`python:db.Repo.find`, module-qualified) is **not**
the entity id (`Repo.find`, file-relative). A lone argument that looks like half
of a forgotten pair (a path, or a dotted / `#`-suffixed id) errors with the fix
instead of running a broad query you didn't intend (`--base-name` forces name
mode when a base name genuinely contains such characters).

A dotted name without its tag (`Repo.find`, `QueryService.search`) is read by
`defs` as a base name and finds nothing: use the bare base name (`find`, with
`--kind method` to narrow) or the tagged name (`python:db.Repo.find`). Both
verbs page like `grep` (`-k`/`--limit`, default 100, and `--offset`); `refs`
has no `--path`, so set test files aside by eye.

Reading `refs` output — each row carries:

- a **role** (`call`, `import`, `type_use`, `inherit`, `implement`,
  `field_access`, `alias`, `decorates`, `use`) — filter with `--role`;
- a **resolution**: `resolved` is a definite reference, printed with its
  target in the same two-token `PATH ENTITY_ID` form, so any target you see
  pastes straight back into `ccx refs`; `ambiguous` means several candidates
  survived and each is its own row (the tool enumerates rather than guessing —
  so one source position can appear on several rows, and row count ≠ site
  count); `name_only`, printed `→ ~name`, is a mention whose target couldn't be
  resolved (an opaque receiver, an import the index could not place) — a
  candidate use to verify by reading the file (`--no-include-unresolved`
  drops these);
- possibly a `(via_alias)` marker: a supplementary row for the alias/re-export
  hop the primary reference went through.

**Check the stderr coverage note before trusting absence.** It reports when the
symbol index for this ref is *not built*, *skipped* (ref too large to resolve),
*partial* (some files failed to parse), or *at another commit than the ref's
indexed head* — in every one of those, a missing symbol may simply be
unindexed. Absence is not completeness.
A stale exact target (definition renamed/removed since the `defs` call) errors
and tells you to re-run `ccx defs` for a current target.

**Zero *resolved* rows is not proof of no callers.** A use the resolver could
not commit — an opaque receiver, an import across a Python source root the
index could not infer — appears as a `~name` row, never as a resolved one: read
those rows (`--role call` narrows them) as candidate uses and confirm by
opening the file; re-run without `--no-include-unresolved` if you dropped them.
A literal `No references.` with no coverage note is strong evidence, but where
`refs` cannot see at all — string keys, dynamic dispatch, an uncovered
language — `ccx grep` the call or registration shape before calling it settled.

**Settling what runs.** To confirm a candidate is the live path, look at its
uses, not its text: `ccx refs <candidate>` lists them, and reading one gives the
verdict. A plain call on the path confirms the candidate. `x or candidate()`
means the path's value comes from `x`, so the candidate is only a fallback — the
answer is upstream, in whatever supplies `x`; do not report the fallback as the
decider. An entry in a registry or dispatch table means configuration picks, so
name the key that selects it. Where `refs` can't see (string keys, dynamic
dispatch, an uncovered language), `ccx grep` the call or registration shape
instead; and when the question names an entry point, `ccx defs <entry>` and
walking down reaches the live code without ever weighing a look-alike hit.

## Ask a question, get a cited answer (`ccx ask`)

**Ask first when the deliverable is an explanation** rather than a location:
one `ccx ask` call replaces a chain of searches. Every command above returns
*material* — hits, matches, symbol rows — for you to read; `ccx ask` returns a
**written answer with citations**, because a server-side agent runs that chain
for you and writes up what it found. Reach for it on "how does X work end to
end?", "why does Y happen?", "walk me through the release flow", "compare A
and B" (above all across repos), and on any question too broad to reduce to
one search or pattern. When a question wants both — an explanation *and* every
call site — ask for the explanation, then settle "every" with `defs` → `refs`.
Scoping is the same as `search`: the current checkout by default, `--repo`
repeatable, `--git-ref` for a single repo.

```bash
ccx ask "how does the indexer decide what to re-embed?"
ccx ask "compare how these two services authenticate" --repo acme/a --repo acme/b --effort high
```

**Pick the effort level from the question's shape** with `--effort`: `low`
for a lookup with a known shape, nothing (the server default, usually
`medium`) for a how-does-this-work question, `high` for architecture,
comparison, and multi-repo questions. Higher levels let the agent take more
steps and run longer; they cost more and are worth it only when the question
needs the breadth.

What it costs: `ask` runs seconds to minutes, where `search`, `grep`, `defs`
and `refs` answer in a second or two — so when the deliverable is a **location
or code to read** (which file to change, where a symbol lives, its call
sites), stay with those. Run one `ask` at a time (the server caps concurrent
agentic requests), and do not wrap it in a shell `timeout` — the server
enforces its own deadline (ten minutes by default, twenty at `--effort high`);
if your own command runner has a shorter limit, raise it or run the call in the
background.

- **Read it as evidence, not proof.** Citations look like `[s0:path#L40-L52]`;
  `s0` resolves on stderr as `s0: <owner>/<repo> @ <ref> (commit <sha>)`, and
  the line numbers are at that commit. Before acting on a claim, open those
  lines at that commit — `git show <sha>:<path>`, or your working tree when it
  is at that commit; for a repo you don't have, `ccx read-file` with that
  `--repo`/`--git-ref` (the ref's indexed head — the same commit unless the
  index has moved since). Drop a claim its lines don't support; don't repeat it.
- **A forced answer may be incomplete.** When the agent runs out of steps or
  of room first, stderr says `this answer was forced` and the answer ends with a
  `## Not verified` section. Treat those items as open: check them with
  `search`/`grep`/`defs`/`refs`, or ask once more with `--effort high` (or a
  narrower question) — never repeat the same ask at the same level.
- **It may be off, busy, or out of time.** `agent_query_unavailable` means the
  deployment hasn't enabled it: answer with the other commands, tell the user
  their platform team decides, and don't try again this session.
  `agent_query_busy` (concurrency cap) and an `HTTP 503` `Request deadline
  exceeded` (the investigation outran the server's deadline): fall back to the
  other commands for this question — at most one later retry, narrower or at
  `--effort high` for the longer deadline, never a loop.

## Reading & listing files at a ref (remote / cross-ref)

`ccx read-file` and `ccx find-files` fetch file contents and paths at an indexed
ref. They're for code you **don't have on disk** — a repo not checked out locally,
or a **different ref** than your working tree. **When the repo is checked out at
the ref you care about, use your normal file tools instead** (faster, same bytes).
Full usage: [references/remote-access.md](references/remote-access.md).

## Repo & ref metadata

`ccx repos` lists the indexed repos you can target (alias, stable uid, default
branch, and the refs each is indexed at as `<ref>@<commit>`).
`ccx git-refs [<owner>/<repo>]` lists one repo's indexed refs with their full
commit shas (`(default)` marks the default branch) — reach for either to target
a non-default ref, or to see which commit a ref is indexed at, not as a routine
pre-flight; the ref default already handles the common case.

Note the two different senses of "ref": `ccx git-refs` lists **git** refs
(branches and tags), while `ccx refs` finds where a **symbol** is used.

## When ccx itself fails

Errors exit non-zero; notes (the ref used, subtree scoping, symbol coverage) go
to stderr and results to stdout — read both. Server and environment failures —
`HTTP 503` (index tables not built yet), `HTTP 401`, an expired login (the
error says `Run ccx login`), a connection error, or `ccx` not installed — are
the user's environment, not something to work around: **never invent a server
URL or token**; tell the user which piece is missing.
[references/management.md](references/management.md) has the symptom table,
and the mapping to the server's MCP tools for agents that have those instead
(`ccx ask` is `ask_codebase`).
