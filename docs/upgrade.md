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
