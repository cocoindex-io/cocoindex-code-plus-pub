# CocoIndex Code Plus — Security & Deployment Guide

For customer security and platform teams. Everything here is verifiable in
the shipped artifacts. *Applies to CocoIndex Code Plus **v0.1.8 and later**
(earlier releases predate some hardening described here: default audit-log
emission, MCP audit lines, disabled interactive-docs routes, and the litellm
egress pin).*

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
| `api.keygen.sh` (optional) | license validation (online mode only) | the license key string — nothing else | Use the **offline signed key** → no license egress at all |
| Your code hosts (GitHub/GitLab) | indexing — **and at query time under `codeHostMirrored`** (short-TTL cached) | repo content at index time; **identity and permission lookups only** at query time — never repo content | Your tokens, your scope |
| Your IdP / authorization server (under `auth.mode: oidc`) | query-server startup + cached refresh | **fetches only**: OIDC discovery + the JWKS public keys — no customer data is sent | It's your IdP; a self-managed one keeps this in-VPC (private CA via `auth.oidc.caBundleSecret`) |

Nothing else — including third-party libraries: the shipped images pin
litellm to its bundled model-cost data (`LITELLM_LOCAL_MODEL_COST_MAP=true`),
suppressing an import-time metadata fetch the library would otherwise make
(no customer data, but it would show up in an egress capture). If you build
your own images or run outside our containers, set that variable too.

**Fully air-gapped recipe:** mirror the images to your registry + offline
license key + in-VPC embedding endpoint.

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
audit principal=<s> list_git_refs repo=<r> refs=<n>
```

MCP tool calls emit the same lines with an `mcp <tool>` operation token.
Note that **query text appears in these logs** — apply your normal log
retention and access controls.

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
fixed or mitigated within 14 days, with affected customers notified via the
fix-release advisory. Dependencies are fully pinned and hash-verified; Dependabot runs on all
product repositories; GitHub secret scanning with push protection runs on
the public repositories, complemented by gitleaks pre-commit hooks and
quarterly full-history scans across all of them.
