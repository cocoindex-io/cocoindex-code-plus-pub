# CocoIndex Code Plus — Security & Deployment Guide

For customer security and platform teams. Everything here is verifiable in
the shipped artifacts. *Applies to CocoIndex Code Plus **v0.1.8 and later**
(earlier releases predate some hardening described here: default audit-log
emission, MCP audit lines, disabled docs routes, and the litellm egress
pin).*

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

## Network egress — the complete list

| Destination | When | Content | Your control |
|---|---|---|---|
| Embedding provider (your account & API key; LiteLLM) | index + query time | code-chunk text; query text | Choose any provider — Azure OpenAI, or a self-hosted in-VPC endpoint for **zero egress** (default config is an OpenAI model) |
| `api.keygen.sh` (optional) | license validation (online mode only) | the license key string — nothing else | Use the **offline signed key** → no license egress at all |
| Your code hosts (GitHub/GitLab) | indexing | API reads with *your* read-only credentials | Your tokens, your scope |

Nothing else — including third-party libraries: the shipped images pin
litellm to its bundled model-cost data (`LITELLM_LOCAL_MODEL_COST_MAP=true`),
suppressing an import-time metadata fetch the library would otherwise make
(no customer data, but it would show up in an egress capture). If you build
your own images or run outside our containers, set that variable too.

**Fully air-gapped recipe:** mirror the images to your registry + offline
license key + in-VPC embedding endpoint.

## Deployment hardening checklist

- **Authentication:** bearer-token (`apiKey`) mode is the default and
  fail-closed — missing/invalid tokens get 401 on every route (REST and
  MCP). The only unauthenticated route is `/health` (status, version, and
  uptime for probes — no index data); the interactive docs and OpenAPI
  schema routes are disabled. The server accepts a *set* of tokens
  (`CCX_API_TOKEN`) for zero-downtime rotation. Never run
  `CCX_AUTH_MODE=none` outside local development (it warns loudly).
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
  egress to your Postgres, code hosts, the embedding endpoint — and
  `api.keygen.sh` if you use online license mode).

## Logging & audit

Both components log to stdout/stderr for your pipeline. The query server
emits HTTP access logs (auth failures visible as 401s) and a per-request
**audit record** on every served operation — REST and MCP. The exact
formats:

```
audit principal=<s> search query=<q> repo=<r> git_ref=<ref> results=<n>
audit principal=<s> grep repo=<r> git_ref=<ref> language=<l> pattern=<p> matches=<n>
audit principal=<s> read_file repo=<r> git_ref=<ref> path=<p> lines=<a>-<b>
audit principal=<s> find_files repo=<r> git_ref=<ref> patterns=<p> total=<n>
audit principal=<s> repositories repo=<r> refs=<n>
```

MCP tool calls emit the same lines with an `mcp <tool>` operation token.
Note that **query text appears in these logs** — apply your normal log
retention and access controls.

## Supply-chain verification

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

The product's only AI use today is **text-embedding inference** for semantic
code search. CocoIndex trains no models and **never trains on customer
data**. All model calls go exclusively to the endpoint *you* configure under
*your* key — including asynchronous indexing-time calls. Future inference
capabilities (e.g., code summarization, agentic query decomposition) are
governed by the same invariants: customer-keyed endpoints only, air-gap
compatible or disableable, data flows documented here **before** release.

## Vulnerability reporting & fixes

Report to **security@cocoindex.io** (canonical policy:
[SECURITY.md](../SECURITY.md);
also discoverable via <https://cocoindex.io/.well-known/security.txt>, RFC 9116) —
acknowledgment within 3 business days, coordinated disclosure preferred.
Critical vulnerabilities in shipped versions: assessed within 24 hours,
fixed or mitigated within 7 days, with affected customers notified via the
fix-release advisory. Dependencies are fully pinned and hash-verified; Dependabot and
secret scanning run on the product repositories.
