---
name: ccx-codebase-explorer
description: "Explore, navigate, and explain code with ccx. Use it before grep, rg, or file reads to find implementations, definitions, callers, references, code shapes, or how code works across files, branches, and repos. Use ccx show before reading a long file whole, and ccx show FILE:LINE instead of sed -n range reads to see a function. Use the change index before redoing listed work, for a test red on main, a line that looks wrong, or a symptom discussed before. Also use when ccx or cocoindex-code-plus is mentioned. Skip only a literal string in a file already at hand."
when_to_use: "Before repo searches or reading several files; where is X defined; who calls X; how does X work; architecture tours; other branches or repos; before redoing a brief; a test red on main; a suspicious line; a repeated symptom."
metadata:
  ccx-skill-revision: "2026-10-27.8"
---

# ccx — Query an Indexed Codebase (Semantic Search + AST Grep + Symbol Navigation + Ask)

`ccx` is the client CLI for **CocoIndex Code Plus**. It queries a codebase that a
**remote query server** has indexed — semantic search, AST structural grep,
symbol definitions/references, read-only file access, and (where enabled) a
cited written answer to a question — over HTTP. The CLI holds no index: results
describe the server's indexed snapshot, not your disk.

**Once per session, before your first `ccx` command**, run
`ccx skill-check 2026-10-27.8`. It prints nothing when this copy of the skill is
current; if it prints an update line, tell the user once and carry on.

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
  Objective-C, C#, Rust, Java, Go, and Kotlin.
- **Large / remote / multi-repo corpus** — the repo isn't checked out locally,
  you need a branch or tag other than your checkout, or the question spans
  several indexed repos (`--repo`, repeatable for `search` and `ask`;
  `--git-ref`).
- **You don't know which repo holds it** — "where is the code that …" across
  many repos, or a search here that finds nothing → `ccx repos --for "<need>"`
  ranks every indexed repo by how much of its code is about the need, with the
  nearest files; then search the top one or two.
- **Code in another repo** — a name this repo imports from a package another
  indexed repo builds, or a public name other repos call → `ccx deps`, then
  `ccx defs NAME --deps` / `ccx refs NAME --dependents` (see "Working across
  repos").
- **A question, not a lookup** — the deliverable is a written, cited
  explanation ("how does re-embedding get decided, end to end?", "compare auth
  in these two services"), or the question is too broad for one search or
  pattern → `ccx ask` (see below).

One command per question, from a checkout of the repo (no flags needed):

```bash
ccx defs <Name>                       # where is it defined — then paste the row's `uses:` command
ccx defs <A> <B> <C>                  # several names: one call, one line each (--body for bodies)
ccx refs <Name> --role call           # who calls it
ccx search "<what the code does>"     # no exact term to grep
ccx grep '<pattern>' -l <language>    # a syntactic shape
ccx grep --text '<regex>'             # an exact string or regex anywhere — comments, docs, config too
ccx show <file>                       # the file's outline, every definition at its line — before reading it whole
ccx show <file>:<line>                # the whole function or type around a line — not sed -n 'A,Bp'
ccx show <file> --lines A-B           # exactly lines A-B, numbered — not sed -n 'A,Bp'
ccx ask "<question>"                  # a cited written answer
```

**Opening a file: pick by what you hold.** `ccx show` reads your working tree,
so it is right on your branch, uncommitted edits included:

- **A window you can name** — lines a hit or a match already printed, an edit
  you just made → `ccx show FILE --lines A-B`, not `sed -n 'A,Bp' FILE`:
  the same lines, numbered, so a later edit or citation names the right
  line. Example: `ccx show src/app.rs --lines 120-160`. Add
  `--whole-definition` to get the definition holding the range instead,
  when it is small. Fall back to `sed -n` only when ccx fails.
- **About to run `sed -n 'A,Bp' FILE`, `head -n`, or a `grep -A40` to see a
  function body** → `ccx show FILE:A` instead. It prints the definition that
  contains line A, whole and with its signature, and folds what you did not
  ask for: on this box it sends about a fifth of the text a range read does,
  and you never cut a function in half or read the next window to finish it.
  Keep `--lines A-B` for a window you can already name (the first bullet).
- **A line, and you need the definition around it** — a search or grep hit, a
  traceback line → `ccx show PATH:LINE`: that definition whole, under its
  enclosing scopes, instead of a guessed window.
- **A name**, or a hit or `ccx defs` row in a file you have edited since the
  indexed commit (its line numbers have moved) → `ccx show -s NAME`: found by
  structure in your working tree.
- **Only the file** — named in the task, unfamiliar, or of unknown length →
  `ccx show PATH` (its header's `L1-L<n>` gives the length), then one of the
  above. A file you know is under about 200 lines: read it whole.
- **Not on disk, or at another ref** → the same targets with `--repo` or
  `--git-ref`, which request the indexed copy (*Files at a ref you don't have* below).

For this checkout's repository, a missing indexed file can use the local
file, including with `--git-ref`. If its header says `read from your working tree; not indexed
at <commit> (<reason>)`, treat it as local text, not that indexed commit.

Local tools stay the right choice for exactly two things: the reads the list
above gives them, and searching the files you edited or added since the
indexed commit (the snapshot rule below). A bare identifier is not a reason to grep locally;
ask which question it stands for. A *symbol* question — its definition, or its
true use sites rather than every textual occurrence — goes to `ccx defs` /
`ccx refs`, which answer it where `rg` cannot. A *text* question — an exact
string, a config key, a log message, a word in a comment or a doc — goes to
`ccx grep --text`, which searches every file of the indexed repo with no
language to name. A structural `ccx grep` with no metavariable is neither: it
floods hits.

## History: pull requests, issues and commits

Before you look up history with `gh` or `git log`, use the ccx command that
replaces the habit. ccx ranks by meaning (your words need not match the
title), prints each record's state (open, merged, closed) on the hit, and
spends no GitHub API quota, so it still answers when `gh` is rate-limited.

| Your habit | Use instead |
|---|---|
| `gh pr list --search "sidebar animation" --state all` | `ccx search --kind change "sidebar plays drop animations on restart"` |
| `gh pr list --state open --search "fix clippy"` (is a fix already in?) | `ccx search --kind change "<the failing test or error line>"`: it also sees merged fixes, which `--state open` hides |
| `gh pr view 2901 --json body`, `--comments` | `ccx show '#2901' --full` (the body whole, every comment and review; a PR or issue URL also works) |
| `gh issue list --state open --search "Main is red"` | `ccx search --kind change "Main is red" --state open --sort updated` |
| `gh pr list --search "renaming_session OR sidebar_layout_tests in:title"` | the same words: `ccx search --kind change "renaming_session OR sidebar_layout_tests"` reads `OR` and `in:title` as gh does, and sees merged fixes too |
| `gh search prs "rate limit breaker"` | `ccx search --kind change "GitHub calls fail with 403 until the reset"` |
| `git log --oneline --grep="landing"` | `ccx search --kind change "landing retries after a rate limit"` |
| `git log -S 'pub const FEATURES_10'` | `ccx log -S 'pub const FEATURES_10'` |
| `git log -L :keep_landed_evidence:…/workspace.rs` | `ccx log keep_landed_evidence` (`--patch` for the diffs) |
| "has someone already done this?" (reading PR lists) | `printf -- '- item\n- item\n' \| ccx prior -` |
| "who changed the code around this line, and why?" | `ccx refs <symbol> --kind change` |

Write the query as the symptom or the task, in plain words: what you saw or
what you are about to do. Paste an error line as it is; exact error text
counts. One query per question; read the top three hits.

**When to run it, without being asked:**

- **Before you start a fix or a listed task:** `ccx prior -`. A `near` hit
  that is `merged` means the work may already be on main: read it before
  you write code. For an issue number, `ccx show '#N'`: its `named by:`
  lines are the pull requests that fixed it, and a pull request's diff
  header says whether its landing commit is still on main or was reverted.
- **When a test or build fails on main:** `ccx search --kind change` with the
  first error line, and `ccx refs <test> --kind change --since 2d`.
- **When a line looks wrong:** `ccx log <symbol>`, then the PR it names.

**Reading the answer.** Each relevance-ranked change-search hit is labelled `near`
(worth reading) or `weak · not found` (no record answers the query). The closing `changes:`
line says the coverage: a numbered range (`#2200 to #3112`) means a `weak`
result is real absence; `insufficient` means the index cannot answer yet, so
fall back to `gh`. A hit records what its author wrote: check the current
code before you rely on it. The printed state is as of the last read; its
`state:` line checks it live.

For recent changes, use `ccx search --kind change --state open --since 2h
--sort updated`; omit `--state open` to include closed and merged records.
Read the header's `states as of` time before treating a poll as current.
If `ccx show '#N'` reports that N is outside the change index, use `gh`.

**Still use `gh` / `git` for:** CI runs and logs; repositories or dates
outside the coverage line; writing (comments, merges). `ccx log` and `ccx show --at <sha>`
read your clone, so they see any commit you have fetched; `--git-ref` takes
only indexed refs, never a sha.

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
  doesn't exist. When files in an answer differ in your checkout, stderr says
  so in one line (`your checkout is N commits behind the index …; K of the
  files in this answer differ locally`) and each such hit is marked:
  `[local differs]` — the line printed is your working tree's; `[local
  differs, line from index]` — it is the index's, so open it with `ccx show
  --git-ref <branch> PATH:LINE` or find it locally. Unmarked hits match your
  files. When you need the exact commit that answered, `ccx git-refs` prints
  it per ref. Keep querying on a dirty checkout, though:
  locating existing code — the common case — survives a line-number offset.
  On a feature branch the split is simple: ccx for the code your branch did
  not touch, which is nearly all of it; your own grep only for the files you
  edited or added since the indexed commit — `git diff --name-only
  <indexed-commit>` lists them, and `ccx repos` prints that commit.
- **CWD subtree scoping.** Run from a *subdirectory* of the checkout and
  `search`/`grep` default `--path` to that subtree (a stderr note names the
  glob). To cover the whole repo, run from the repo root or pass `--path '*'`.
  Don't mistake subtree-narrowed emptiness for "not in the codebase".
- **Areas: product code, tests and the rest.** Every row has an area —
  `code`, `test`, `test_support`, `bench`, `example`, `doc`, `mock`, `data`,
  `config`, `vendored` — and `search`, `grep`, `defs`, `refs` and
  `find-files` take `--only AREA` / `--exclude AREA` (comma-separated or
  repeated) and `--no-tests` (= `--exclude test,test_support`: one rule
  decides test code everywhere). By default test rows beside product rows
  fold into one `+ N … in tests; --tests lists them` line and take no page
  slot, so `-k N` lists N product rows; other areas are tagged (`[config]`,
  `[vendored]`; in `grep --text` once per file, at the end of its first
  line); when one area fills a page, stderr names the `--exclude` that
  clears it. With `--only`/`--exclude`, stderr says what the filter left
  off, so an empty answer is not proof of absence.
- **Which tests to run, and what a test covers.** `defs NAME` prints
  `tested by: N uses in K test files` and `run:` commands naming real test
  functions (`cargo nextest run -p …` where the repo has
  `.config/nextest.toml`, else `cargo test -p …`; `pytest …::…`; `go test
  … -run …`) — after changing that code, run those. With several
  definitions each row gets its own one-line `tested by: …; run: CMD`, and
  `ccx show PATH:LINE` / `show -s` print it right under the header, so no
  extra lookup is needed. The commands skip tests the repo keeps out of a
  plain run (`not run: 2 outside the default test filter (nightly only), 1
  quarantined`); do not add those back unless the change is about them.
  `N likely mentions by name` means the calls do not resolve (Rust
  methods): counted in test files tied to the definition, `(+M other)` are
  same-named calls elsewhere. `tested by: no tests; nearest: FILE (tests N
  siblings); setup: a, b` is where a new test goes and the helpers to build
  it with. `defs` of a test prints what it `exercises`, the code named like
  the test first: the product code to read when it fails. The tests of a
  symbol: `ccx refs NAME --only test,test_support`; `defs A B C` marks rows
  `(N test uses)`.
- **The tests for your whole change.** `ccx tests-for` maps your diff
  against its base to the definitions it changed and prints one command
  per runner that runs all their tests (a nextest `-E` filterset, pytest
  node ids, `go test -run`), plus the changed definitions no test uses;
  `ccx tests-for PATH:LINE` for one definition. Run it before you commit
  instead of guessing a filter or running the whole suite; the plugin
  prints the same command after an edit and before `git commit` or a ship.
- **A failing test.** After a red test run the plugin adds, per failing
  test, `ccx red-test`'s lines: the test's `PATH:LINE` (`new on this
  branch` when your branch added it), `failed in FN (PATH:LINE)` when it
  stopped in a helper or in product code rather than in the test's own
  body, `exercises A (PATH:LINE), B …` (for a new or changed test read
  from your working tree; `new` / `changed on this branch` marks your own
  code), then a fix already open or merged and the likely culprit PRs
  ranked by whether they `changed` what the test exercises. Read the
  `failed in` function and the exercised ones first (`ccx show
  PATH:LINE`); "no merge … changed these" means the cause is on your
  branch. `ccx red-test NAME…` (or test output on stdin) looks up the rest.

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
  widen a subtree-narrowed `--path` — not to page further. One result is one
  definition: `+ N more chunks of this definition: L356-L368` names its other
  matching chunks, for `ccx show PATH:LINE`. Docs, tests and mocks rank under
  code unless your words name them (`doc`, `design`, `test`, `mock`).
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
gutter. To read past a hit, *Opening a file* above applies: `ccx show PATH:LINE`
renders the whole definition around it.

## AST structural grep

`ccx grep` matches a **by-example pattern against the code's syntax tree (AST)**,
not text — so it ignores formatting and never matches code inside comments.
Requires `-l/--language`; `--path '<glob>'` narrows (repeatable); `-k`/`--limit`
(default 100) bounds the page. Files are scanned in a fixed shuffled order, so a
page is a sample of the repo, not its first files; a stderr note ending in
`--cursor <c>` means the scan stopped short — the page filled, or the server
stopped ahead of its deadline — and the same command with that `--cursor`
continues it. (For the text itself — comments and docs included — see
*Plain-text grep* below.)

```bash
ccx grep 'foo(\*)' -l python                  # foo(...) with any arguments: every call, and the def header
ccx grep 'def \_(\*) \*:' -l python           # function defs (async, decorated, `-> T` too)
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

### Plain-text grep: `ccx grep --text`

`--text` makes the pattern a **regular expression matched line by line against
the text of every file** in the ref — comments, docs, config and languages the
structural grep cannot parse included — and needs no `-l`. Output is one
`path:line:text` line per match; the line number is the one `ccx read-file
--offset` takes.

```bash
ccx grep --text 'retry_budget'                   # a word or phrase anywhere
ccx grep --text 'TODO|FIXME' --path 'src/*'      # a regex, scoped by path
ccx grep --text -w 'timeout' -l yaml -l toml     # whole word; with --text, -l is an optional filter
ccx grep --text -U '\)\s*\{' -l c++              # -U: a match may span lines (rg -U)
```

- **Reach for it when what you know is text**: a string literal, an error
  message, a config key, a word in a comment or a doc. A symbol's definition
  or uses → `ccx defs` / `ccx refs`; a code shape → structural `ccx grep`.
- **Smart case** by default: case-insensitive unless the pattern has an
  uppercase letter; `--case sensitive|insensitive` forces it. `-w`/`--word`
  matches whole words only.
- **ripgrep's regex dialect**: write the pattern as you would for `rg` —
  `\b`, `\w`, `\d`, `\s`, alternation, `(?i)`, `[[:alpha:]]`, `\p{…}` all
  work as there. Lookarounds and backreferences also work, on a slower
  engine (a warning says so). A plain word needs no escaping.
- **A match that must span lines needs `-U`** (`rg -U`): a brace on the next
  line (`\)\s*\{`), a signature wrapped over two lines, a call whose
  arguments continue on the next. Without it the pattern is matched line by
  line and `\s*` never crosses a line break, so the answer is zero. With it,
  `^` / `$` still mean line bounds and `.` still stops at a newline; `\s`,
  `[^;]` and `\n` cross one. Each line a match covers prints with its own
  number.
- **Cost**: a pattern with literal text in it is prefiltered in SQL and cheap;
  one with none (`.*`, a class alone), or whose only literal is in most files
  (`return`), scans every file of the ref — add `--path` on a large
  repository, and pass `-s` when case does not matter to the question (smart
  case folds a pattern with no uppercase letter, and that scan costs several
  times more).
- **A stderr note ending in `--cursor <c>`** means the scan stopped short:
  `more matches` when the page filled, `scan incomplete` (with a `warning:`
  line) when the server stopped ahead of its deadline — the matches you got
  are a sample of the repo. Rerun the same command with that `--cursor` to
  continue, or narrow it. An empty result with a `scan incomplete` note is not
  "no matches".

## Symbol navigation (`ccx defs` / `ccx refs`)

Where is a symbol **defined**, and who **uses** it — answered from a resolved
symbol graph (cross-file, alias- and re-export-aware), not from text matching.
Covers **Python, TS/JS incl. TSX, C/C++, Objective-C, C#, Rust, Java, Go, and Kotlin**; for
other languages fall back to `grep`/`search`.

```bash
ccx defs QueryService                        # definitions of the base name
ccx defs Repo.find                           # a member with its qualifier (C++/Rust: Store::fetch)
ccx defs python:db.Repo.find                 # exact qualified name (the ':' selects the mode)
ccx defs lookup:withDefault:                 # an Objective-C method: its full selector
ccx defs Config --kind class --lang python   # filter: --kind / --lang / --path
ccx defs answered refused Rig --path src     # several names in one call, not `ccx defs A; ccx defs B` or `grep 'fn A|fn B'`
ccx refs QueryService                        # uses, by base name (broad recall)
ccx refs Repo.find                           # uses of every definition the dotted name matches
ccx refs python:db.Repo.find                 # every use of this exact qualified name
ccx refs src/db.py Repo.find                 # uses of EXACTLY this definition (see below)
ccx refs QueryService --role call            # only calls (roles: call, import, type_use, …)
```

Imports of the name fold into a last line, `+ 50 imports in 48 files [alias];
--aliases to list`, beside the real definition; a Rust `mod x;` row names the
module's file (`module file: …`), which `ccx show` opens.

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

When `ccx defs NAME` finds one definition, its body follows the row: read it
there, with no second read. With several rows, `ccx show -s NAME` renders the
nearest one (*Opening a file* above).

Four precisions of `ccx refs`, broad to exact:

- **Bare name** — `ccx refs NAME`: every definition with that unqualified
  name.
- **Dotted name** — `ccx refs Repo.find`, `ccx refs db.Repo.find`, C++/Rust
  `ccx refs Store::fetch`: every definition whose qualified name ends with it
  (`python:db.Repo.find`). The natural spelling of a member; no tag, no flag.
- **Qualified name** — `ccx refs python:db.Repo.find`: the name a `ccx defs`
  headline shows, every occurrence and overload under it. Every qualified name
  opens with its language tag (the CLI's errors say "pack-tagged"), so the `:`
  selects the mode — no flag needed.
- **One definition** — the pasted `uses:` command, `ccx refs PATH ENTITY_ID`.

Run the printed command — don't compose the second token yourself: the
headline's qualified name (`python:db.Repo.find`, module-qualified) is **not**
the entity id (`Repo.find`, file-relative). A lone argument that looks like half
of a forgotten pair (a path, or a `#`-suffixed id) errors with the fix instead
of running a broad query you didn't intend (`--base-name` forces name mode when
a base name genuinely contains such characters).

`ccx defs` takes the same spellings: `ccx defs Repo.find` lists every
definition whose qualified name ends with `Repo.find`, where `ccx defs find` is
the bare base name (narrow with `--kind method`). Both verbs page like `grep`
(`-k`/`--limit`, default 100, at most 500, and `--offset`).

`refs` lists resolved uses first. Results with at most 60 rows include test
uses and unresolved mentions. Larger results end stdout with what they leave off:
`+ N in tests; --tests to list`, `+ N unresolved mentions of the name;
--include-unresolved to list`, then `… N more references past K; --offset K
for the next page.` Before saying a symbol has no other callers, rerun with the
flag those lines name. `--count` / `--by-file` give the totals without rows.

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
  candidate use to verify by reading the file, listed automatically in small results, or with
  `--include-unresolved` when a larger result hides them;
- possibly a `(via_alias)` marker: a supplementary row for the alias/re-export
  hop the primary reference went through.

**Check the stderr coverage note before trusting absence.** It reports when the
symbol index for this ref is *not built*, *skipped* (ref too large to resolve),
*partial* (some files failed to parse), or *still being built* for the ref's
newest indexed commit (the results describe the commit the note names, and
can differ from `grep`, `search` and `show`) — in every one of those, a
missing symbol may simply be unindexed. Absence is not completeness.
A stale exact target (definition renamed/removed since the `defs` call) errors
and tells you to re-run `ccx defs` for a current target.

**Resolved rows alone do not settle "no callers".** A use the resolver could
not commit — an opaque receiver, an import across a Python source root the
index could not infer — appears as a `~name` row, never as a resolved one: when
the output ends with `+ N unresolved mentions`, rerun with `--include-unresolved`
and read those rows (`--role call` narrows them) as candidate uses, confirming
by opening the file. A literal `No references.` with no coverage note and no
`+ N` line (the `Using git ref` line is not one) is strong evidence, but where `refs` cannot see at all — string keys, dynamic dispatch, an uncovered
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
ccx ask --parent 7e3a0012 "and where is that retried?"
```

**Follow up instead of re-asking.** When an answer printed a `follow-up:`
command on stderr and your next question builds on it — a detail, the next
step, or the reply to an answer headed `## Clarification needed` — run that
command with your question (`ccx ask --parent <answer-id> "<follow-up>"`):
the evidence is already in context, so the investigation is not repeated, and it needs no `--repo` (the
scope is the answer's). A `note: N observation(s) the earlier answer relied
on have changed since` line on stderr means the code moved under the
conversation: trust the new answer over the earlier one where they differ.

**Pick the effort level from the question's shape** with `--effort`: `low`
for a lookup with a known shape, nothing (the server default, usually
`medium`) for a how-does-this-work question, `high` for architecture,
comparison, and multi-repo questions. Higher levels let the agent take more
steps and run longer; they cost more and are worth it only when the question
needs the breadth.

What it costs: `ask` runs seconds to minutes, where `search`, `grep`, `defs`
and `refs` answer in a second or two — so when the deliverable is a **location
or code to read** (which file to change, where a symbol lives, its call
sites), stay with those. Run one `ask` at a time (past the server's cap,
a question waits in its queue).

**Where to run it.** `ask` prints a **first answer** in seconds — the
locations search and symbol lookup find, each with a short excerpt, labeled
and unverified — and, run by an agent (stdout not a terminal), exits there
with a `collect: ccx ask --collect <id>` line on stderr. The investigation
starts at your collect and answers in about a minute. Read the whole first
answer (no `| tail` or `| head`: its first locations are the definitions your
question named) and work from its locations. When you need the full answer,
run the `collect:` command: in the background when your harness wakes you on
completion and ending your turn does not end your run (Claude Code's main
conversation: `run_in_background: true` on the Bash call), so the notice
brings it; in the foreground otherwise (a subagent, a one-shot run), where a
background command dies with the run. `ccx ask --wait` waits for the full
answer in the one call. Don't wrap it in a shell `timeout`.

- **Read it as evidence, not proof.** Citations look like `[s0:path#L40-L52]`;
  `s0` resolves on stderr as `s0: <owner>/<repo> @ <ref> (commit <sha>)`, and
  the line numbers are at that commit. Before acting on a claim, open those
  lines at that commit — `git show <sha>:<path>`, or your working tree when it
  is at that commit; for a repo you don't have, `ccx read-file` with that
  `--repo`/`--git-ref` (the ref's indexed head — the same commit unless the
  index has moved since). Drop a claim its lines don't support; don't repeat it.
- **A forced answer may be incomplete.** When the agent runs out of steps or
  of room first, stderr says `this answer was forced` and the answer ends with a
  `## Not verified` section. Treat those items as open: when the notice ends
  with a `ccx ask --parent …` command, run it; otherwise check them with
  `search`/`grep`/`defs`/`refs`, or ask once more with `--effort high` (or a
  narrower question) — never repeat the same ask at the same level.
- **It may be off, busy, or out of time.** `agent_query_unavailable` means the
  deployment hasn't enabled it: answer with the other commands, tell the user
  their platform team decides, and don't try again this session — unless it
  answered a `--parent` and names the answer cache: then ask the question
  afresh without `--parent`, or retry shortly when it says so.
  A question past the server's concurrency cap waits in its queue (stderr
  says `queued, place N, about S s`); `agent_query_busy` means the queue is
  full, and `deadline_exceeded` that the investigation outran the server's
  deadline: fall back to the other commands for this question — at most one
  later retry, narrower or at `--effort high` for the longer deadline, never a
  loop. `investigation_not_found` from `--collect`: ask the question again.

## Reading files: what `ccx show` prints

*Opening a file* above says when; this is how to read the output. The outline
gives each function one row at its line —
`44~     async def put(self, row: Row) -> None: ... 4 lines` spans lines 44 to
47 — each type with its fields, docs by their first line, the imports as one
row. Each header includes where the text came from: `working tree`,
`working tree, differs from indexed <ref>@<sha>` (index line numbers for this
file have moved), or `indexed <ref>@<sha>`. A stderr note
`outline folded to depth 1: the full outline is N rows` means the file is
large and you got its items only, each container collapsed to its head and a
`// members:` roster: open one object with `ccx show PATH:LINE` next, or
`ccx show --depth 2 PATH` for one more level, rather than re-running with
`-e`. Test code (`#[cfg(test)]`, `Test*` classes, names with a test word) is
collapsed the same way in every outline.

```bash
ccx show src/app.py                    # the outline: every def and class at its line
ccx show src/app.py:142                # the definition at line 142 whole, doc included, under its enclosing scopes
ccx show -s QueryService               # a definition by name (what `ccx defs` finds), from your working tree
ccx show -e src/app.py                 # the whole file, numbered
```

Pasted headlines work as targets (`path:line:col` from `ccx defs`,
`path:line-line` from `ccx grep`). Flags, the `-s` listing rule and the
gutter: [references/remote-access.md](references/remote-access.md).

### Files at a ref you don't have: `ccx read-file` / `ccx find-files`

`ccx read-file` and `ccx find-files` fetch file contents and paths at an indexed
ref. They're for code you **don't have on disk** — a repo not checked out locally,
or a **different ref** than your working tree. **When the repo is checked out at
the ref you care about, use your normal file tools instead** (faster, same bytes),
routed by *Opening a file* above; nothing below applies then. There, too, a
whole file gets its outline first:

```bash
ccx show src/app.py --repo acme/api --git-ref v1.2        # request its indexed outline at that ref
ccx read-file src/app.py --repo acme/api --git-ref v1.2   # a file at a ref you don't have on disk
ccx find-files 'src/*.py' --repo acme/api --git-ref v1.2  # paths there, by glob (`*` spans `/`)
```

Line windows (`--offset`/`--limit`), paging, and case mode:
[references/remote-access.md](references/remote-access.md).

## Working across repos

`ccx deps` names the indexed repos this one depends on and the ones that
depend on it, read from package manifests (`pyproject.toml`, `package.json`,
`Cargo.toml`, `go.mod`) at each repo's default branch: the package, the version
requirement, and the manifest line's file. Two flags carry any query across
that edge, each repo at its default branch, under a `── <repo> (<role>) ──`
header:

```bash
ccx deps                                  # this repo: what it builds, depends on, is used by
ccx defs <Name> --deps                    # a name you import: its definition in the repo that builds it
ccx refs <Name> --dependents              # before changing a public name: its callers in other repos
ccx grep --text '<regex>' --dependents    # the same for any text, e.g. a config key or an import path
ccx search "<concept>" --deps             # one ranked list over this repo and its dependencies
ccx ask "<question>" --deps --dependents  # an answer that may follow the code into related repos
```

- **Before you change an exported name, signature or wire format**, run
  `ccx refs <Name> --dependents`. Your tests pass without those callers; theirs
  will not.
- **An import from a package this repo does not build** is not a dead end:
  `ccx defs <Name> --deps` reads the real definition at the dependency's
  indexed commit, not a guess or a stale copy under `site-packages` or
  `node_modules`. The requirement `ccx deps` prints says whether that commit
  is the version you pin.
- `--dependents` also covers repos that ship the same Python module under
  another package name (a fork or a vendored copy: the change reaches them when
  they sync) and the repos that use that copy. Headers say which is which; a
  repo "at the same commit as" another is a separate repo with the same code,
  and its uses count too.
- In a dependent repo, `refs` lists uses as `name_only`: matched by name, since
  the index does not resolve imports across repos. Read the import line before
  trusting a common name.

## Repo & ref metadata

`ccx repos --for "<what you need, in words>"` answers "which repo?" in one call:
the repos ranked by how many of the nearest code chunks are theirs (docs, tests
and recorded data count less), each with its nearest `file:line`s. A repo
"same code as" another is a fork or mirror. Use it before naming `--repo`s for
`search` or `ask` when the repo is not obvious, instead of guessing from names
or searching repo after repo. The answer lists a few repos on purpose: siblings
(a UI crate beside its engine) often both hold the code, and the nearest files
tell them apart.

`--repo` on `search` and `ask` takes a glob too: `--repo 'acme/*'` (or `'*'`)
searches the matching repos, and when more match than the per-query cap, the
ones `--for` ranks nearest to the query.

`ccx repos` lists the indexed repos you can target (alias, stable uid, default
branch, up to three refs it is indexed at as `<ref>@<commit>`, how long ago it
was indexed, and what the repo is in one line, from its manifest or README).
Read the last column before picking a repo by its name. With many repos, narrow it rather than scrolling: `ccx repos <text>`
(a case-insensitive name fragment, or a glob such as `'acme/*-api'`),
`--owner <owner>`, `--here` (this checkout's repo), `--sort recent|stale`,
`--json`.
`ccx git-refs [<owner>/<repo>]` lists one repo's indexed refs with their full
commit shas (`(default)` marks the default branch) — reach for either to target
a non-default ref, or to see which commit a ref is indexed at, not as a routine
pre-flight; the ref default already handles the common case.

Note the two different senses of "ref": `ccx git-refs` lists **git** refs
(branches and tags), while `ccx refs` finds where a **symbol** is used.

## When ccx itself fails

On `index_in_progress` (an `HTTP 503` whose message says `is being indexed`), use native tools and do not retry before the time the error names (`retry in …`).

Errors exit non-zero; notes (the ref used, subtree scoping, symbol coverage) go
to stderr and results to stdout — read both. Server and environment failures —
`HTTP 503` (index tables not built yet, or the repo is being indexed), `HTTP 401`, an expired login (the
error says `Run ccx login`), a connection error, or `ccx` not installed — are
the user's environment, not something to work around: **never invent a server
URL or token**; tell the user which piece is missing. A command this skill
names that your `ccx` lacks (`No such command`) means the CLI predates this
copy of the skill: do that step with your own tools and tell the user once.
[references/management.md](references/management.md) has the symptom table,
and the mapping to the server's MCP tools for agents that have those instead
(`ccx ask` is `ask_codebase`).
