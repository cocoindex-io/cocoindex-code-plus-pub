# CocoIndex Code Plus — Security & Deployment Guide

For customer security and platform teams. Everything here is verifiable in
the shipped artifacts. *Applies to CocoIndex Code Plus **v0.1.24 and later**.
Earlier releases predate parts of what follows: the interactive-docs routes
were disabled and the litellm egress pinned in **v0.1.8**, the structured JSON
audit stream arrived in **v0.1.14**, and agentic query — off by default — in
**v0.1.24**.*

## Architecture & trust model

CocoIndex Code Plus is **self-hosted software**: an indexer and a query
server run in your Kubernetes (Helm chart; images from GHCR or your own
mirror), all index data lives in your PostgreSQL (+pgvector), and the `ccx`
CLI / MCP endpoint serve your engineers and AI agents inside your network.
**CocoIndex operates no service in the data path and receives no customer
data.** There is no telemetry, analytics, or crash reporting in the shipped
product.

## What the product stores (in *your* database)

Code chunk text and embedding vectors; full file bodies; file paths; SHA-1
content/commit identifiers; branch/tag names; repository owner/name;
language; line/column positions. **Not extracted:** git author names,
emails, commit messages — the schema contains no developer-identity fields.
Retention is entirely yours (your database, your logs).

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

Enabling mirrored mode requires two named operator attestations
(`authz.attestations.*`) — explicit acknowledgments of facts the server
cannot verify itself (the context-control review; the instance-key binding
contract). Both are defined in the deploy guide.

## Network egress — the complete list

| Destination | When | Content | Your control |
|---|---|---|---|
| Embedding provider (your account & API key; LiteLLM) | index + query time | code-chunk text; query text | Choose any provider — Azure OpenAI, or a self-hosted in-VPC endpoint for **zero egress** (default config is an OpenAI model) |
| Completion provider for [agentic query](deploy.md#agentic-query) (your account & API key; LiteLLM) — **off by default** | query time, only while `agentQuery.enabled` | the caller's question, the tool schemas, the source snippets the agent chooses to read, and that request's conversation history | Off unless you turn it on; the model is operator configuration, never caller-selected. Credentials reach the **query server only**, never the indexer. See [AI/ML data handling](#aiml-data-handling) |
| `api.keygen.sh` (optional) | license validation (online mode only) | the license key string — nothing else | Use the **offline signed key** → no license egress at all |
| Your code hosts (GitHub/GitLab) | indexing — **and at query time under `codeHostMirrored`** (short-TTL cached) | repo content at index time; **identity and permission lookups only** at query time — never repo content | Your tokens, your scope |

Nothing else — including third-party libraries: the shipped images pin
litellm to its bundled model-cost data (`LITELLM_LOCAL_MODEL_COST_MAP=true`),
suppressing an import-time metadata fetch the library would otherwise make
(no customer data, but it would show up in an egress capture). If you build
your own images or run outside our containers, set that variable too.

**Fully air-gapped recipe:** mirror the images to your registry + offline
license key + in-VPC embedding endpoint + `agentQuery` left off (the default),
or pointed at a tool-calling model you host.

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
- **Secrets:** use the chart's `existingSecret` hooks to source credentials
  from your secret manager; nothing is baked into images (build secrets use
  BuildKit mounts).
- **Pods:** images run as a non-root user (uid 10001); set your
  `securityContext`/`runAsNonRoot`, resource limits, and NetworkPolicy per
  your cluster standards (the service needs only: ingress from clients,
  egress to your Postgres, code hosts, the embedding endpoint — plus the
  completion endpoint if you enable `agentQuery`, and `api.keygen.sh` if you
  use online license mode).

## Logging & audit

Both components log to stdout/stderr for your pipeline. The query server
emits HTTP access logs (auth failures visible as 401s) and a **structured
JSON audit stream** for your SIEM to ingest. There is no audit store we own
or can read. REST and MCP feed the same stream; a `route_class` field
distinguishes them.

Audit events go to the process's **standard error** under the logger name
`cocoindex_code_plus.audit` — one event per line, as a single JSON object
after the standard log prefix, so a collector can select the stream by that
name and take everything from the first `{`:

```
2026-08-13 09:14:22,418 INFO cocoindex_code_plus.audit: {"event":"request", …}
```

The examples below show the JSON bodies alone. There are exactly **two**
record kinds.

**A terminal `request` event, exactly one per request, whatever the
outcome.** It is emitted by the outermost middleware, so a rejection at any
stage — oversized URI, Origin, pre-auth, admission, authentication,
deadline — still produces exactly one, carrying the correlation id assigned
before any of them ran:

```json
{"event":"request","ts":"2026-08-13T09:14:22.418Z","correlation_id":"f9045689f8cb46b68a50066784612758","route_class":"code","operation":"semantic_search","status":200,"authn_outcome":"success","principal":"ccx:apikey/analytics-team","named_input_count":1,"resolved_repo_keys":["github:github.com:acme/web"],"result_count":3,"free_text":{"query":"[redacted]"}}
```

`operation` is `semantic_search`, `code_grep`, `read_file`, `find_files`,
`find_definitions`, `find_references`, `list_git_refs`, `list_repos`, or
`agent_query` — `null` when the request was rejected before routing.
`authn_outcome` is `success` / `failure` / `not_attempted`. Optional fields
appear when they apply: `azp` / `act` (client and actor identifiers),
`candidates_examined` (the `list_repos` page walk), `result_paths`, `agent`
(agentic-query counters — see [AI/ML data handling](#aiml-data-handling)),
and `tool_code` — an MCP tool error's code. Worth a rule in your SIEM: MCP
reports tool failures *inside* a successful response, so a failed MCP call
carries `status: 200` and its `tool_code`, not an HTTP error status.

**A `repo_decision` event per named repo the request actually processed** —
emitted at the authorization seam, joined to its request by
`correlation_id`:

```json
{"event":"repo_decision","ts":"2026-08-13T09:14:22.402Z","correlation_id":"f9045689f8cb46b68a50066784612758","principal":"ccx:apikey/analytics-team","operation":"semantic_search","outcome":"deny","repo_key":"github:github.com:acme/api"}
```

`outcome` is `allow` / `deny` / `indeterminate` when authorization ran (the
repo uid is present), or `not_resolved` / `ambiguous` when the name never
resolved (no uid exists, so the caller's input string appears instead, under
the free-text policy below). This is what makes the uniform `404` legible to
**you** without leaking anything to the caller: audit records each processed
input's real decision, while the client sees one indistinguishable 404.
Inputs the request short-circuited before processing have no decision event —
the terminal event's `named_input_count` exposes the gap.

Always logged in the clear: principal ids, repo uids, operation names,
decision outcomes, counts, status, and `authn_outcome`. **Never** logged: raw
claims and token material. The client/actor identifiers (`azp`, `act`) are
recorded only from a token that *validated* — a failed validation's claims are
attacker-controlled text.

### Caller free text is redacted by default

`audit.freeText` governs **all** caller-supplied free text uniformly — query
text, grep patterns, path globs, `read_file` / `find_files` paths, and symbol
targets. (A toggle that redacted the query while logging the grep pattern
would redact nothing.)

| `audit.freeText` | Rendered as | Notes |
|---|---|---|
| `redact` — **the default** | `[redacted]` | nothing the caller typed reaches the log |
| `hmac` | `hmac:<32 hex chars>` | a **keyed** HMAC-SHA-256: stable per key, so an analyst can correlate repeated queries without reading them. Requires `audit.hmacKeySecret` — an unkeyed digest of low-entropy text would be dictionary-invertible by anyone reading the SIEM, so the server refuses `hmac` without key material |
| `plain` | verbatim | development only |

A separate `audit.logResultPaths` (default `false`) decides whether
result-derived filenames, refs, and aliases are logged at all; when enabled
they still pass through the same policy. These keys live in the chart's
`audit:` block — setting any of them moves auth configuration onto the chart's
file lane ([Chart configuration](deploy.md#chart-configuration)).

Even at the default the stream still identifies **who** searched **which
repo**, so apply your normal log retention and access controls to it.

One scope limit, stated plainly: the redaction promise above covers the
**application audit stream**. Repo aliases ride in URL paths (e.g.
`GET /repo/v0/git_refs/{repo}`), so they appear in your ingress and
web-server **access logs** regardless of any audit setting — retention and
redaction there are yours.

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

CocoIndex trains no models and **never trains on customer data**. Every model
call goes exclusively to an endpoint *you* configure under *your* key. Two
inference capabilities ship today.

### Text-embedding inference — always on

Code-chunk text at index time and query text at query time go to your
configured embedding provider, including asynchronous indexing-time calls.
Point `embedding` at a self-hosted in-VPC endpoint for zero egress.

### Agentic query — off by default

`agentQuery` (`POST /code/v0/query`, the MCP `query_codebase` tool, and
`ccx query`) runs a server-side agent that investigates your indexed code and
returns a cited prose answer instead of raw hits. It is **disabled by
default**, because enabling it moves source code to a model provider — an
operator data-governance decision, not one a default should make. Setup is in
the deploy guide's [Agentic query](deploy.md#agentic-query) section; the data
flow is:

- **What leaves the cluster**, per query, to your configured completion
  provider: the caller's question, the tool schemas, the source snippets the
  agent chooses to read, and that request's conversation history. Provider
  credentials are read by LiteLLM from the query server's environment and
  never appear in prompts, tool results, responses, or logs. The model is
  operator configuration — never caller-selected, with no per-request
  provider override.
- **What the agent can reach:** a closed tool set — search, grep, read file,
  list files, symbol definitions and references — running through **the same
  authorized reads the low-level API already exposes**. The authorized scope
  is established before inference and re-proved against a fresh scope before
  any answer is returned; each read is bound to the commit resolved at the
  start of the request, so a ref that moves mid-run fails the request rather
  than blending revisions. There is no fetch, shell, filesystem, secret, or
  mutation tool, and no repository the caller could not already search
  itself. One exposure, stated rather than omitted: if a caller's access is
  revoked *mid-run*, reads already in flight can still reach the model
  context — the final check then fails the request, so no answer is returned.
- **What is stored: nothing new.** The transcript exists only in request
  memory — no trace file, no trace table, no stored prompts or answers, no
  new database. The audit stream gains only plain counters (model, tool, and
  subquery counts; token totals; finish code; artifact count). Prompts,
  source snippets, model text, subquery questions, tool arguments, and
  artifact contents are never logged.
- **Untrusted-input posture:** indexed source, comments, documentation, and
  file names are treated as data, not instructions. A successful prompt
  injection still faces the closed capability set above — there is nothing to
  escalate into. The answer text is the one channel that stays open, so treat
  answer and artifact Markdown as untrusted model output: render it without
  automatic remote fetches, and note that citations are not yet mechanically
  verified.
- **Cost and load are bounded per request**, not left to a knob: one query is
  capped at 30 model turns plus at most 8 helper sub-investigations of 15
  turns each, under a whole-query deadline (`requestDeadlineSeconds`, default
  600 s) and per-pod concurrency caps.

Any future inference capability is governed by the same invariants:
customer-keyed endpoints only, air-gap compatible or disableable, data flows
documented here **before** release.

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
