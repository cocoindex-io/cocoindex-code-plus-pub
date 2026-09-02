# Upgrading CocoIndex Code Plus

How to move a deployment from one release to the next. This page is the
place to check before every upgrade: releases that need anything beyond the
upgrade command have an entry below, newest first.

## The normal upgrade

Every release ships as a new chart version with matching images. The upgrade
is one command, and the index is never rebuilt by an upgrade:

```bash
helm upgrade <release> oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus \
  --version <X.Y.Z> -n <namespace> -f values.yaml
```

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
