# Upgrading CocoIndex Code Plus

How to move a deployment from one release to the next. This page is the
place to check before every upgrade: releases that need anything beyond the
upgrade command have an entry below, newest first.

## Complete small lookup results

Upgrade the CLI and server together. Requested definitions now retain nested
code up to 400 lines or 16 KiB. File outlines keep their compact budget.
Text grep keeps pages with at most 60 hits complete. Small reference results
include tests and unresolved mentions. Use `--no-tests` or
`--no-include-unresolved` to exclude those rows explicitly.

Default CLI search now requests code and preserves similarity order.
Exact record numbers and URLs retain record lookup.
Use `--kind all` to request the change section. File outlines omit change
annotations; selected definitions show only recent symbol-level changes.
No schema migration or index rebuild is required.

## Compact show and text grep output

Upgrade the CLI and query server together. Default show output now folds large
bodies and outlines. Use `--full` for the expanded object, or `--lines A-B` for
an exact source range. An ambiguous `show -s` renders one match and lists alternatives.
Text grep defaults to 30 displayed matches, with at most 10 per file.
Use explicit `-k N` to disable sampling. REST and MCP grep defaults remain unchanged.
Refs now reports test-only unresolved mentions in both hidden counts.
Enable `--tests --include-unresolved` to list them.
Concrete reference targets precede same-named import aliases.
No schema change or index rebuild is required.

## Hybrid change search lexical ties

Hybrid retrieval now prefers newer creation times when lexical scores are equal.
Set `changeIndex.recencyTiebreak: false` to restore the previous lexical tie
order. Vector retrieval and automatic reranking keep their current defaults.
No schema migration or index rebuild is required.

## Local fallback after an indexed file miss

Upgrade the CLI and query server together. `ccx show PATH` now uses the
current checkout's file after an indexed file miss, including an explicit
ref request. It applies only to this checkout's repository. The header
identifies local text and names the failed read's commit and reason.
Read that header before treating output as the requested indexed ref.
No schema change or index rebuild is required.

## Indexed record lookup and filtered change lists

Upgrade the CLI, query server, and indexer together. A search query containing
only `#N` now selects that indexed record. Use `--kind code` to search code
for a number instead. `ccx show '#N'` and PR/issue URLs read the change index.

Change search adds `--state`, `--since`, and `--sort`. An empty query requires
`--kind change` and a filter. State/date conditions apply before ranking and
pagination. Date order uses title/body text matching when a query is present.

`ChangeFreshness.states_as_of` reports the earlier completed issue/PR listing
check. The indexer stores these times in existing cycle statistics. Until a
new cycle completes both listings, the CLI uses the earlier content watermark.
No schema migration, rebuild, or manual database step is required.

## Change search relevance comes from the server

Upgrade the CLI and server together. Change search now returns `relevance`
and `ranking` per hit. Clients must display the server assessment instead
of comparing `score` with `change_freshness.near`. The vector score keeps
its previous meaning. Automatic retrieval uses hybrid by default and vector
candidates when optional reranking is enabled. Reranking is off by default.
No database migration or index rebuild is required.

## Change-hit host state

Change hits add `state`, `merged_at`, `closed_at` and `read_at`. The indexer
adds nullable columns at startup without rebuilding stored content or vectors.
Start the new indexer before the new query server. Existing records show unknown
state until the automatic upgrade pass reads them. Each read refreshes state,
including unchanged text.
The CLI shows stored state and prints a command for live checks when its
observation predates the last sweep, or when state or sweep coverage is unknown.

Status shows one change-index line per repository. `ccx log Type.method` uses
the same name resolution as `ccx defs Type.method`.

## Change-index touched sets

The indexer now fills changed-file rows, symbol touches, and diff hunks.
Search hits and change references read these rows. Indexed `ccx show` output
also shows touched-by annotations. A touch identifies a proposal; it does not
prove that the proposal merged.

Startup adds the state columns first, then the nullable `change_meta.touch_key`
column. Both steps are additive and run in one schema transaction. Existing content
and usage history remain intact. The automatic upgrade pass fills old records
without embedding their unchanged text again. No manual database step is required.
Mirror-backed repositories read local git diffs. App-backed repositories use
GraphQL file and blob reads within the existing quota reserve.

## Existing change records upgrade automatically

Stored records with missing state are stale. Pull requests with a missing
touched-set key are stale too. The indexer reads them oldest-updated first,
after new and updated records, within `maxRecordsPerCycle` and the GraphQL
reserve. It batches these reads like backfill. Host timestamps and listing
cursors do not prevent this upgrade pass.

`ccx status` shows `upgrading N records to schema 3` until the remaining count
reaches zero. The count remains visible when the GraphQL reserve stops a cycle.
The indexer retains embeddings for unchanged text and reads mirror-backed
touched sets from local git. The pass runs automatically on normal refreshes.

## Test-aware search and grounded answer citations

Search now prefers implementation code unless the query asks about tests.
Use `ccx search --tests` to keep similarity order with tests included, or
`--no-tests` to exclude test candidates. REST and MCP expose nullable `tests`.
Scores remain raw cosine similarities; default ordering can differ from them.

Agent answers now use observed citation spans. Unsupported coordinates become
`line range unverified`. The CLI marks citations for changed local files.
The answer-cache logic epoch advances; older answers are recomputed. Stored
usage history remains intact. No operator migration is required.

## The normal upgrade

Every release ships as a new chart version with matching images. The upgrade
is one command, and the index is never rebuilt by an upgrade:

```bash
helm upgrade ccx oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus \
  --version <X.Y.Z> -n ccx -f values-secret.yaml
```

Release name, namespace, and values file are the quickstart's; substitute yours.
Both workloads roll. The singleton indexer restarts once (indexing pauses for
the restart; the query server keeps serving), so pin `<X.Y.Z>` deliberately.
`helm rollback` works as usual.

Versioning is lockstep: the chart, the images, and the `ccx` CLI share one
version number. Upgrade the CLI alongside the server
(`uv tool install -U cocoindex-code-plus`; [cli.md](cli.md) has the details
and the symptoms of a CLI that is too old). From 0.1.60 on the CLI tells its
users itself: after the server upgrade, the next command of an older CLI
prints the upgrade command, so no announcement is needed for the CLI.

## Reading the entries

- **An entry is written for the release right before it.** When you skip
  releases, apply the entries you skipped from oldest to newest.
- **A release without an entry needs nothing but the command above.**
- Each entry says what changed, what to do (before or after the command), how
  to verify, and what is optional.

## Next release — one search result per definition, imports folded

Upgrade the CLI and server together; no database change and no re-index.

- **Search.** Chunks of one function, method or type merge into one result;
  the others are in its `more_chunks` (`+ N more chunks of this definition`
  in the CLI). `top_k` and `offset` now count definitions, so a page holds
  more distinct code. Clients that paged by chunk see fewer, merged results.
- **`find_definitions`.** Imports and re-exports (`alias` rows) beside a
  real definition are counted in `alias_count` / `alias_file_count`
  instead of listed; pass `include_aliases: true` (`ccx defs --aliases`)
  to list them. A Rust `mod x;` row gains `module_file`.
- **`show`.** A cut response says what it left out: `omitted_lines` on the
  cut object, `dropped_objects` / `dropped_from_line` for objects left off.

## Next release — checkout drift notes

Upgrade the CLI; no server or database change. In a checkout whose files
differ from the indexed commit, code commands print one stderr line saying how
far the checkout is from the index, and mark hits in differing files
(`[local differs]`, `[local differs, line from index]`). A remapped hit prints
the working tree's line number.

`ccx indexed --json` changes in place: `local_diff` now holds
`changed_count` and `untracked_count`; pass `--files` to also get the
`changed` and `untracked` path lists it used to carry. It also adds `head` and
`head_line`. Scripts that read the lists add `--files`.

## Next release — index files up to 4 MiB

The default indexed file size increases from 1 MiB to 4 MiB.
The first pass reads newly admitted files and embeds their chunks.
The symbol extraction ceiling also changes, so existing files extract symbols
once more. Existing content-keyed embeddings remain reusable.

No manual data migration is required. To retain the previous size policy, set
`indexer.maxFileSizeBytes: 1048576` before upgrading. Repo `max_file_size`
values still override this default. Read larger files through `read-file`
`--offset` / `--limit` windows; each window keeps its 1 MiB content cap.

## Next release — query coverage notes

Upgrade the CLI and server together. No manual database step is required.
The indexer adds a nullable column for file-gap diagnostics at startup.
Existing rows remain valid; older rows can report an unavailable skip reason.
The next walk fills diagnostics without re-embedding unchanged code.
The derived answer-cache logic epoch advances, so old answers are not reused.
Collected usage history remains in place.

Exact skipped-file queries now return `file_not_found` with reason
`not_indexed`, instead of a successful empty match or definition page.
Read the error detail for the file, reason, and local grep fallback.
Explicit change queries retain freshness notes even for empty results.
See [When an index cannot answer](cli.md#when-an-index-cannot-answer).

## Next release — Rust navigation and bounded grep output

Upgrade the CLI and server together. `ccx show -s NAME` now lists ambiguous
matches instead of rendering several bodies. Add a file path after the name,
or open one listed position with `ccx show PATH:LINE`.

Structural grep now caps each displayed hit at 40 lines and 4096 bytes.
API consumers use `code_truncated` to detect a cut; `start_line` and `end_line`
still describe the complete match. File-scoped reference lookup can return
`candidates` when a bare method name has several definitions. Select a candidate
and retry its exact `path` and `entity_id`.

## Next release — change ingest GraphQL reserve and mirror reads

Change ingest reserves 1500 GraphQL points by default for other applications.
Set `changeIndex.graphqlReserve` in Helm, or `graphqlReserve` in `CCX_CHANGE_INDEX`.
Zero disables this guard. A reserve stop or throttle skips the cycle until a later refresh.
Token sources use local mirror commits for merge bases and avoid REST content reads on the normal path.
Quota metadata checks use REST `GET /rate_limit`, which costs no primary REST quota.
The App source retains its installation-permissions and compare reads.

The indexer adds a `partial` column to change metadata at startup.
This additive migration preserves existing change rows and usage history.
A throttled optional REST read stores available content and marks the record partial.
The next cycle retries the record; coverage reports `reason=partial` until repair completes.
Review anchors now use GraphQL positions, including null positions on outdated threads.
Upgrade the CLI and server together for the new coverage reason.

## Next release — change ingest budget validation

Enabled change ingest now rejects budgets with fewer than two reads outside the reserved sweep.
Such budgets previously stall active work or starve one of its passes.
Increase `changeIndex.maxRecordsPerCycle` or reduce `changeIndex.sweepShare` when startup names this combination.
The default values remain valid. Disabled change ingest requires no action.

## Next release — optional change content ingest

The feature defaults to off. Normal upgrades require no change.
The indexer creates six change content tables when `changeIndex.enabled` is true.
Existing code rows, usage history, and answer cache rows remain in place.
A startup marker records the embedding model and vector dimension.
Changing them requires a change-vector migration; startup names the previous model and refuses mixed vectors.

Before enabling change ingest, add **Issues: read** and **Pull requests: read**
to the indexer's GitHub App. Approve the added permissions on each installation.
Then set `changeIndex.enabled: true` and add `changes.enabled: true` to selected repository entries.
A local git entry also needs `changes.from`; a code-host entry must omit it.
See [Change content ingest](deploy.md#change-content-ingest) for settings and exposure rules.

The repository's `changes` status row names a missing permission or refused credential.
The next refresh retries change ingest; code indexing continues for every repository.
A refused credential leaves the existing change index unchanged.
Turning off an entry removes its change rows; re-enabling starts a new backfill.
GitLab change ingest does not ship in this slice.

## v0.1.74 — the Claude Code plugin installs as `ccx@ccx`; the internal state database works behind a connection pooler

Nothing is required for most deployments. Read on if your rollout doc or
your managed Claude Code settings install the `ccx` plugin, or if the
indexer reaches its internal state database through a connection pooler.

### The plugin installs as `ccx@ccx`

- **What changed.** The plugin marketplace in
  `cocoindex-io/cocoindex-code-plus-pub` is named `ccx`. It was `cocoindex`,
  which the CocoIndex library's own marketplace also uses, and Claude Code
  refuses a second marketplace of the same name. The rename is live in the
  repository from 2026-10-23, ahead of this release; the add command is
  unchanged.
- **What to change.** A rollout doc that says
  `/plugin install ccx@cocoindex` fails at that step for a new user: change
  it to `/plugin install ccx@ccx`. Managed settings that declare the
  marketplace under `extraKnownMarketplaces` as `cocoindex`, or enable
  `ccx@cocoindex` under `enabledPlugins`, change the key to `ccx` and the id
  to `ccx@ccx`.
- **Developers who installed `ccx@cocoindex`** keep receiving updates under
  the old name. From this release on, the plugin's hook tells each of them
  once a day, as a warning in the session, to move with three commands —
  [cli.md → For agents & automation](cli.md#for-agents--automation), under
  "Installed as `ccx@cocoindex`?".
- **Verify.** In Claude Code, `/plugin` → **Installed** lists `ccx@ccx`.

### The internal state database behind a connection pooler

This applies if the indexer reaches its internal state database
(`CCX_INTERNAL_DB_URL`) through a connection pooler: PgBouncer, a
provider's pooled connection string, or Cloud SQL Managed Connection
Pooling. A direct connection is not affected, and neither is the Cloud SQL
Auth Proxy on an instance without Managed Connection Pooling.

- **What changed.** The engine keeps the indexer's internal state in
  `CCX_INTERNAL_DB_SCHEMA` (default `ccx_internal`). It used to select that
  schema with a connection startup parameter (`search_path`), which a
  default PgBouncer refuses: the indexer failed at startup with
  `unsupported startup parameter in options: search_path`. From
  cocoindex-plus 1.0.62 the engine writes the schema into every table name
  and sends no startup parameter, so the internal database works behind a
  pooler, in session or transaction pooling.
- **Before you upgrade, if a pooler was already in front of the internal
  database.** A PgBouncer with `ignore_startup_parameters = options`, or
  with `track_extra_parameters = search_path` against Postgres 17 or
  earlier, accepted the parameter and dropped it, so the internal state went
  to the `public` schema instead. Check where it is:

  ```sql
  SELECT schemaname FROM pg_tables WHERE tablename = 'cocoindex_meta';
  ```

  `ccx_internal` (or your `CCX_INTERNAL_DB_SCHEMA`) needs nothing. `public`
  means the state must move before the new release starts. Otherwise the
  indexer starts over in the empty schema: its first pass is a
  bootstrap-scale run, embeddings included, and the old state stays unused.
  Stop the indexer, move the tables, then upgrade. Don't start the old
  release in between: it would find nothing in `public` and start over
  there.

  ```bash
  kubectl -n ccx scale deploy/ccx-cocoindex-code-plus-indexer --replicas=0
  ```

  Then, as the indexer's role (it owns the tables; adjust `ccx_internal` if
  you overrode `CCX_INTERNAL_DB_SCHEMA`), move the tables `cocoindex_meta`
  lists, then `cocoindex_meta` itself. Other tables in `public` stay:

  ```sql
  BEGIN;
  DO $$ DECLARE t text; BEGIN
    FOR t IN SELECT c.tablename FROM pg_tables c
             JOIN public.cocoindex_meta m ON m.key LIKE 'app:%'
              AND starts_with(c.tablename, 'app_' || (m.value->>'table_prefix') || '__')
             WHERE c.schemaname = 'public' LOOP
      EXECUTE format('ALTER TABLE public.%I SET SCHEMA ccx_internal', t);
    END LOOP;
  END $$;
  ALTER TABLE public.cocoindex_meta SET SCHEMA ccx_internal;
  COMMIT;
  ```

  Run the upgrade command, then start the indexer again (a no-op if the
  upgrade already did):

  ```bash
  kubectl -n ccx scale deploy/ccx-cocoindex-code-plus-indexer --replicas=1
  ```

- **Cloud SQL Managed Connection Pooling.** In its default transaction mode,
  set the pooler's `max_prepared_statements` flag above 0, or switch the
  pool to session mode. The engine uses prepared statements, and the default
  of 0 makes them fail under load (`prepared statement "s10" does not
  exist`). PgBouncer has them on by default since 1.24.
- **Verify.** The query above returns your `CCX_INTERNAL_DB_SCHEMA`, and the
  first indexer pass after the upgrade takes about as long as a normal pass,
  not as long as the initial one.

## v0.1.73 — `ccx grep --text -U`: a match may span lines; `text_grep` matches carry `end_line`

Nothing is required: upgrade normally, and upgrade the `ccx` CLI with it.
Read on if a script or an MCP client of yours reads `text_grep` matches.

- **What changed.** `ccx grep --text -U` / `--multiline` is ripgrep's `-U`:
  the pattern may match across lines — `^` / `$` still mean line bounds and
  `.` still stops at a newline, while `\s`, `[^;]` and `\n` cross one — so
  `\)\s*\{` finds a brace on the next line. The REST body and the MCP tool
  `text_grep` take `multiline` (default `false`, the behaviour so far), and
  every match now carries `end_line` beside `line`: equal to `line` without
  `multiline`; with it, the match covers `line`..`end_line` and `text` is
  those lines joined by newlines. The CLI prints each covered line with its
  own number.
- **Verify.** `ccx grep --text -U '\)\s*\{' -l c++ -k 3` on a repository in
  the brace-on-its-own-line style prints two-line matches; the same command
  without `-U` prints only same-line braces.
- **Expected after the upgrade.** Every ref's symbol step resolves every
  module again, because the resolver's behavior changed for Rust: an
  `impl Foo` written apart from `struct Foo` now reaches `Foo`'s members, and
  `#[path = "x.rs"] mod foo;` names the file the attribute gives. That step
  takes about as long as it did on the initial pass; nothing is re-read from
  the code host and nothing is re-embedded. `ccx defs` / `ccx refs` on Rust
  code answer from the old resolution until the pass ends.
- **Rust fixes in the engine.** A structural `ccx grep` pattern like
  `SessionView { \* }` matches struct expressions and patterns, and no longer
  matches an impl or struct declaration or a function's return type. In
  `ccx show`, a position inside a value or a body block opens the nearest
  enclosing declaration.
- **The license check reuses its cached answer for a day.** A standard
  license is still validated against `api.keygen.sh` at a container's first
  start, but a process that restarts within 24 hours on a host that keeps its
  disk no longer sends a request. Nothing changes for a cluster whose
  containers start empty. `COCOINDEX_PLUS_LICENSE_REVALIDATE_AFTER` (seconds;
  `0` restores a request at every start) tunes it — [License key](deploy.md#license-key).
- **Structural `ccx grep` is faster, and its parallelism follows the query
  server's CPUs.** The server parses candidate files on one thread per CPU
  the container may use (its cgroup limit, else the node's count; before, a
  flat eight), and reads the next batch of files while the current one is
  being parsed. A pattern whose only literal is a keyword (`catch (\_ \_) { }`,
  `for (int \_ = 0; \_ < \_; \_++) { delete \_; }`) no longer parses every
  file of the language: a file without the keyword is skipped before the
  parse. **What to check:** a `queryServer.resources.limits.cpu` of `1`
  now means one parse thread; give the query server the CPUs you want a
  large grep to use (4 to 8 on a monorepo). `CCX_GREP_PARSE_THREADS` through
  `queryServer.extraEnv` caps the threads below the limit when the server
  shares its CPUs — [Query server CPU](deploy.md#query-server-cpu).

## v0.1.71 — text_grep: the index lookup is bounded, so a case-insensitive pattern of common words can no longer spend the whole deadline before the scan

Nothing is required: upgrade normally. Read on if `ccx grep --text` on a
large repository answered `503 Request deadline exceeded` or a warning
ending in `after 0 files` whose cursor made no progress.

- **What changed.** The lookup that asks the text search index which files
  hold the pattern's literals now runs under a budget (a fifth of the time
  left, at most 10 s). When every literal is in most files, the lookup gives
  up and the scan takes over with the rest of the deadline, returns its
  matches so far and a cursor that makes progress. A warning names the
  abandoned lookup. A scan that could scan nothing in the time left now says
  that a retry with its cursor repeats the same work, and names the levers
  (`--path`, a rarer literal, `-s`) instead of advising a retry.
- **The scan itself is several times faster.** Each file is searched once as
  a whole before its lines are visited, so files without a match — nearly all
  of them, for most patterns — cost one search instead of one per line. A
  full scan of a large repository that took a minute takes seconds; the
  deadline stop and the cursor still cover what does not fit.
- **The pattern is read in ripgrep's dialect.** `ccx grep --text` now matches
  with the same regex engine `rg` uses: everything `rg` accepts works as
  there, and the engine never backtracks catastrophically. POSIX classes
  (`[[:alpha:]]`), `\z` and Unicode classes (`\p{Greek}`) work now; `\Z`
  does not (write `\z`). A pattern with a lookaround or a backreference still
  works, matched by the previous engine with a warning that it is slower.
- **Verify.** `ccx grep --text 'return.*null.*delete.*cast.*assert' --path '*' -k 5`
  on a large repository returns inside the deadline with a cursor, and the
  same command with that `--cursor` scans further.

## v0.1.70 — grep pages by cursor in a shuffled scan order; a scan the deadline would end returns its matches so far; `ccx repos` batches GitHub permission checks

Nothing is required in the deployment: upgrade normally, and upgrade the
`ccx` CLI with it. Read on if a script or an MCP client of yours pages
`ccx grep`, `code_grep` or `text_grep` results, or if `ccx repos` and the
Insights views are slow under `authz.mode: codeHostMirrored` on GitHub.

### What changed

- **Paging is by cursor.** `--offset` is gone from `ccx grep` (both modes);
  the CLI prints `… continue with --cursor <c>` on stderr when a scan stopped
  short, and the same command with that `--cursor` resumes it. The REST
  bodies and MCP tools `code_grep` / `text_grep` take `cursor` instead of
  `offset` and answer `next_cursor` (`null` once the ref is scanned). A
  request body still carrying `offset` is refused with `400`, not ignored.
- **Matches come in a fixed shuffled order** (files by a hash of the path,
  lines in file order), not by path. A page is a sample of the ref; sort the
  output yourself when you want path order.
- **A grep that cannot finish inside the server's deadline answers with its
  matches so far**, a `next_cursor` and a `warnings` entry naming the levers
  (a `--path` glob, a rarer literal, `-s`), instead of a `503`. `text_grep`
  responses gain `warnings` (`code_grep` already had it).
- **`-i` / `-s`** are new short forms of `--case insensitive` / `sensitive`
  on `ccx grep --text`.
- **Inside `ccx ask`, one grep tool call scans for at most 30 s**
  (`agentQuery.grepCallBudgetSeconds`; see [deploy.md](deploy.md#agentic-query))
  and then returns its matches so far with a cursor; the agent continues or
  narrows. Before, such a call could run until the whole query's deadline.
- **`ccx repos` under `codeHostMirrored` on GitHub settles most permission
  checks in its batched lookup, and the lookups run in parallel.** When the
  authz App's installation grants **Organization → Members: Read-only**,
  one GraphQL request per 32 repositories answers the caller's permission
  on each, up to 8 requests in flight per installation with every installation
  at once, so a cold walk takes a few round trips instead of one per
  repository or one per batch; public repositories cost nothing either way.
  Without the grant the walk still batches the repository facts (one
  permission call per private repository remains) and the query server logs
  one warning per installation naming the grant.
  [deploy.md § App permissions](deploy.md#app-permissions) has the details;
  the Insights views that list repositories share the walk and speed up with
  it.
- **`authz.listReposCheckConcurrency` now bounds per-repo calls, not
  checks.** A walk dispatches a whole page of checks at once; the value
  (default 10) is how many per-repo provider calls — refusals, and private
  repositories under an installation without the grant — run at a time.
  Batched lookups are outside it. A value you raised to speed up the walk
  can go back to the default.
- **Every audit line carries `provider_calls`, `provider_ms` and
  `provider_busy_ms`**: how many code-host calls the request made, their
  summed duration, and the wall time at least one was in flight. A slow
  request shows at a glance whether it waited on the code host, and whether
  in series or in parallel ([security.md](security.md#logging--audit)).

### What to do

- Scripts that page `ccx grep` with `--offset`: read the cursor from the
  stderr note (or `next_cursor` from the API) and pass it back.
- Agents using the MCP tools pick the change up from the tool descriptions;
  the published skill is updated with this release.
- Optional, GitHub `codeHostMirrored` deployments: grant the authz App
  **Organization → Members: Read-only** on each approved org (org-level SAML
  mapping already requires it) and approve the updated permission on the
  installation. No restart is needed: the next token mint sees the grant.

### Verify

`ccx grep --text 'return' -k 5 --path '*'` on a large repository returns in
about a second with a `… more matches; continue with --cursor …` line.

## v0.1.60 — Objective-C symbols; the indexer no longer reuses config-walk cache entries from before v0.1.54

Nothing is required: upgrade normally, and upgrade the `ccx` CLI with it
(an older one looks up an Objective-C method's name as a qualified name and
finds nothing). The first indexer pass after the upgrade walks every
repository again and resolves every symbol again. Read on if your indexer
crash-loops on v0.1.59 with `KeyError: 'fields'`, or if your deployment was
first installed before v0.1.54.

### Objective-C symbols

- **`ccx defs` / `ccx refs` and the MCP `find_definitions` /
  `find_references` tools cover Objective-C**: `.m` files, and `.h` headers
  written in Objective-C. Objective-C++ (`.mm`) is not covered yet.
- **Names share C/C++'s `cpp:` tag**, since Objective-C code calls the C
  functions its headers declare. A class's `@interface`, `@implementation`
  and categories are one class.
- **A method is named by its full selector**, and that is the name to look
  up: `ccx defs formatCents:withSymbol:` finds
  `cpp:Wallet.formatCents:withSymbol:`. `formatCents` alone finds nothing.
- **C/C++ lookups are more accurate.** A class forward-declared in several
  headers answers once, and a method a class inherits resolves to the
  base's out-of-line definition, not only to its declaration in the header.

### The config read on deployments installed before v0.1.54

On a deployment installed before v0.1.54 whose config files had not changed
since, v0.1.59 could crash the indexer at every start:

```
  File ".../cocoindex_code_plus/indexer/config.py", in parse_repo_configs
    cfg = entry["fields"]
KeyError: 'fields'
```

preceded by `Dir.accept: 1 total | 1 unchanged`. The indexer caches the
result of reading the config repository, so an unchanged config costs no
code-host API calls per refresh. v0.1.59 changed what that read produces,
and a cache entry stored by a release older than v0.1.54 was reused as if it
were current. v0.1.60 caches only each config file's text, keyed by its git
blob, and parses every file afresh on each refresh, so a cached entry can
never disagree with the running release again.

### The first pass after the upgrade

- **It walks every repository again.** It reads every file from the code
  host and parses it again, symbol extraction included, so Objective-C files
  gain their symbols. The pass takes longer than a usual one and uses more
  code-host API quota
  ([What a settings change redoes](deploy.md#what-a-settings-change-redoes)).
  Nothing is re-embedded.
- **Every ref's symbol step resolves every module again**, because the
  resolver's behavior changed; that step takes about as long as it did on
  the initial pass.
- **It re-reads the config files once** (a handful of API calls) and
  discards the old config cache entries.

### Upgrade

1. Upgrade the release with the command above, `--version 0.1.60`, and the
   `ccx` CLI with it. No database or values change.
2. If the indexer is crash-looping on v0.1.59 and you cannot upgrade yet,
   change the content of every file in the config directory (a comment line
   is enough): the indexer starts on the next refresh.

### Verify

The indexer's first startup logs the config read with `Dir.accept: …
reprocessed` instead of `unchanged`, and the pass proceeds. `ccx status`
reports the server healthy as before.

In a repository with Objective-C code, `ccx defs <ClassName>` returns a
`cpp:` qualified name with an `.m` or `.h` path once that repository's pass
completes; each ref's symbol step logs `resolving N of N modules` on that
pass.

## v0.1.59 — config files reject unknown fields; groups share fields across entries; per-key agentic concurrency; plain-text grep; Java, Go and Kotlin symbols

Nothing is required for a config repo whose entries carry only documented
fields: upgrade normally, and upgrade the `ccx` CLI with it. The first
indexer pass after the upgrade walks every repository again and resolves
every symbol again. Read on if a config file might carry a field the indexer
does not define, because that file now fails; if an API key runs many
agentic queries at once; or if Insights' agentic query counts for recent
days change after the upgrade. Optional: give the database the `pg_trgm`
extension and `ccx grep --text` gets an index.

### What changed

- **`ccx grep --text` searches the text of every file.** A regular
  expression, or a plain word, matched line by line against every file in
  the ref — comments, docs, config and languages the structural grep cannot
  parse included — with no `-l` to pass; smart case by default, `-w` for
  whole words, one `path:line:text` line per match. The MCP server offers it
  as `text_grep`, and `ccx ask` uses the same tool
  ([cli.md → the quick reference](cli.md#quick-reference)).
- **A trigram index speeds up `ccx grep --text`** when the database has the
  `pg_trgm` extension: the indexer builds it over every indexed file's text
  at the end of its next pass, and a pattern with a distinctive literal then
  reads only the files holding it instead of scanning the ref. The bundled
  Postgres gets the extension on a fresh volume; an external database or an
  existing bundled volume gets it with one statement, after which the
  indexer needs a restart —
  [deploy.md → Text search index](deploy.md#text-search-index). Without the
  extension nothing changes except a startup log line naming the statement.
- **Java, Go and Kotlin symbols.** `ccx defs` / `ccx refs` and the MCP
  `find_definitions` / `find_references` tools cover `.java`, `.go` (with
  `go.mod`) and `.kt` files. Their qualified names open with `java:`, `go:`
  and `kotlin:`; a Go name carries its package directory
  (`go:internal/store:Store.Fetch`).
- **C# lookups are more accurate.** A name declared in an enclosing
  namespace now wins over one a `using` directive brings in at the same
  level, and `this.member` resolves to the enclosing type's member.

- **An unknown field in a config entry is an error.** A config file with a
  field the indexer does not know — a typo such as `excluded_pattern`, or a
  field of your own — now fails the config refresh for that config repo,
  naming the file and the entry, where it used to be ignored. Indexing of
  already configured repos continues; adding, removing and changing repos
  pauses until the field is removed. Before upgrading, check each config
  file against the field table in
  [deploy.md → Index config repo](deploy.md#index-config-repo).
- **An invalid `included_patterns` / `excluded_patterns` value is an error
  at the config file.** Each must be a list of glob strings, and a glob that
  does not compile now fails the config refresh naming the repo, instead of
  failing that repo's own refresh mid-index.
- **Groups.** An entry with a `repos` key is a group whose other fields are
  inherited by the entries under it; `excluded_patterns` accumulate, every
  other field is overridden by the nearer value. A fleet-wide exclude list
  is written once per file —
  [deploy.md → Groups](deploy.md#groups-write-shared-fields-once).
- **The per-caller concurrency cap is a setting.**
  `agentQuery.maxConcurrentRequestsPerPrincipal` (default 2, as before) is
  how many agentic queries one caller may run at once on one pod, and an
  `auth.apiKeys` record can set its own —
  [deploy.md → Concurrency](deploy.md#concurrency). Neither may exceed
  `agentQuery.maxConcurrentRequests`; the query server refuses to start
  otherwise.
- **A busy refusal states its wait.** The `HTTP 503` `agent_query_busy`
  response carries `Retry-After` (`agentQuery.busyRetryAfterSeconds`,
  default 10), and the MCP tool error carries `retry_after_seconds`.
  `ccx ask` prints it.
- **A busy refusal no longer spends a rate-limit token.**
  `rateLimit.agentQuery` now counts only the queries the concurrency caps
  admit. A caller that starts more queries at once than its cap gets
  `agent_query_busy` for the excess, where it used to get `HTTP 429` once
  its burst ran out, and retrying on the stated wait costs it nothing.
- **Insights counts the agentic queries that ran.** A request refused at
  admission, busy or rate-limited, still counts as a request and an error,
  and no longer as an agentic query. After the upgrade, the days still
  within `usageAnalytics.retention.rawDays` (default 90) are recomputed in
  the background, one day about every 30 seconds; those days show as
  partial until rebuilt, and period comparisons stay hidden meanwhile.
  Their agentic query counts drop by the busy refusals they included;
  older days keep their counts.

### The first pass after the upgrade

- **It walks every repository again.** It reads every file from the code
  host and parses it again, symbol extraction included, so Java, Go and
  Kotlin files gain their symbols. The pass takes longer than a usual one
  and uses more code-host API quota
  ([What a settings change redoes](deploy.md#what-a-settings-change-redoes)).
  Nothing is re-embedded.
- **Every ref's symbol step resolves every module again**, because the
  resolver's behavior changed for every language; that step takes about as
  long as it did on the initial pass.
- **With `pg_trgm` installed, the pass ends by building the text search
  index**: about 100 seconds per gigabyte of indexed text, and about 8% of
  that text's size in disk.

### During the rollout

Old and new pods each apply their own rules, so a refusal on an old pod
still spends a rate-limit token until the rollout completes. Set a key's
own cap in a later `helm upgrade`, after this one completes: a query-server
pod of the previous release that restarts mid-rollout would refuse an auth
configuration carrying it.

### Rolling back

A query server rolled back to v0.1.58 refuses to start while any
`auth.apiKeys` record carries an `agentQuery` block; remove those blocks
first. Insights then recomputes the recent days again under the previous
counting.

### Verify

After the upgrade, the indexer's next config refresh logs no
`config refresh cycle failed` line; one that does names the file and the
field to fix.

Start three `ccx ask` questions at once under one caller with the default
cap: two answer, and the third fails at once with
`[agent_query_busy] … (retry in 10s)`.

`ccx grep --text 'TODO' --path 'docs/*'` prints matching lines from
Markdown files. With `pg_trgm` installed, the indexer's startup log has no
`pg_trgm extension not installed` line, and after its pass the database has
an index named `file_body_body_trgm` in the index schema (`ccx` by default).
In a repository with Java, Go or Kotlin code, `ccx defs
<ClassName>` returns a `java:` / `go:` / `kotlin:` qualified name once that
repository's pass completes; each ref's symbol step logs `resolving N of N
modules` on that pass.


## v0.1.58 — follow-up questions continue a stored answer

Nothing is required: upgrade normally, and upgrade the `ccx` CLI with it.
The answer cache and usage analytics both upgrade in place on the first
start, with everything stored kept. Read on if a client of the agentic query
REST API sends fields the server does not define, or if you run several
query-server replicas and want to know what a follow-up does mid-rollout.

### What changed

- **A stored answer can be continued.** An answer the cache stored now
  carries an `answer_id`, which `ccx ask` prints on stderr as the follow-up
  command, `follow-up: ccx ask --parent <answer-id> "<question>"`. `ccx ask --parent <answer-id> "<follow-up>"` and the `parent`
  parameter of the `ask_codebase` MCP tool answer a follow-up with the
  earlier investigation's evidence in context; a forced answer names its
  continuation, and an answer may be a clarifying question to reply to the
  same way — [cli.md → Follow-ups](cli.md#follow-ups---parent).
- **The answer cache keeps what the agent observed.** Each stored
  investigation step now also stores what its tool call returned, when that
  is 32 KiB or smaller, so a follow-up loads the transcript instead of
  re-running it; a larger result, or any result after the code changed, is
  re-run to verify. The cache's schema contract is now `5`: the new columns
  and tables are added at the first start, and stored answers stay. An
  answer made before the upgrade is still served from the cache, but it has
  no answer id and cannot be continued; the first answer made after the
  upgrade can.
- **Usage analytics count follow-ups.** The new column is added on the
  first start, with your history kept, and the agentic day rollups are
  recomputed; `ccx usage queries --json` gains `agent.follow_ups`, and
  Insights shows it as a tile.
- **The agentic query REST request rejects fields it does not define.**
  `POST /code/v0/query` fails with `HTTP 400` on an unknown field, where it
  used to ignore it; the `ask_codebase` MCP tool still ignores an argument
  it does not define. A `ccx` CLI of this release sends none.

### During the rollout

While old and new query-server pods serve side by side, a follow-up can land
on an old one, which still requires `repos` and ignores `parent`. A follow-up
without `repos` (`ccx ask --parent` without `--repo`) fails there with a
plain `HTTP 400`: retry shortly. One that carries `repos` (`--repo`, or the
MCP `repos` argument) is answered by it as a fresh question in that scope,
with no `answer_id` in the reply; the CLI reports that as a wire-model
mismatch. The window closes with the rollout.

### Rolling back

With the answer cache on, a query server rolled back to v0.1.57 refuses to
start: that release does not know the cache's new shape. Roll forward, or —
to run v0.1.57 anyway — start the cache over with the command in
[deploy.md → Answer cache](deploy.md#answer-cache-optional). From this
release on, the query server migrates its own cache tables at startup, so
later upgrades need no such step.

### Verify

`ccx ask --stats` on a question reports `answer stored` and prints a
`follow-up:` command after the answer; running that command with the
question `"say that again in one line"` answers from the stored
investigation.

## v0.1.57 — Insights names repositories in the freshness table; Rust and C/C++ symbols are more accurate; Nix files are parsed

Nothing is required — upgrade normally, and upgrade the `ccx` CLI with it.
The first indexer pass after the upgrade walks every repository again;
only `.nix` files are re-embedded. Read on if a script parses
`ccx usage indexing --json` or `ccx usage repos --json`.

### What changed

- **The Indexing view's freshness table names repositories, and lists only
  the ones you can read.** Each row is the repository's `<owner>/<repo>`,
  with the branch or tag whose unfinished work sets the lag beside the
  state, and a click opens the repository's drill-down. Before, the table
  listed every repository by a key such as `github:github.com:1146989733`,
  which nobody can read, to every holder of the usage entitlement. It now
  follows the same per-repository authorization as the Repositories table;
  repositories the indexer reports on that are not listed — ones you cannot
  read, or ones the index does not hold yet because their first pass is
  pending or failed — are a count under the table. `ccx usage indexing`
  prints the same names, the same *REF* column and the same count.
- **`ccx usage indexing --json` carries `freshness` as a list**, plus
  `freshness_withheld`. `freshness` was an object keyed by repository key;
  it is now one row per listed repository, sorted by name, each with
  `repo_key`, `repo`, `instance` and the pill under `freshness`;
  `freshness_withheld` is the count above. A repository's pill (in this
  list and on the Repositories rows) gains `git_ref`: the ref behind its
  pending head, `null` when nothing is pending.
- **Repositories rows no longer carry `removed`.** The rows of
  `ccx usage repos --json` and the drill-down are always repositories the
  index holds (they are the ones you can list), so the flag was never true;
  the *removed* badge is gone with it.
- **Rust and C/C++ symbols are extracted more accurately.** `ccx defs` and
  `ccx refs` find more definitions and fewer name-only matches:
  - **Rust:** a variable's use refers to the binding in force where it is
    written. A shadowing `let text = text.copy();` no longer leaves later
    `text.…` calls as name-only matches, and in `let parser = parser();`
    the call finds the function. Calls inside a match arm's guard
    (`Some(s) if s.is_empty() =>`) are indexed.
  - **C and C++:** `struct point { int x; } origin;` gives `origin` the
    type `struct point`, so `origin.x` finds the field.
- **Nix files are parsed.** `.nix` files are chunked along their syntax,
  and `ccx grep -l nix` searches them.

### The first pass after the upgrade

- **It walks every repository again.** It reads every file from the code
  host and parses it again, symbol extraction included. The pass takes
  longer than a usual one and uses more code-host API quota
  ([What a settings change redoes](deploy.md#what-a-settings-change-redoes)).
- **Only `.nix` files are re-embedded**, because their chunks change.
- **It resolves again only the symbols the change reaches**: the Rust and
  C/C++ files, and the files whose lookups read them. Other files' symbols
  are reused.

### How to verify

- Each ref's symbol step in that pass logs `resolving N of M modules (…),
  reusing K`, with N covering the ref's Rust and C/C++ files.
- `ccx grep 'pkgs.\X' -l nix` returns matches in a repository with `.nix`
  files once its pass completes.

## v0.1.56 — the indexer reads at most about 1,000 files ahead; symbol lookups are more accurate

Nothing is required — upgrade normally. The first indexer pass after the
upgrade walks every repository again and resolves every ref's symbols
again; nothing is re-embedded. Read on if an indexer ran out of memory while
walking a new repository or branch, or if you size the indexer's memory.

### What changed

- **The walk no longer reads a whole ref ahead.** The indexer reads files
  from the code host far faster than it embeds them. Earlier releases kept
  every file read ahead in memory until its turn came, so a first pass — a
  new repository, a branch newly added to a large one, or the re-walk an
  upgrade triggers — could hold the ref's whole new content, and an
  embedding provider that rate-limited the indexer made it do so. A file is
  now read only once the indexing engine has room for it, so at most about
  1,000 files wait their turn at once.
  - Measured on an 8,900-file TypeScript repository: at most 746 files
    waited instead of 7,412, and the pass peaked at 0.8 GiB instead of
    0.9 GiB.
  - Embedding starts sooner (after 22 s instead of 2 minutes on that
    repository), and the pass as a whole took 5% longer.
- **Symbols are extracted and resolved more accurately.** `ccx defs` and
  `ccx refs` find more definitions and fewer name-only matches:
  - **Python:** an annotated `*items: int` or `**options: str` is a rest
    parameter. A reassignment such as `text = text.copy()` no longer leaves
    that call, and every later `text.…` call, as a name-only match. A
    module that imports its own name (`from pkg.table import Table as
    Table`) no longer turns every import of that name into one.
  - **C and C++:** `typedef struct tag { … } tag_t;` defines `struct tag`
    and its members. `int app::helper() {}` defines a function of
    namespace `app`, not a method. `extern int counter;` and an in-class
    `static int count;` are declarations, so references go to the
    definition. `using Base::count;` in a class exposes the base class's
    member. `struct point p;` gives `p` the type `struct point`. A variadic
    `...` parameter accepts extra arguments.
  - **C/C++, C# and TypeScript:** a call to an overloaded function is
    typed by the overload its arguments select, and left untyped when they
    select none, instead of by every overload.
  - **C#:** a parameter with a default value (`int c = 0`) is optional, so
    a call that leaves it out matches.
  - **Rust:** `use super::…` and `use self::…` inside an inline `mod` (such
    as `mod tests`) name the module the path climbs to.
  - **TypeScript:** member access through an alias of a union
    (`type Shape = Circle | Square`) resolves per member, as through the
    written union.

### The first pass after the upgrade

- **It walks every repository again.** It reads every file from the code
  host and parses it again, symbol extraction included. Nothing is
  re-embedded. The pass takes longer than a
  usual one and uses more code-host API quota
  ([What a settings change redoes](deploy.md#what-a-settings-change-redoes)).
- **It resolves every ref's symbol graph again.** The cost is one symbol
  step per ref ([Indexer memory sizing](deploy.md#indexer-memory-sizing)).

### What to do (optional)

- **You raised the indexer's memory limit after it was OOM-killed walking
  a new repository or branch:** the walk's backlog is now bounded. Check the
  limit against [Indexer memory sizing](deploy.md#indexer-memory-sizing)
  before lowering it; the symbol step's peak is unchanged.

### How to verify

- During a first pass, the indexer's minute line, `indexer memory: … N
  files waiting their turn`, stays below about 1,000.
- Each ref's symbol step in that pass logs `resolving N of N modules (…),
  reusing 0`: every file's symbols are resolved again, and only the files
  whose symbols changed are written.

## v0.1.55 — indexed refs and their commits are shown wherever repositories are listed; symbol steps run one at a time; the indexer logs its memory; agentic questions take an effort level

**If agentic query is enabled, raise the ingress timeout and move two values
before upgrading** — the chart refuses to render otherwise. Nothing else is
required: upgrade normally, and upgrade the `ccx` CLI with it. Usage
analytics needs nothing: the new columns are added on the first start, with
your history kept.
Read on if a BI role reads the `v_repo_activity_daily` view, if a script
parses `ccx repos` output, if you run several large repositories on one
indexer, or if you size the indexer's memory.

### What changed

- **`ccx repos` prints every ref a repository is indexed at, with its
  commit**, as a fourth tab-separated column after the default branch:
  comma-separated `<ref>@<commit>` entries, the commit cut to 12 hex
  characters, capped at ten with a `+N more` tail (`ccx git-refs` still
  prints the full set with full shas). The MCP `list_repos` tool carries
  the same list as `git_refs`, each entry an object with `git_ref` and
  `commit_sha`. Before, a repository indexed at several branches or tags
  looked identical to one indexed at its default branch alone, and no
  listing said which commit the index was at.
- **Insights reads ref counts from the index as you look.** The *Refs*
  column of the Repositories table — in the web UI and, new, in
  `ccx usage repos` — is a live read. It was sampled once a day, so a ref
  added in the morning showed up the next day, and a repository indexed
  after the day's sample showed `0`. A repository's drill-down (the web UI
  and `ccx usage repo`) now lists each indexed ref with the commit indexed
  for it and its own freshness.
- **Insights names the commit behind every freshness pill.** The
  Repositories table has a *Commit* column: the default branch at its
  indexed commit, or the first ref when the default branch is not indexed,
  with `+N` for the other refs. A drill-down ref that is behind shows the
  newer head the indexer has seen and how long ago; one that is caught up
  says so as of the indexer's last poll, which the table and the drill-down
  both name.
- **The `v_repo_activity_daily` view no longer has an `indexed_refs`
  column**, and the analytics table behind it (`repo_profile`) is no longer
  written with one. The query server recreates the view on its first start
  after the upgrade, which drops any grants made on that view.

- **One ref's symbol step at a time.** The symbol steps of different
  repositories no longer overlap: a ref whose step is due while another's
  runs waits, logs that it waits, and starts when the other finishes. The
  indexer's memory peak for the step is one ref's, not a sum over
  repositories ([deploy.md § Indexer memory sizing](deploy.md#indexer-memory-sizing)).
  `indexer.symbolIndex.maxConcurrentResolves` (default 1) lets more run at
  once, with the memory to match.
- **The indexer logs its memory**, once a minute while it has work in
  progress and every ten minutes while idle, counting the files the walk
  has read ahead apart from the files in progress. Each ref's walk, each
  symbol step's boundaries and each pass's last line end with the same
  figure. Include those lines when you report an OOM kill
  ([deploy.md § Indexer memory sizing](deploy.md#indexer-memory-sizing)
  has the command).
- **The sizing guide covers new refs.** A branch or tag added to an indexed
  repository is a first pass of its new content, the refs of one repository
  walk one at a time, and `indexer.maxFilesInFlight` bounds the files in
  progress, not the files read ahead of them.

- **Agentic questions take an effort level** — `low`, `medium`, or `high`,
  named with `ccx ask --effort` or the MCP tool's `effort`. A table under
  `agentQuery.effort` sets each level's turns and deadline
  ([deploy.md § Effort levels](deploy.md#effort-levels)).
  It replaces `agentQuery.maxTurns` and `agentQuery.requestDeadlineSeconds`.
  The defaults are 10 / 30 / 60 turns and 300 / 600 / 1200 s; `medium`, the
  default level, matches the old defaults. A helper sub-investigation now
  runs one level below its caller instead of with half the turns.
- **A forced answer says so.** When the agent runs out of turns or context
  before it is done, the answer ends with what it could not verify, the
  response's new `completion` field reads `forced_turns` or
  `forced_context`, and `ccx ask` prints a note on stderr. Insights counts
  forced answers apart from complete ones.
- **The usage-analytics tables gain the columns behind those counts on the
  first start**, keeping your collected history — the first release to
  upgrade the analytics schema in place, which is how analytics schema
  changes work from here on ([deploy.md § How the analytics schema
  evolves](deploy.md#how-the-analytics-schema-evolves)).

### What to do

- **If `agentQuery.enabled` is true**, before upgrading:
  - raise `queryServer.ingress.timeoutSeconds` to clear the largest effort
    deadline plus 5 s — **1230** for the defaults, up from 630 — or lower
    `agentQuery.effort.high.deadlineSeconds`;
  - move a tuned `agentQuery.maxTurns` to `agentQuery.effort.medium.turns`,
    and a tuned `agentQuery.requestDeadlineSeconds` to
    `agentQuery.effort.medium.deadlineSeconds`. The chart refuses to render
    while either old key is set, and names the replacement.
- If a BI role reads `v_repo_activity_daily`, re-apply its grant after the
  upgrade (the schema-wide statement from [Insights](insights.md#sql-views-for-bi-and-grafana)
  works too):

  ```sql
  GRANT SELECT ON ccx_usage.v_repo_activity_daily TO bi_reader;
  ```

  A report that read `indexed_refs` from the view should read the index's
  own `ccx.git_ref_roots` instead (one row per repository and ref) — the
  live source the dashboards now use.
- Scripts that split `ccx repos` output on tabs keep working — the column
  is appended — but a ref to pass to `--git-ref` is the part of each entry
  before `@`. Take the full ref set from `ccx git-refs`, since the listing
  caps it at ten per row.
- If you had raised `indexer.resources.limits.memory` to fit several
  repositories' symbol steps at once, size for the largest ref instead
  ([deploy.md § Indexer memory sizing](deploy.md#indexer-memory-sizing)).

### What to do (optional)

An analytics schema created before this release keeps the unused
`repo_profile.indexed_refs` column: nothing writes or reads it any more, so
it holds whatever the last daily sample wrote. Drop it if you like:

```sql
ALTER TABLE ccx_usage.repo_profile DROP COLUMN IF EXISTS indexed_refs;
```

### How to verify

- `ccx repos` prints four columns, and a repository indexed at several refs
  lists them in the last one, each with the commit `ccx git-refs` shows for
  it.
- In `ccx ui`, open a repository under Repositories: an **Indexed refs**
  card lists its refs, and the *Refs* column follows a newly indexed ref on
  the next reload rather than the next day. The table's *Commit* column
  matches the drill-down's commit for the same ref.
- `\d ccx_usage.v_repo_activity_daily` shows no `indexed_refs` column.

## v0.1.54 — symbols are resolved and written per file, in one step; the symbol tables are rebuilt; Git LFS files are skipped

Nothing is required — upgrade normally. The first indexer pass after the
upgrade walks every repository again and builds every ref's symbol graph
again, into new tables; nothing is re-embedded. Until a ref's symbol step has
run in that pass, `ccx defs` and `ccx refs` note that the ref's symbol index
isn't built yet. Read on if a large repository's symbol step ran out of memory
or held a pass for long, if anything of yours reads the symbol tables by name,
or if you exclude file types to keep Git LFS pointers out of the index.

### What changed

- **A pass resolves and writes only the files whose symbols may have
  changed.** After a change, the indexer resolves the changed files and the
  files whose symbols depend on them, reuses the rest, and writes only the
  files whose symbol rows came out different. Before, every pass after a
  change resolved the ref's whole symbol graph, and every symbol row of the
  ref went through the indexer's bookkeeping again, changed or not.
  Measured on an 8,900-file TypeScript repository holding 800,000 symbol
  rows: after a one-commit change the pass resolved 5 files, took 12 s and
  peaked at 0.8 GiB; a pass like it used to take about 40 s and peak at
  1.7 GiB. After 25 commits it resolved 886 files.
- **Reused symbols are checked once a day.** A file whose symbols have been
  reused for a day is resolved again on the next pass after a change to its
  repository. If its symbols come out different, the indexer logs an ERROR
  naming the files and writes the right ones; please report it. The
  optional `indexer.symbolIndex.reuseMaxAgeSeconds` (default `86400`) sets
  the interval, and `0` turns reuse off
  ([Symbol index](deploy.md#symbol-index)).
- **A ref's symbol graph changes in one step.** Everything a pass changes
  for a ref is written in one transaction. `ccx defs` and `ccx refs` never
  answer from a half-written graph, and a killed pass leaves the previous
  graph or the new one, whole
  ([Interrupted passes](deploy.md#interrupted-passes-and-cleanup)).
- **A first pass needs less memory for the symbol graph.** On the same
  repository the first pass peaked at 1.6 GiB instead of 2.2 GiB, and its
  symbol step, write included, took 1 minute instead of 2.
  [Indexer memory sizing](deploy.md#indexer-memory-sizing) has the new
  figures.
- **Deleting a ref's symbol rows is one quick step.** A ref that goes over a
  symbol cap, a ref removed from the index config, and every ref once the
  symbol index is turned off lose their symbol rows in one transaction:
  about 2 seconds for the 800,000 rows above. Before, the indexer cleared its
  bookkeeping for them row by row, which ran for hours on millions of rows.
- **The symbol tables have new names.** `symbol_module_roots`,
  `symbol_definition`, `symbol_reference` and `symbol_name_sites` are now
  `symbol_coverage`, `symbol_definitions`, `symbol_references` and
  `symbol_name_only_sites`. The first pass after the upgrade creates the new
  tables and drops the old ones.
- **Symbols are extracted and resolved more accurately.** `ccx defs` and
  `ccx refs` find more definitions and fewer wrong ones:
  - **C and C++:** `class MYLIB_API Widget : public Base { … };`, a class
    declared with an export macro, defines `Widget` and its members; the
    macro used to be read as the class name, so `ccx defs Widget` found
    only forward declarations. `void MYLIB_API f(int);` declares a
    function. `class ui::Widget { … };`, written outside namespace `ui`,
    defines `ui::Widget`.
  - **TypeScript/JavaScript and Rust:** a name reached through a directory
    resolves only where the language finds it. `pkg.mod.f()` through
    `import * as pkg from "./pkg"` when `pkg/` has no `index` file, and
    `a::b::f()` when `a.rs` declares no `mod b;`, are name-only matches
    instead of resolving to the directory's file of that name.
  - **Rust:** in `src/a/b.rs`, `use super::x;` and `use super::*;` find the
    items of `src/a.rs`.
- **Git LFS files are no longer indexed as their pointers.** The git blob of
  an LFS-tracked file is a short text pointer, not the file. Earlier releases
  stored and embedded that pointer as the file's contents; the indexer now
  skips it, as it skips binary files
  ([File size limits](deploy.md#file-size-limits)).
- **The symbol step's log lines changed.** The step logs `checking N
  modules`, then `resolving K of N modules (…), reusing M`, or `reused all
  N modules` when it resolves none. Its totals line gains a `check` phase,
  `rows declared` reads `rows compared`, and a `wrote` line follows the
  totals when a file's symbol rows changed
  ([Symbol index](deploy.md#symbol-index)). A write that stops advancing
  for 10 minutes logs a WARNING, `No rows have been written for … in the
  symbol write of …`.

### The first pass after the upgrade

- **It walks every repository again.** It reads every file from the code
  host and parses it again, symbol extraction included, and drops the
  contents of the LFS pointers it indexed before. Nothing is re-embedded. The
  pass takes longer than a usual one and uses more code-host API quota
  ([What a settings change redoes](deploy.md#what-a-settings-change-redoes)).
- **It resolves every ref's symbol graph again and writes it to the new
  tables.** The cost is one symbol step per ref
  ([Indexer memory sizing](deploy.md#indexer-memory-sizing)).
- **It drops the old tables and clears the indexer's bookkeeping for their
  rows.** For the repository above this took 44 s: 11 s to write the
  800,000 rows to the new tables, most of the rest to clear the bookkeeping
  of the old ones.
- **`ccx defs` and `ccx refs` follow it ref by ref.** A ref's symbol index
  reads as not built until its symbol step has run, and answers from its full
  graph after that. For a few seconds while the two workloads roll, the two
  commands can answer `503`. Search, grep and file reads are unaffected
  throughout.
- **`helm rollback` works, and rebuilds again.** The previous release drops
  the new tables and builds the old ones from scratch, the way this upgrade
  builds the new ones.

### What to do (optional)

- **You set `indexer.symbolIndex.maxFilesPerGitRef` low to get a large
  repository's symbol step through:** check that repository against
  [Indexer memory sizing](deploy.md#indexer-memory-sizing) and consider
  raising the cap back. A ref past the cap has no symbol graph.
- **You read the symbol tables by name** (a dashboard, a grant, a backup
  filter): switch to the new names. Nothing in the chart, the CLI or the API
  refers to them.
- **You exclude file types to keep Git LFS pointers out of the index:** you
  can remove those `excluded_patterns`.

### How to verify

- The indexer log shows, for each ref the first pass resolves, `symbol
  graph: <repo-uid> <ref> wrote N modules (…) and removed 0 in …s`, with N
  the ref's source files.
- `ccx defs <function-name>`, for a function you know in that repository,
  answers once the repository's `wrote` line is logged.
- On the passes after it, a repository's step logs `resolving K of N
  modules (…), reusing M`, with K the files that changed and the files
  whose symbols depend on them.
- `ccx read-file <path>`, for a file you know is stored in Git LFS, reports
  that the path was not found once its repository's first pass completes.

## v0.1.53 — removing a large component commits in seconds; symbol names are corrected

Nothing is required — upgrade normally. The first indexer pass after the
upgrade resolves every ref's symbols again; no file is walked, extracted or
embedded again. Read on if the indexer sat in a long `idle in transaction`
commit after you lowered `indexer.symbolIndex.maxFilesPerGitRef`.

### What changed

- **A commit that removes a large component no longer takes hours.**
  Lowering `indexer.symbolIndex.maxFilesPerGitRef` below a ref's size skips
  that ref's symbol step, and the pass then removes the symbol rows it had
  declared. The Postgres commit checked each of those rows with its own
  query inside one transaction: about 600 a second, so a million rows took
  nearly 18 minutes and seven million would take about 3 hours, and a restart rolled
  all of it back. The commit now reads them in bulk. In the library's
  measurements a million rows take 7 s and seven million take 52 s.
- **Symbol resolution is corrected in two cases.** In TypeScript and
  JavaScript, a binding made inside an arrow function or IIFE
  (`const { X } = require("./b")`) no longer replaces the module's own `X`
  for `export { X } from "./a"` or for the module's other mentions of `X`;
  it applies inside the function only. In a repository mixing languages, a
  lookup stays inside the looking-up file's language: a C++ and a C#
  `namespace app` are no longer one namespace, and a `.ts` file in a Python
  namespace package no longer turns `pkg.mod.f()` into a name-only match.

### What to do

- **Stuck commit:** upgrade and restart the indexer. A commit already
  running does not speed up, and the restart rolls it back; the next pass
  removes the component in bulk.
- **Expected after the upgrade:** the first pass re-resolves every ref, so
  its symbol step runs once more over every repository with symbols enabled.
  Rows for the cases above change; everything else is identical.

## v0.1.52 — the symbol step reports progress and is bounded; C/C++ symbols resolve in seconds

Nothing is required — upgrade normally. The first indexer pass after the
upgrade extracts symbols again from every Python, TypeScript/JavaScript and
C/C++ file and resolves every ref again; nothing is re-embedded. Read on if a
repository's symbol step has run for hours, or if you lowered
`indexer.symbolIndex.maxFilesPerGitRef` to get past one.

### What changed

- **One ref's symbol step can no longer hold every repository.** A ref's
  symbol resolve still running `indexer.symbolIndex.resolveTimeoutSeconds`
  (new; default 1800, 30 minutes) after it starts is cancelled; time spent
  waiting behind another repository's resolve does not count. That ref's pass fails with a
  `component build failed` ERROR saying `symbol resolution was cancelled at
  the 30-minute bound (CCX_SYMBOL_RESOLVE_TIMEOUT_SECONDS)`, keeps answering
  from its last completed pass, and is retried on the next one. Before, such
  a ref held the whole pass for as long as its resolve ran, hours on some
  C/C++ code, and no other repository updated meanwhile. See
  [Symbol index](deploy.md#symbol-index).
- **A long symbol step reports its progress.** Each ref's symbol step logs
  when its tree is read and how many modules it will resolve, a line a minute
  while it runs, and its totals. When it stops advancing for 10 minutes, the
  indexer logs a WARNING, `No module has finished resolving for … in the
  symbol step of …`, every 10 minutes while that lasts.
- **C/C++ symbols resolve in seconds, not hours.** Resolution scanned a
  namespace's members and a scope's entries again for every reference. In
  the library's benchmarks, LLVM's `llvm/lib` (3,954 files) resolved in 15 s
  instead of 205 s, and code shaped like the reports that ran for hours
  finished in seconds.
- **Symbol resolution uses every CPU.** A ref's modules resolve in parallel,
  on as many threads as the indexer's CPU limit allows.
- **Large deletions no longer stall a pass.** A pass deletes superseded rows
  in batches of thousands, and Postgres took about a minute to plan each
  batch, so a pass deleting a large repository's grep index ran for over an
  hour. Each batch now plans in under a second.
- **The symbol step needs less memory.** The indexer keeps the symbol rows
  it has resolved in a compact form until it writes them. In the library's
  measurement, the first pass over an 8,900-file TypeScript repository peaked
  at 3.1 GiB instead of 4.5 GiB;
  [Indexer memory sizing](deploy.md#indexer-memory-sizing) keeps the older,
  larger figures until they are re-measured.
- **`ccx defs` and `ccx refs` resolve more names.** Among them: names
  re-exported through `from .x import *` and `export * from` barrels; names
  qualified with a C++ namespace that many files reopen (every `llvm::` name
  in LLVM was unresolved); every signature of a large overload set; and
  TypeScript/JavaScript object-literal shorthand properties. A bare name in a
  method no longer resolves to a member of its own class, which Python and
  TypeScript/JavaScript do not do either.
- **The first indexer pass after the upgrade re-walks every repository.**
  Symbol extraction changed for Python, TypeScript/JavaScript and C/C++, so
  every such file is extracted again and every ref resolved again; nothing is
  re-embedded. That pass takes longer than a normal one and has first-pass
  memory needs, each repository's symbol step included.

### What to do (optional)

- **Check the indexer's memory limit against
  [Indexer memory sizing](deploy.md#indexer-memory-sizing) before upgrading.**
  The first pass after the upgrade re-walks every repository. If you raised
  the limit to get a large repository through an earlier first pass, keep it
  for this one.
- **You lowered `indexer.symbolIndex.maxFilesPerGitRef` to get past a symbol
  step that never finished:** C/C++ resolution is now fast, so consider
  raising it back. A ref still past the cap has no symbol graph.
- **A ref's pass fails at the bound every pass** (the `cancelled at the …
  bound` error): its search, grep and symbols stay at its last completed
  pass. Raise `resolveTimeoutSeconds`, or set `maxFilesPerGitRef` below that
  repository's file count to skip its symbol graph, and report it — a
  healthy resolve takes seconds to minutes.

### How to verify

- The indexer log shows, for each ref the first pass resolves,
  `symbol graph: <repo-uid> <ref> read … parsed_module rows in … rounds in
  …; resolving … modules`, and later `symbol graph: <repo-uid> <ref>
  resolved … modules → …`.

## v0.1.51 — `/mcp` answers in place; rollouts stop failing requests; large first passes fit in memory

Nothing is required — upgrade normally. Read on if you pointed MCP clients
at `/mcp/` to work around a redirect, if a proxy on the query-server pod's
own loopback (a service-mesh sidecar) receives its traffic, if requests
still fail while pods roll, if you run agentic query with the answer cache,
or if you raised the indexer's memory or excluded files to get a large
repository indexed. The first indexer pass after the upgrade re-reads every
repository once (nothing is re-embedded); see *What changed*.

### What changed

- **`/mcp` no longer redirects.** 0.1.50 answered `<publicUrl>/mcp` with a
  `307` to `http://<host>/mcp/`: behind a TLS-terminating ingress the
  server sees plain HTTP and built the redirect from that. A client that
  followed it either dropped its bearer token and got `401`, or sent the
  token over plain HTTP. Now `/mcp` and `/mcp/` are the same endpoint,
  answered in place, so clients pointed at `/mcp/` keep working. No route
  redirects any more: a stray trailing slash on a REST path is a `404`.
  In Insights, the redirect used to count as a separate MCP request; it no
  longer does.
- **Rollouts no longer fail requests.** A query-server pod keeps serving for
  `queryServer.shutdownDelaySeconds` (default 10) after it is marked for
  deletion, so the ingress stops routing to it first, and its termination
  grace period now lets every in-flight request finish — see
  [Rollouts and pod shutdown](deploy.md#rollouts-and-pod-shutdown).
- **Forwarded headers never rewrite a request.** The server takes a
  request's client address and scheme from the connection itself. Before, a
  request arriving from the pod's loopback had both rewritten from
  `X-Forwarded-For` / `X-Forwarded-Proto` ahead of your
  `rateLimit.clientIpStrategy`.
- **The grep matcher loads when the pod starts.** A missing or rejected
  license key is logged as a warning at startup instead of at the first
  `ccx grep`, and grep keeps answering `503` with that reason until the pod
  restarts. If the license check cannot reach `api.keygen.sh`, the pod takes
  up to about 5 s longer to start, instead of every request stalling for
  that long at the first grep.
- **The first requests after a restart no longer fail with `503
  authn_unavailable`.** A request that arrived while the server was fetching
  the IdP's signing keys was judged against the empty key cache instead of
  waiting for the fetch; the same race could answer `401` during a key
  rotation. Requests now wait for the fetch in flight.
- **The answer cache serves answers made under turn pressure.** An answer
  whose investigation ran into its last few turns — or used a helper
  sub-investigation that did — was stored but could never be served, so
  repeating a deep question reran it in full every time. Answers stored
  before the upgrade stay unused; the next ask of each question stores a
  servable one.
- **Each answer says whether it was stored.** `ccx ask --stats` ends with
  `answer stored` or `answer not stored (<reasons>)`, and `--json` and the
  audit event carry `result_stored` and `not_stored_reasons` —
  [deploy.md → Answer cache](deploy.md#answer-cache-optional) lists the
  reasons. `ccx ask` from this release needs a server from this release.
- **`agentQuery.maxTurns`** sets the main agent's turn budget (default 30;
  helper sub-investigations get half). The query server also logs a startup
  warning when LiteLLM will drop your `agentQuery.reasoningEffort` for the
  configured model.
- **A large repository's first pass fits in memory.** The indexer works on
  at most `indexer.maxFilesInFlight` files at once (new; default 256) and
  frees each file's parse before it waits on its embeddings. Before, every
  file of the repository was in progress at once: with the symbol index off,
  a repository with 80 MiB of source peaked above 5 GiB, and now peaks at
  0.9 GiB. With it on, the symbol step at the end of the pass can need more;
  [Indexer memory sizing](deploy.md#indexer-memory-sizing) has both budgets.
- **A long token no longer fails the whole ref.** Grep indexes a file's
  identifiers and words, and a few constructs are indexed as one token: a
  shell heredoc body, a C macro body, JSX text. A token that did not compress
  under Postgres's 2,704-byte index limit failed its file, its folder and the
  whole ref on every pass, logging `index row size … exceeds btree version 4
  maximum 2704`. Tokens over 512 bytes are now left out of the grep index.
- **The indexer reports a stalled pass.** When files are in progress and none
  has finished for 10 minutes, the indexer logs a WARNING,
  `No file has finished processing for …`, naming the oldest files in
  progress and what each is waiting on. It repeats every 10 minutes while
  the stall lasts.
- **Symbol extraction no longer hangs on long call chains, and deep nesting
  no longer crashes the indexer.** In TypeScript/JavaScript, C/C++ and C#,
  each call of a chain like `a.b().c()` is walked once: before, extraction
  time doubled with every call, and a chain of 30 calls took minutes. A file
  nested more than 2,000 levels deep, or one whose extraction would exceed a
  fixed work budget, now gets no symbols (search and grep still cover it)
  instead of stalling or crashing the indexer. TypeScript/JavaScript and C#
  results also lose spurious entries: duplicate definitions inside chained
  callbacks and stray member-access entries in C# initializers.
- **The first indexer pass after the upgrade re-reads every repository.**
  Symbol extraction changed, so every file is extracted again; nothing is
  re-embedded. That pass takes longer than a normal one and has first-pass
  memory needs, each repository's symbol step included.

### What to do (optional)

- **A service-mesh sidecar receives the query server's traffic** (requests
  arrive from the pod's loopback): the sidecar is now the peer the server
  sees. Set `rateLimit.clientIpStrategy: trustedChain` and add the address
  the sidecar connects from to `rateLimit.trustedProxyCidrs`; otherwise every
  client shares the sidecar's rate-limit bucket.
- **Requests still fail or stall while pods roll:** your load balancer needs
  longer to drop a pod. Raise `queryServer.shutdownDelaySeconds` and re-check.
- **Answers keep reporting `answer not stored (unattested_read)`:** they
  overlapped an indexer pass. See
  [deploy.md → Answer cache](deploy.md#answer-cache-optional) for how to read
  your pass time and when a longer `indexer.cycleSeconds` helps.
- **You excluded files to get a repository indexed**, such as shell scripts
  whose heredocs failed with the `index row size` error: remove those
  `excluded_patterns` entries. The files index now.
- **Check the indexer's memory limit against
  [Indexer memory sizing](deploy.md#indexer-memory-sizing) before upgrading.**
  The first pass after the upgrade re-reads every repository and ends with
  each one's symbol step. If you raised the limit to get a large repository
  through an earlier first pass, keep it until you have compared.

### How to verify

- MCP answers in place: step 4 of [Verify the install](deploy.md#verify-the-install)
  prints `200`.
- The pod has the delay and the grace period:
  `kubectl -n ccx get deploy ccx-cocoindex-code-plus-query-server -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}'`
  prints `80` (`600` with agentic query enabled). The quickstart's release
  and namespace; substitute yours.
- After the first pass that follows the upgrade, the indexer log has no
  `exceeds btree version 4 maximum 2704` error.

## v0.1.50 — enterprise lookup: `membersOnly` dropped

Applies if any instance maps identities through the **enterprise lookup**
(github.com enterprise-level, or GHES with `enterpriseSlug`). Nothing is
required — upgrade normally.

### What changed

The enterprise lookup's `externalIdentities` query no longer sends
`membersOnly: true`. At the enterprise scope that flag does not mean "has
org membership": on GHES it filters to enterprise **administrators**
(observed on a 3.21 instance: 7 of 3,448 identities survived it), so with
0.1.49 every ordinary engineer on such an instance resolved as unmapped —
public repos only — while the startup probe, which never sent the flag,
passed. Matching is as strict as before: the byte-exact join on
`samlIdentity.nameId` **or** `scimIdentity.username`, plus the linked-user
requirement — and per-repo permission checks still gate all access, so
dropping the flag grants nothing by itself. The **org-level** SAML lookup
is unchanged (its `membersOnly` has the documented org-membership meaning
and is field-verified).

The [enterprise pre-flight query](deploy.md#pre-flight-check) is updated to
match; if you saved a copy that carries `membersOnly: true`, re-run it
without the flag.

### How to verify

A linked engineer's private-repo search returns results, and the audit
stream's `denied_by_reason` no longer counts the whole population under
`unmapped` on the enterprise-lookup instance.

## v0.1.49 — GHES mirrored mapping: the enterprise lookup route

Applies if a GHES instance runs `codeHostMirrored`. Nothing is required —
existing routes behave exactly as before; this release adds a route.

### What changed

A GHES `authz.codeHosts` entry can now set `enterpriseSlug` next to its
`identityMappingCredential`, selecting the **enterprise lookup** (the same
`enterprise(slug:) … externalIdentities` query the github.com enterprise row
uses — GHES runs SAML/SCIM at the enterprise scope) instead of the SCIM
route. Its PAT needs **`read:enterprise` only** — read-only, no
`ghesScimPatAccepted` attestation — and its join accepts either stored
linkage field (`samlIdentity.nameId` or `scimIdentity.username`)
byte-for-byte.

One skew note: `enterpriseSlug` on a GHES entry was previously accepted
but never read — if yours already carries it, this upgrade activates the
enterprise lookup on that instance (checked at startup by the mapping
probe); remove the field to stay on SCIM.

Do this if you use the SCIM route and your IdP provisions the SCIM
`userName` as the work email: that route resolves the `userName` as the
GHES login, which 404s there, and every caller unmaps ([deploy.md → GHES:
instance-wide SAML](deploy.md#ghes-instance-wide-saml) has the full
explanation and the two-step pre-flight that now catches it).

### What to do (optional — only to adopt the route)

1. Mint an enterprise-owner classic PAT with `read:enterprise` and put it in
   the mapping-credential Secret (replacing the `scim:enterprise` one).
2. On the GHES entry: add `enterpriseSlug: <slug>` (the enterprise settings
   URL carries it) and drop `attestations.ghesScimPatAccepted` if no other
   instance still uses the SCIM route.
3. Run the enterprise pre-flight query
   ([deploy.md → Pre-flight check](deploy.md#pre-flight-check)) for a
   test user, then upgrade and watch the mapping probe line at startup.

### How to verify

`ccx repos` as a mapped engineer lists their private repos; the audit
stream's `reason: unmapped` entries for known-linked engineers disappear.

## v0.1.48 — Python qualified names lose a stray directory prefix

Applies when upgrading from v0.1.47 or earlier. It matters if you use
`ccx defs` / `ccx refs` on Python code; nothing is needed before the upgrade.

### What changed

v0.1.41 gave Python qualified names their package's full import path, and in
some repositories it overshot: a name could open with a directory that is not
part of the import path, most often `src.`. A function in
`python/common/src/mypkg/settings.py`, imported as `mypkg.settings`, was named
`python:src.mypkg.settings.load_env` instead of
`python:mypkg.settings.load_env`.

The trigger was an import through a directory without an `__init__.py`,
typically a test fixture doing `from src.app import …`. The indexer then took
every directory holding a `src/` for a source root. It now does so only for a
directory with the same name as the one holding the fixture's `src/`.

- **Names are corrected** where the triggering import names a module inside
  the directory: `from src.app import …`, `import src.app`. An import of the
  directory itself — `from src import app`, `import src` — still adds the
  prefix in this release.
- **Pieces of one package without an `__init__.py`, under differently named
  directories** (`tools/mypkg/` beside `src/mypkg/`), are joined only when some
  file imports the package itself: `import mypkg` or `from mypkg import …`.
  Where the repository imports only modules inside one piece
  (`from mypkg.settings import …`), the other piece is no longer joined:
  - its qualified names lose the package part (`python:mypkg.tool.run`
    becomes `python:tool.run`);
  - a relative import between the pieces is no longer resolved, so exact
    targets (`PATH ENTITY_ID` or a qualified name) stop listing that use, and
    only `ccx refs <function-name>` shows it, as a `~name` row.
- As in v0.1.41, the two-token `PATH ENTITY_ID` target that `ccx defs` prints
  under each row keeps its spelling.

### Upgrade

1. **Upgrade the release** with the command above, `--version 0.1.48`.

2. **Let the indexer finish one full cycle.** It re-resolves the symbol
   references of every indexed branch and tag, which is what applies the fix
   to already-indexed repos. No file is parsed again and nothing is
   re-embedded, so the cycle is shorter than v0.1.41's and costs nothing with
   your model provider. Queries keep working while it runs; until a branch or
   tag has been re-resolved, `ccx defs` and `ccx refs` can still show its old
   spellings.

3. **Update saved qualified-name queries**, if you have any — scripts, agent
   prompts, or bookmarks that pass a Python qualified name to
   `ccx defs --qualified-name` or `ccx refs <qualified-name>`. Both changes
   above can rename a symbol; run `ccx defs <base-name>` to read the current
   spelling.

### Verify

Once the indexer has completed a cycle, pick a Python function in a package
under a `src/` directory, one your code imports as `mypkg.…`, and check its
headline:

```bash
ccx defs <function-name>
```

The qualified name starts `python:mypkg.`. A module your code imports through
`src` itself, such as a fixture imported as `src.app`, keeps `src.`: that is
its import path.

## v0.1.45 — `ccx query` is now `ccx ask`; log severity means something

Applies when upgrading from v0.1.44 or earlier, to every deployment. Nothing
to do at upgrade time; read the first part if anyone types or scripts the
question command, the second if anything of yours reads the pod logs.

### The question command is renamed

- **`ccx query` is now `ccx ask`**, and the MCP tool `query_codebase` is now
  `ask_codebase`. Flags, output, scoping, and the REST endpoint
  (`POST /code/v0/query`) are unchanged, and there is no alias: the old
  spellings are gone.
- **Why**: coding agents choose between the subcommands on what the verbs
  mean, and "query" reads as a synonym of "search" — so question-shaped
  requests were being routed to `ccx search`. `ask` is the verb the
  surrounding ecosystem already uses for question → answer.
- **What to do**: update any script, alias, or agent instruction that types
  `ccx query`, and reinstall the CLI (`uv tool install -U
  cocoindex-code-plus`) so `ccx ask` exists. MCP clients rediscover the tool
  list on connect and need no change, but a repo instruction line or prompt
  that names `query_codebase` should be updated. An older CLI keeps working
  against the new server — the REST contract did not change.

### What changed in the logs

- **Routine lines now go to standard output**, warnings and errors to standard
  error. Everything but the HTTP access log used to go to standard error, and a
  log collector that reads severity from the stream — Cloud Logging, most
  Kubernetes log agents — stamped the lot `ERROR`: a successful request's audit
  event arrived at the same severity as a crash, so `severity>=ERROR` matched
  the whole log.
- **The audit stream moved with it**, to standard output. Its content, logger
  name (`cocoindex_code_plus.audit`), and one-JSON-object-per-line shape are
  unchanged.
- **The HTTP access log stays on standard output but changes shape**: it now
  carries the same prefix as every other line — a timestamp, the level, and the
  logger name (`<ts> INFO uvicorn.access: … "GET /health HTTP/1.1" 200`) —
  where it read `INFO:     … "GET /health HTTP/1.1" 200 OK` before. It gains
  the timestamp it never had, and loses the trailing status phrase.

### What to do about the logs

Check anything that consumes the logs, and adjust it once:

1. **SIEM / audit ingestion** that selects the standard-error stream now finds
   nothing; point it at standard output (selecting by the logger name keeps
   working either way).
2. **Alerts on `severity>=ERROR`** were matching every request and are worth
   re-reading now that they mean what they say — a rule written to tolerate the
   old volume (a high threshold, a mute) will hide real errors.
3. **Log-based metrics or dashboards** built on the old access-line format need
   their pattern updated.

### Verify

After the upgrade, in your log store:

```bash
gcloud logging read 'resource.labels.namespace_name="ccx" AND severity>=ERROR' --freshness=1h
```

A healthy deployment returns nothing, while a query for `severity=INFO` shows
the audit events and access lines. Adjust the query to your log store; the
principle is that a served request is no longer an error.

## v0.1.44 — Insights prices model calls only

Applies when upgrading from v0.1.43 or earlier, to every deployment with
Insights enabled. The one step below is needed only if you configured a rate
sheet (`usageAnalytics.rates`).

### What changed

- **Compute and storage are no longer priced.** Cost figures are now
  **model cost** — agent and embedding model calls at your rates. The
  illustrative defaults priced infrastructure too, so every deployment's cost
  figures drop, rate sheet or not; the old figure was mostly a flat per-day
  estimate built from parameters the server cannot verify.
- **Tiles are named for what they price**: *Estimated model cost* on the
  overview and per repository, *Estimated embedding cost* on the indexing
  view, *Estimated agent cost* on the queries view. The index footprint is
  still shown, in bytes.
- **Daily charts start on the day analytics was enabled.** Every view says
  *data since* that day when it falls inside the range, and a quiet day after
  it is a zero, so charts over one window share an axis.
- **Four rate-sheet keys are gone**: `vcpu_hour`, `indexer_vcpus`,
  `query_server_vcpus`, and `storage_gb_month`. The server validates the sheet
  at startup and refuses unknown keys, so a values file that still sets any of
  them stops the query server from starting after the upgrade.

### Upgrade

1. **Remove those keys** from `usageAnalytics.rates` in your values file, if
   present. The remaining keys are unchanged.
2. **Upgrade the release** with the command above, `--version 0.1.44`.

### Verify

```bash
ccx usage overview --range 30d
```

The tile reads *Estimated model cost*. If the range reaches before the day
analytics was enabled, a *data since* note follows the window line.

## v0.1.41 — the symbol index finds more references, and Python names change shape

Applies when upgrading from v0.1.40 or earlier.

### What changed

Two fixes to how `ccx defs` / `ccx refs` read Python and, for the second one,
every supported language:

- **Python source roots are now inferred from the repo.** Previously a
  relative import only resolved inside the file's own directory and an
  absolute import only from the repo root, so a package split across several
  source roots — `python/*/src/<pkg>/`, the `src/` layout, one repo holding
  several installable distributions — did not resolve across them. The
  indexer now infers the roots from the tree and the repo's own imports
  (package markers, and the directories an absolute import actually resolves
  under). No configuration; nothing to set.
- **Calls inside an unreadable receiver are indexed.** A call written inside
  an expression the indexer cannot type — `(base_url or settings.url()).rstrip()`,
  `items[0].run()`, `handlers[key]()` — was dropped entirely, so those call
  sites appeared in **no** `ccx refs` output at all. They are now indexed in
  Python, TypeScript/JavaScript, C/C++, and C#.

The visible effect is that `ccx refs` returns call sites it used to miss, with
nothing needed from you.

**Python qualified names change spelling** where a package sits under a source
root: `python:mypkg.settings.server_url` where the old index said
`python:settings.server_url`. This affects `ccx defs --qualified-name` and
`ccx refs <qualified-name>`. The two-token `PATH ENTITY_ID` target form that
`ccx defs` prints under each row is **unaffected** — if you copy targets from
`defs` output rather than composing names by hand, nothing changes for you.

### Upgrade

1. **Upgrade the release** with the command above, `--version 0.1.41`.

2. **Let the indexer finish one full cycle.** This release re-extracts every
   file and rebuilds every ref's symbol graph — that is what applies the fixes
   to already-indexed repos, and it happens automatically on the first cycle.
   Expect that cycle to take noticeably longer than a normal one, roughly in
   proportion to how much code you index. Nothing else re-runs: file contents,
   chunks, and embeddings are content-addressed and are reused untouched, so
   there is no re-embedding cost and no new spend with your model provider.

   Queries keep working throughout. Each ref's old symbol rows serve until its
   new ones are ready, then swap.

3. **Update saved qualified-name queries**, if you have any — scripts, agent
   prompts, or bookmarks that pass `--qualified-name` for a Python symbol. Run
   `ccx defs <base-name>` to read the current spelling.

### Verify

Once the indexer has completed a cycle, pick a Python symbol your code calls
from inside a parenthesized or conditional expression and confirm the call
site now appears:

```bash
ccx refs <function-name> --role call
```

Check stderr for the coverage note as usual. To confirm the new name shape:

```bash
ccx defs <function-name>
```

The headline's qualified name now carries the package's full import path.

## v0.1.39 — one owner per database schema

Applies when upgrading from v0.1.38 or earlier.

### What changed

Every database schema now has exactly one owning role. When you enable the
answer cache or usage analytics, the query server's role creates and owns
their schemas (`ccx_agentic`, `ccx_usage`) at startup, and the indexer's
writer role inherits from it through Postgres role membership, so it builds
its own tables inside those schemas with no further grant. There is no
per-feature provisioning SQL any more. The whole setup, for both features and
any future one, is two statements run once as the database admin:

```sql
GRANT CREATE ON DATABASE <db> TO cocoindex_server;  -- it creates the schemas it owns
GRANT cocoindex_server TO cocoindex;                -- the indexer inherits them
```

Two smaller changes ride along:

- The values keys `usageAnalytics.url`, `usageAnalytics.existingSecret`, and
  `agentQuery.cache.url` are gone. Both features live in the target database.
  Helm ignores unknown keys silently, so remove them if you had set them.
- The guides now show the chart's default role names in every statement:
  `cocoindex_server` for the query server's role (it was `ccx_query`) and
  `cocoindex` for the indexer's. Your own roles keep whatever names they
  have; renaming is optional (below).

If you already run the answer cache with a pre-created `ccx_agentic`, nothing
changes for it.

### Upgrade

The upgrade itself changes nothing in your database. The two statements are
preparation: with them in place, turning on the answer cache or usage
analytics later is a values change and a rollout.

1. **Upgrade the release** with the command above, `--version 0.1.39`. Both
   workloads come back with the database privileges they have today; nothing
   in this step depends on the statements.

2. **Run the one-time role setup, before or after, as the database admin.**

   ```sql
   GRANT CREATE ON DATABASE <db> TO cocoindex_server;
   GRANT cocoindex_server TO cocoindex;
   ```

   The statements use the chart's default role names — `cocoindex_server`
   for the role the query server connects as, `cocoindex` for the role the
   indexer connects as; substitute the names in your DSNs. If the query
   server connects with the writer's credential, run only the first
   statement, granting that role. On Cloud SQL, a role created
   with `gcloud sql users create` still needs
   `REVOKE cloudsqlsuperuser FROM cocoindex_server;`, as
   [deploy.md](deploy.md#production-postgres-cloud-sql--external) describes.

   Prefer the chart to run them? Put an admin DSN in a Secret under the key
   `CCX_ADMIN_DB_URL` and set `database.provisioning.adminExistingSecret`. A
   Helm hook then applies both statements before every install and upgrade,
   reading the role names from your workload DSNs, which must be
   `existingSecret`s.

3. **Verify.**

   ```sql
   SELECT has_database_privilege('cocoindex_server', '<db>', 'CREATE') AS creates_schemas,
          pg_has_role('cocoindex', 'cocoindex_server', 'MEMBER') AS writer_inherits;
   ```

   Expect `creates_schemas = t` and `writer_inherits = t`. That is the whole
   precondition for either feature.

### Optional: rename the query server's role to `cocoindex_server`

Cosmetic, to match the guides. The DSN carries the role name, so the rename
and the credential update are one operation: do it in one sitting, after the
upgrade has finished, and never while a rollout is in progress, because every
pod that starts in between fails to authenticate.

```sql
ALTER ROLE ccx_query RENAME TO cocoindex_server;   -- ccx_query: the previous example name
```

Then, immediately, put the new username into the query server's DSN Secret
and restart the query server so it picks the Secret up. SCRAM passwords
survive a rename (the default on Postgres 14 and later, and on Cloud SQL), so
the password itself does not change. If the query server then fails on every
restart with `password authentication failed for user "ccx_query"`, the
Secret still carries the old name: Postgres reports an unknown role as a
password failure.

### When you enable the answer cache or usage analytics later

Startup is the loud moment: a component that lacks a privilege fails to start
and prints the exact statement to run, with your real database and role
names, rather than degrading silently.

| The log says | It means | Do |
|---|---|---|
| query server: `cannot create schema "…": it lacks CREATE on database "…"` | the first statement is missing | run it as printed |
| indexer: `can see schema "…" (owned by "…") but cannot build in it` | the second statement is missing | run it as printed |
| indexer: `schema "…" does not exist after waiting 300s` | no query server with analytics on and the same schema name is running against this database, or it could not create the schema | check the query server's own log and its `usageAnalytics` settings |

With analytics on, the indexer needs a running query server: the query server
creates the analytics schema, and the indexer waits up to five minutes for it
before failing. A standalone `ccx-indexer --once` run with
`CCX_USAGE_ANALYTICS_ENABLED=true` and no query server does the same.

### Bundled Postgres (evaluation installs)

Nothing to run: a Helm hook applies the two statements to the bundled
database before every upgrade. A volume created before v0.1.39 still holds
the query server's role under its old name, `ccx_query`, so set
`database.bundled.queryUsername: ccx_query` in your values or recreate the
volume.

## Rust workspace symbol metadata

This change requires an engine with internal `cargotoml` extraction support.
Upgrade the engine before the indexer. The indexer preflight names missing
language support and refuses startup with an older engine.

IR format 4 rebuilds derived symbol nodes. Rust extraction version 11 and
resolver behavior version 30 also invalidate older derived references. Existing
usage and change history remain intact. `Cargo.toml` keeps its TOML search chunks.
