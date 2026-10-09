# Upgrading CocoIndex Code Plus

How to move a deployment from one release to the next. This page is the
place to check before every upgrade: releases that need anything beyond the
upgrade command have an entry below, newest first.

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
and the symptoms of a CLI that is too old).

## Reading the entries

- **An entry is written for the release right before it.** When you skip
  releases, apply the entries you skipped from oldest to newest.
- **A release without an entry needs nothing but the command above.**
- Each entry says what changed, what to do (before or after the command), how
  to verify, and what is optional.

## v0.1.55 — indexed refs and their commits are shown wherever repositories are listed; symbol steps run one at a time; the indexer logs its memory

Nothing is required — upgrade normally, and upgrade the `ccx` CLI with it.
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
  progress, every ten minutes while idle, and at each symbol step's
  boundary. Include those lines when you report an OOM kill.
- **The sizing guide covers new refs.** A branch or tag added to an indexed
  repository is a first pass of its new content, the refs of one repository
  walk one at a time, and `indexer.maxFilesInFlight` bounds the files in
  progress, not the files read ahead of them.

### What to do

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
