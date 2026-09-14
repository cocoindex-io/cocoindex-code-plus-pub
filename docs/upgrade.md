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
