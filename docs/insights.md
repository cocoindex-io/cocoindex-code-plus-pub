# ccx Insights — usage, cost and savings

Insights answers three questions about a CocoIndex Code Plus deployment: who
is using it, what it costs, and what the caching saved. It is **off by
default** and, when on, adds no new deployable component — the numbers are
collected by the two services you already run and stored in one Postgres
schema.

Nothing leaves your deployment. There is no telemetry endpoint, no vendor
callback, and no aggregate we receive.

**Contents**

- [Turning it on](#turning-it-on)
- [Who can see what](#who-can-see-what)
- [The web UI (`ccx ui`)](#the-web-ui-ccx-ui)
- [The terminal (`ccx usage`)](#the-terminal-ccx-usage)
- [Reports you can e-mail](#reports-you-can-e-mail)
- [Rates: units in, currency out](#rates-units-in-currency-out)
- [SQL views for BI and Grafana](#sql-views-for-bi-and-grafana)
- [How much storage it needs](#how-much-storage-it-needs)
- [Reading the numbers honestly](#reading-the-numbers-honestly)

## Turning it on

One switch wires both workloads — developers running `ccx` configure nothing:

```yaml
usageAnalytics:
  enabled: true
```

Enabling it also defaults `indexer.cycleSeconds` to `300`, because the
indexing metrics count *cycles* and live mode has no pass boundary to count.
An explicit `indexer.cycleSeconds` still wins.

With the bundled Postgres the chart provisions the schema for you — but its
init scripts run **only on a first, empty data directory**. Turning analytics
on for a deployment whose bundled volume already exists means they never run,
and the query server fails startup naming the grant it needs. Run the
statements below by hand in that case.

With your own Postgres, run them once as a superuser (adjust the names to
match your values):

```sql
-- The indexer's credential owns the schema; the query server's is granted
-- CREATE so each service makes and maintains its own tables.
CREATE SCHEMA IF NOT EXISTS ccx_usage AUTHORIZATION cocoindex;
GRANT USAGE, CREATE ON SCHEMA ccx_usage TO ccx_query;
```

The query credential also needs to read the indexer's analytics tables. If it
holds `pg_read_all_data` (the chart's bundled role does) that is already
covered; otherwise grant `SELECT` on the indexer's tables in that schema.

**Enabled but unprovisioned fails startup, loudly.** That is deliberate: an
analytics feature that silently collected nothing would be discovered weeks
later, from an empty dashboard. The error names the exact grant to run, so
the fix is a copy-paste rather than a diagnosis.

Analytics history lives in its own schema and **survives an index rebuild** —
dropping and re-indexing your repositories does not reset your usage history.

## Who can see what

Two levels, and the split is deliberate:

| Surface | Who |
|---|---|
| Per-repository usage, cost and savings | any authenticated caller, for the repositories they can already query |
| Organization-wide totals, error triage, identity drill-down | callers holding the **`ccx.usage.read`** entitlement |

`ccx.usage.read` is **additive**: it grants the organization-wide views and
takes nothing away. A developer without it keeps the ordinary search surface
and their own repositories' figures.

Grant it the same way as `ccx.read` — see [sso.md](sso.md). For a service
account (a BI job, a scheduled report), add it to the API key record:

```yaml
auth:
  apiKeys:
    - id: reporting
      secretHash: sha256:…
      label: quarterly reporting job
      entitlements: [ccx.usage.read]
```

## The web UI (`ccx ui`)

```bash
ccx ui
```

This serves the dashboard on a loopback port and opens it. The page reads the
same API everything else does; your CLI proxies those reads with your stored
token, so **the token never reaches the page** and the query server needs no
browser-session or CORS surface.

The link `ccx ui` prints carries a one-time session secret — open that link
rather than typing the bare address, and don't share it: it is what stops
another process on your machine from driving the proxy. `--no-open` prints
the URL instead of launching a browser.

Four views: **Overview** (headline savings and spend), **Repositories** (per
repository, no entitlement needed), **Indexing** (cycles, freshness,
footprint), and **Queries & agents** (operations, latency, agent reuse,
errors).

## The terminal (`ccx usage`)

```bash
ccx usage                     # your repositories — no entitlement needed
ccx usage overview            # organization headline figures
ccx usage indexing            # cycles, freshness, footprint
ccx usage queries             # operations, latency, agent reuse, errors
```

`--range 7d|30d|90d` picks the window (default `30d`). `--json` prints the API
response verbatim, which is the supported shape for scripting — the table
layout is not.

Running an organization-wide subcommand without the entitlement tells you so
and points at the per-repository view, rather than failing opaquely.

## Reports you can e-mail

```bash
ccx usage --report insights-q3.html --range 90d
```

One self-contained HTML file: no network access when opened, no external
assets, the data embedded. It renders with the same code as the web UI.

**What a report deliberately does not contain**: principal labels (who ran
what) and correlation ids (the handles for pulling one request's logs). A
report carries aggregate counts only, so forwarding it does not forward the
means to identify a person or to look up an individual request. Sections the
person generating it could not see are simply absent.

Whoever runs it needs `ccx.usage.read` for the organization-wide sections;
without it the report still contains their repositories. Scheduling is yours —
cron, CI, whatever you already run.

## Rates: units in, currency out

**Dollar figures are never stored.** The database holds tokens, chunks,
requests and milliseconds; a rate sheet turns them into currency when a page
is rendered. Prices change and contracts differ, so a stored dollar figure
would be wrong the day after it was written — while the units stay true.

Without a rate sheet every surface labels its figures **illustrative** and
means it. Being explicitly approximate beats implying a real number.

```yaml
usageAnalytics:
  rates:
    currency: USD
    embedding_per_mtok: 0.13
    agent_input_per_mtok: 3.00
    agent_output_per_mtok: 15.00
    vcpu_hour: 0.048
    indexer_vcpus: 4
    query_server_vcpus: 4     # TOTAL across replicas
    storage_gb_month: 0.17
    tokens_per_chunk: 260     # drives embedding tokens from chunk counts
```

Every key is optional; unset ones keep the built-in illustrative value. The
sheet is validated at startup, so a typo or a non-positive number fails there
rather than rendering a nonsense figure.

## SQL views for BI and Grafana

The schema exposes a set of views as its **stable surface**. Read the views,
not the tables underneath them — the tables are free to change shape between
releases, the views are not.

| View | Grain |
|---|---|
| `v_requests_daily` | day × route × operation × client × status × error code |
| `v_repo_activity_daily` | day × repository × operation |
| `v_agent_daily` | day × repository, plus the organization row |
| `v_indexing_daily` | day × repository, plus the deployment row with cycle stats |
| `v_footprint_daily` | day × grain × group |
| `v_error_codes_daily` | day × error code × status |
| `v_usage_status` | one row: freshness of the numbers themselves |
| `v_freshness_current` | one row per repository: is the index keeping up |

Three rules the views follow:

1. **Columns are only ever added**, never repurposed. A dashboard built today
   keeps working.
2. **Units are in the names** — `_ms`, `_bytes`, `_tokens` — so a chart legend
   cannot misdescribe what it plots.
3. **Organization rows are marked, not implied.** They carry
   `is_org_total = true` and a `NULL` repo_key. This matters: per-repository
   *counts* deliberately overlap, because one request naming three
   repositories counts once for each. **Summing per-repository rows does not
   give you an organization total** — filter `WHERE repo_key IS NOT NULL` for
   per-repository work, and read the marked row for the total.

To give a BI tool read access:

```sql
CREATE ROLE bi_reader LOGIN PASSWORD '…';
GRANT USAGE ON SCHEMA ccx_usage TO bi_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA ccx_usage TO bi_reader;
```

> **Granting the BI role is granting organization-wide read.** It is the same
> decision as handing out the `ccx.usage.read` entitlement, made in a
> different place, and it deserves the same owner's approval. If you want the
> role limited to the stable surface, grant `SELECT` on the individual views
> instead of `ALL TABLES`.

Identity-grain tables have **no views**: BI gets counts, never who. If you
grant `ALL TABLES` those underlying tables are reachable — grant per-view if
that matters to you.

Re-running an upgrade preserves your grants. If a view's shape changes in a
pre-release build the service recreates it and logs that the grants went with
it — re-apply them.

## How much storage it needs

Raw request events are ~99% of the total, so one number drives everything:

> **≈ 50 MB per weekday-active developer**, at the 90-day default retention.

A 50-developer deployment lands near **3 GB**; 1,000 developers near
**50–60 GB**. Measured at 241 bytes per event including indexes.

The two knobs that matter are both linear: request volume and
`retention.rawDays`. Halving the raw horizon halves the total. Rollups
(400-day default) and the indexer's own rows are megabytes, not gigabytes —
the indexer records *cycles that did work*, not every poll.

The schema's own size shows up in the Indexing view's footprint under the
group `usage`, so the cost of analytics is visible inside analytics.

To put analytics on cheaper storage than the index, point it at another
database and move the grants with it:

```yaml
usageAnalytics:
  # A DSN is a credential: set inline it lands in the chart's Secret (never a
  # ConfigMap), or name your own Secret carrying the key CCX_USAGE_DB_URL.
  url: postgres://…
  # existingSecret: my-analytics-dsn
```

Provision the schema on that database with the same two statements, and move
the read grant with it.

## Reading the numbers honestly

Every surface carries its own caveats rather than presenting partial data as
settled:

- **Partial days** are named. Today is always partial.
- **Comparisons are suppressed** until there is a comparable prior period, so
  a new deployment shows no misleading "+900%".
- **Unknown is not zero.** Token totals exclude queries whose provider
  returned no count, and say how many. Time-saved excludes cache hits with no
  stored duration, and says how many.
- **Savings are measured, not modelled.** "Cost saved" values reuse at what
  producing the same result again would have cost. "Agent time saved" is wall
  time on both sides of the subtraction — the stored original's duration less
  what serving from cache actually took. There is no productivity multiplier
  anywhere, and the figure is a lower bound by construction.
- **Rates are labelled** as illustrative until you configure them.

If a number looks wrong, `v_usage_status` reports how fresh the aggregates
are and whether anything is still pending or was dropped under load.
