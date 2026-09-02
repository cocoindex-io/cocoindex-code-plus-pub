# CocoIndex Code Plus — Security & Deployment Guide

For customer security and platform teams. Everything here is verifiable in
the shipped artifacts. *Applies to CocoIndex Code Plus **v0.1.40 and later**.
Earlier releases predate parts of what follows: the disabled interactive-docs
routes and the litellm egress pin (v0.1.8), the structured JSON audit stream
(v0.1.14), agentic query (v0.1.24) and its answer cache (v0.1.29), usage
analytics (v0.1.37), and the `reason` on audit denials (v0.1.40).*

## Architecture & trust model

CocoIndex Code Plus is **self-hosted software**: an indexer and a query
server run in your Kubernetes (Helm chart; images from GHCR or your own
mirror), all index data lives in your PostgreSQL (+pgvector), and the `ccx`
CLI / MCP endpoint serve your engineers and AI agents inside your network.
**CocoIndex operates no service in the data path and receives no customer
data.** There is no telemetry or crash reporting in the shipped product, and
no analytics that leave your deployment: the optional usage dashboards
([ccx Insights](insights.md)) are computed from, and stored in, your own
database.

## What the product stores (in *your* database)

Everything below lives in the PostgreSQL you configure. Retention is entirely
yours (your database, your logs).

- **The index** — always: code chunk text and embedding vectors; full file
  bodies; file paths; SHA-1 content/commit identifiers; branch/tag names;
  repository owner/name; language; line/column positions. **Not extracted:**
  git author names, emails, commit messages — the index schemas contain no
  developer-identity fields.
- **The agentic answer cache** — only under `agentQuery.cache.enabled`, in
  its own schema (`ccx_agentic` by default): the questions callers asked,
  verbatim, with their embeddings; the generated answers; and the
  investigation record behind each answer — the agent's tool calls (tool name
  and arguments), its intermediate notes, and content **fingerprints** of what
  those calls returned and of the commits and paths they depended on. The
  source the agent read is not copied into the cache; an answer contains only
  what the model chose to quote. No caller identity is stored with a
  question. Removal is per repository (the purge command) or by dropping the
  schema's tables — see the deploy guide's
  [Answer cache](deploy.md#answer-cache-optional).
- **Usage analytics** — only under `usageAnalytics.enabled`, in its own
  schema (`ccx_usage` by default): one row per request — principal,
  operation, repository uids, status, durations, client kind and version,
  agentic-query counters and token totals — plus daily rollups, under
  configurable retention windows. **No caller free text under any setting**:
  no query text, patterns, or paths. See
  [Usage analytics](deploy.md#usage-analytics-ccx-insights).

## Who can read which repos (authorization)

*Authorization is a separate axis from authentication; both are set out together
in the deploy guide's [Access](deploy.md#access-authentication--authorization).*

Per deployment, one of two modes:

- **`indexScope`** (default): any authenticated caller searches everything
  indexed — the PR-reviewed index config repo is the access-control
  authority, by governing what gets indexed in the first place.
- **`codeHostMirrored`**: results mirror each caller's live code-host
  permissions (setup in the [deploy guide](deploy.md#code-host-mirrored-authorization)).
  The guarantees, stated precisely:
  - A repo the caller cannot read **never participates** in results,
    ranking, or counts — and is **indistinguishable from a nonexistent
    repo** in every response (one uniform 404, no name echo, no candidate
    lists).
  - Checks **fail closed**: an identity the deployment cannot map is
    granted public repos only; a check the server cannot complete (code-host
    outage, rate limiting, misconfiguration) is a `503` — never a grant,
    never a silent downgrade.
  - The server keeps **no authorization state** of its own — only
    short-TTL caches of code-host answers. Your code host and IdP stay the
    sources of truth: revocation and offboarding happen entirely in your
    systems and propagate within cache TTL plus token lifetime.
  - API-key records are governed by their **own** configured scope
    (index-wide or an explicit repo list), never mirrored — a key has no
    code-host identity. Issue them accordingly.

Enabling mirrored mode requires named operator attestations
(`authz.attestations.*`) — explicit acknowledgments of facts the server cannot
verify itself. **`contextControlReviewCompleted`** (the context-control review)
is required whenever the mode is on; **`instanceBindingContractAccepted`** (the
instance-key binding contract) is required alongside a code-host registry.
Individual identity-mapping routes require one more —
`ghesScimPatAccepted`, `ghesManagedUsernames`, `gitlabManagedUsernames`. The
server refuses to start without the ones your configuration needs and names
them; all are defined in
[the deploy guide](deploy.md#code-host-mirrored-authorization).

### Agentic query runs inside the same authorization

`ccx query` (and the MCP `query_codebase` tool) adds no authorization path of
its own, under either mode:

- The server resolves and authorizes the caller's **complete named repository
  set once, at admission** — before any model call, embedding, or cache
  lookup. A nonexistent or unauthorized repository fails the whole request
  with the same uniform 404.
- The agent's tools are **the same authorized reads** the low-level API
  exposes, so it cannot see a repository the caller could not already search.
- A cached answer is served only to a caller whose own request was admitted
  for that answer's repositories. A cache entry is never evidence of
  authorization, and the denial path consults no cache, so the cache adds no
  existence or timing signal.

## Network egress — the complete list

| Destination | When | Content | Your control |
|---|---|---|---|
| Embedding provider (your account & API key; LiteLLM) | index + query time | code-chunk text; query text — under agentic query also the search phrases the agent composes and, with the answer cache, the question itself | Choose any provider — Azure OpenAI, or a self-hosted in-VPC endpoint for **zero egress** (default config is an OpenAI model) |
| Completion provider for [agentic query](deploy.md#agentic-query) (your account & API key; LiteLLM) — **off by default** | query time, only while `agentQuery.enabled` | per query: the caller's question, the tool schemas, the source snippets the agent chooses to read, and that request's conversation history | Nothing is sent until you turn it on. The model is operator configuration, never caller-selected; its credentials reach the **query server only**, never the indexer (`agentQuery.secretEnv` / `existingSecret`). Any tool-calling LiteLLM model works, including one you host in-VPC |
| `api.keygen.sh` (optional) | license validation (online mode only) | the license key string — nothing else | Use the **offline signed key** → no license egress at all |
| Your code hosts (GitHub/GitLab) | indexing — **and at query time under `codeHostMirrored`** (short-TTL cached) | repo content at index time; **identity and permission lookups only** at query time — never repo content | Your tokens, your scope |
| Your IdP / authorization server (under `auth.mode: oidc`) | query-server startup + cached refresh | **fetches only**: OIDC discovery + the JWKS public keys — no customer data is sent | It's your IdP; a self-managed one keeps this in-VPC (private CA via `auth.oidc.caBundleSecret`) |

Nothing else — including third-party libraries: the shipped images pin
litellm to its bundled model-cost data (`LITELLM_LOCAL_MODEL_COST_MAP=true`),
suppressing an import-time metadata fetch the library would otherwise make
(no customer data, but it would show up in an egress capture). If you build
your own images or run outside our containers, set that variable too.

**Fully air-gapped recipe:** mirror the images to your registry + offline
license key + in-VPC embedding endpoint — and leave `agentQuery` off (the
default), or point it at a tool-calling model you host.

## Deployment hardening checklist

- **Authentication:** bearer-token (`apiKey`) mode is the default and
  fail-closed — missing/invalid credentials get 401 on every route
  returning code or index data, REST and MCP alike. Exactly three routes
  are unauthenticated, `GET`/`HEAD` only, none of them touching index
  data: `/health`, `/openapi.json` (the interface *description* — generated
  from the same paths and request models that ship in the public `ccx`
  package), and — under `oidc` —
  `/.well-known/oauth-protected-resource/mcp`, which a client reads
  precisely because it has no credential yet. Swagger/ReDoc are not
  served. Never run `CCX_AUTH_MODE=none` outside local development (it
  warns loudly). Modes and key records:
  [Access](deploy.md#access-authentication--authorization); rotation:
  [Operate](deploy.md#operate).
- **TLS:** terminate at your ingress; the chart ships with ingress
  **disabled** by default and its install notes state the TLS-in-front
  requirement. Fronting the service with your ZTNA (e.g., ZPA) adds your
  own SSO/MFA.
- **PostgreSQL:** for an external database, set `sslmode=require` (or
  `verify-full`) in `CCX_TARGET_DB_URL` — the application passes your DSN
  through verbatim. The chart's bundled Postgres is for evaluation only.
- **Secrets:** use the chart's `existingSecret` hooks — every secret group
  has one, the completion-model key's (`agentQuery.existingSecret`) included
  — to source credentials from your secret manager; nothing is baked into
  images (build secrets use BuildKit mounts).
- **Pods:** images run as a non-root user (uid 10001); set your
  `securityContext`/`runAsNonRoot`, resource limits, and NetworkPolicy per
  your cluster standards (the service needs only: ingress from clients,
  egress to your Postgres, code hosts, the embedding endpoint — plus the
  completion endpoint if you enable `agentQuery`, and `api.keygen.sh` if you
  use online license mode).

## Logging & audit

Both components log to stdout/stderr for your pipeline. The query server
emits HTTP access logs (auth failures visible as 401s) and a **structured
JSON audit stream** — REST and MCP alike — for your SIEM. There is no audit
store we own or can read.

### Where the stream is

On the query server's standard error, under the logger name
`cocoindex_code_plus.audit`: one event per line, a single JSON object after
the standard log prefix. Select the stream by logger name and parse from the
first `{`:

```
2026-09-02 09:14:22,418 INFO cocoindex_code_plus.audit: {"event":"request", …}
```

### Two record kinds

- **One `request` event per request, whatever the outcome.** The outermost
  middleware emits it, so a rejection at any stage — oversized URI, Origin,
  authentication, admission, deadline — still produces exactly one, carrying
  the correlation id assigned before those stages ran.
- **One `repo_decision` event per named repository the request processed**,
  emitted at the authorization seam and joined to its request by
  `correlation_id`. `outcome` is `allow` / `deny` / `indeterminate` when
  authorization ran (the repository uid is present), or `not_resolved` /
  `ambiguous` when the name never resolved (no uid exists; the caller's
  input appears only under the free-text policy below). Every `deny` and
  `indeterminate` also carries a closed-vocabulary `reason` — the table is
  in the deploy guide's [Verifying a rollout](deploy.md#verifying-a-rollout).

This is what keeps the uniform 404 legible to **you**: audit records each
processed input's real decision while the caller sees one indistinguishable
404. A search naming one readable and one withheld repository:

```json
{"event":"repo_decision","ts":"2026-09-02T09:14:22.402Z","correlation_id":"f9045689f8cb46b68a50066784612758","principal":"ccx:apikey/analytics-team","operation":"semantic_search","outcome":"allow","repo_key":"github:github.com:6105489"}
{"event":"repo_decision","ts":"2026-09-02T09:14:22.404Z","correlation_id":"f9045689f8cb46b68a50066784612758","principal":"ccx:apikey/analytics-team","operation":"semantic_search","outcome":"deny","repo_key":"github:github.com:6105490","reason":"not_allowlisted"}
{"event":"request","ts":"2026-09-02T09:14:22.418Z","correlation_id":"f9045689f8cb46b68a50066784612758","route_class":"code","operation":"semantic_search","status":404,"duration_ms":31,"authn_outcome":"success","principal":"ccx:apikey/analytics-team","principal_kind":"api_key","client_kind":"cli","client_version":"0.1.40","error_code":"repo_not_found","named_input_count":2,"resolved_repo_keys":["github:github.com:6105489"],"free_text":{"query":"[redacted]"}}
```

`operation` is `semantic_search`, `code_grep`, `read_file`, `find_files`,
`find_definitions`, `find_references`, `list_git_refs`, `list_repos`,
`agent_query`, or a `usage_*` read of the Insights API — `null` when the
request was rejected before routing. `route_class` is `code`, `repo`, `mcp`,
or `other`. Optional fields appear when they apply: `error_code` (the same
closed vocabulary the wire returns), `azp` / `act` (client and actor
identifiers, from a validated token only), `result_count`,
`candidates_examined` and `denied_by_reason` (the `list_repos` walk — counts,
never which repos), `result_paths`, and `agent` — the agentic query's
counters: model, tool, and subquery counts, token totals, cache reuse, the
cost split, and a `finish` code; never prompts, snippets, or model text. One
rule worth a SIEM alert: MCP reports a tool failure *inside* a successful
response, so a failed MCP call carries `status: 200` with an `error_code`,
not an HTTP error status.

### Caller free text is redacted by default

`audit.freeText` governs **all** caller-supplied free text uniformly — search
queries and agentic questions, grep patterns, path globs, `read_file` /
`find_files` paths, symbol names, and a repository name that failed to
resolve. (A toggle that redacted the query while logging the grep pattern
would redact nothing.)

| `audit.freeText` | Rendered as | Notes |
|---|---|---|
| `redact` — **the default** | `[redacted]` | nothing the caller typed reaches the log |
| `hmac` | `hmac:<digest>` | a **keyed** HMAC-SHA-256 (32 hex chars): stable per key, so an analyst can correlate repeated queries without reading them. Requires `audit.hmacKeySecret` — the server refuses to start under `hmac` without key material, because an unkeyed digest of low-entropy text is dictionary-invertible by anyone reading the SIEM |
| `plain` | verbatim | development only |

`audit.logResultPaths` (default `false`) decides whether result-derived file
paths, refs, and aliases are logged at all; when enabled they pass through
the same policy. Both keys live in the chart's top-level `audit:` block,
which is on the file lane ([The lane rule](deploy.md#the-lane-rule)).

Always logged in the clear: principal ids, repository uids, operation names,
decision outcomes and reasons, counts, and status. Never logged: raw token
claims or token material. Even at the default the stream identifies **who**
used **which repository**, so apply your normal log retention and access
controls. One scope limit: repository aliases ride in URL paths
(`GET /repo/v0/git_refs/{repo}`), so they appear in your ingress access logs
regardless of any audit setting — retention and redaction there are yours.

## Supply-chain verification

### SBOM

A complete SBOM bundle is published for every release at
[cocoindex-code-plus-pub → Releases](https://github.com/cocoindex-io/cocoindex-code-plus-pub/releases)
(tag `sbom-vX.Y.Z`). **No credentials needed** — you do not need image pull
access to review it, so it's available during evaluation.

Each bundle carries, in both **SPDX 2.3** and **CycloneDX**:

- both container images, **per platform** (`linux/amd64`, `linux/arm64`) —
  covering the Debian packages from the `python:3.11-slim` base and every Python
  distribution in the runtime environment;
- the `ccx` CLI as resolved from PyPI;
- license attribution for the Rust crate tree inside the CocoIndex Plus engine;
- the optional upstream images the Helm chart can deploy on your behalf.

Verify the bundle (one signature covers every asset):

```bash
cosign verify-blob SHA256SUMS --signature SHA256SUMS.sig --certificate SHA256SUMS.pem \
  --certificate-identity-regexp '^https://github\.com/cocoindex-io/cocoindex-code-plus/\.github/workflows/release\.yml@refs/tags/v.*$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
sha256sum -c SHA256SUMS
```

Once you have image pull access, the same content is also attached to each image
digest at build time, which is the authoritative per-digest record:

```bash
docker buildx imagetools inspect ghcr.io/cocoindex-io/ccx-query-server:<tag> --format '{{ json .SBOM }}'
```

One scope note: the CocoIndex Plus engine ships as a compiled extension module,
so scanners resolve it to a single `cocoindex-plus` component rather than to the
Rust crates compiled into it. The attribution file in the bundle is the record
for that subtree.

### Signatures

- Container images: **cosign-signed (keyless OIDC)** with **SBOM +
  build-provenance attestations**. Working verifier:

  ```
  cosign verify ghcr.io/cocoindex-io/ccx-query-server:<tag> \
    --certificate-identity-regexp '^https://github\.com/cocoindex-io/cocoindex-code-plus/\.github/workflows/release\.yml@refs/tags/v.*$' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
- Helm chart (OCI): cosign-signed (keyless OIDC).
- CLI: published to PyPI via **Trusted Publishing** (OIDC — no long-lived
  publish credentials exist).
- Releases are tag-gated: `main` requires PRs + passing CI, and the release
  jobs run only behind `v*`-tag-restricted deployment environments.

## AI/ML data handling

CocoIndex trains no models and **never trains on customer data**. Every
model call goes exclusively to an endpoint *you* configure under *your* key.
Two inference capabilities ship today; anything later is governed by the
same invariants — customer-keyed endpoints only, air-gap compatible or
disableable, and its data flow documented in this section.

### Text-embedding inference — always on

Code-chunk text at index time and query text at query time go to your
configured embedding provider (`embedding.model`, any LiteLLM provider),
including asynchronous indexing-time calls. A self-hosted in-VPC endpoint
gives zero egress.

### Agentic query — off by default

`ccx query`, the MCP `query_codebase` tool, and `POST /code/v0/query` run a
server-side agent that investigates your indexed code and returns a cited
prose answer instead of raw hits. Turning it on (`agentQuery.enabled`, with a
`model`) is an operator data-governance decision, because it sends source
code to a model provider; while it is off, nothing is sent. Setup is in the
deploy guide's [Agentic query](deploy.md#agentic-query) section. The data
flow:

- **What leaves the cluster**, per query, to the completion provider you
  configure: the caller's question, the tool schemas, the source snippets the
  agent chooses to read, and that request's conversation history. Provider
  credentials are read by LiteLLM from the query server's environment and
  are never placed in prompts, tool results, or responses.
- **What the agent can do**: a closed, read-only tool set — the same
  searches, greps, file reads, and symbol lookups the low-level API serves —
  over the repositories authorized at admission
  ([above](#agentic-query-runs-inside-the-same-authorization)). Everything a
  tool returns is treated as untrusted model input: the system prompt says
  so and forbids external URLs in answers, and a successful prompt injection
  still meets no mutation, network, filesystem, secret, or process tool.
  Render answers as untrusted Markdown, without automatic remote fetches.
- **What is stored**: nothing, by default — the transcript lives in request
  memory only, and the audit event gains plain counters plus the question
  under the free-text policy. With the optional answer cache on, the
  questions, answers, and investigation records listed under
  [What the product stores](#what-the-product-stores-in-your-database) live
  in your Postgres.
- **Bounds**: the model and its reasoning effort are operator configuration,
  never caller-selected. One query is capped at 30 model turns plus at most
  8 helper sub-investigations of 15 turns each, under a per-request deadline
  (`agentQuery.requestDeadlineSeconds`, default 600 s) and per-pod
  concurrency limits.

## Vulnerability reporting & fixes

Report to **security@cocoindex.io** (canonical policy:
[SECURITY.md](../SECURITY.md);
also discoverable via <https://cocoindex.io/.well-known/security.txt>, RFC 9116) —
acknowledgment within 3 business days, coordinated disclosure preferred.
Critical vulnerabilities in shipped versions: assessed within 24 hours,
fixed or mitigated within 14 days, with affected customers notified via the
fix-release advisory. Dependencies are fully pinned and hash-verified; Dependabot runs on all
product repositories; GitHub secret scanning with push protection runs on
the public repositories, complemented by gitleaks pre-commit hooks and
quarterly full-history scans across all of them.
