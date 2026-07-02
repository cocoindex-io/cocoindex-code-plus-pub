# Deploying CocoIndex Code Plus (Helm)

Self-host the **backend** — the indexer and query server — on Kubernetes with the
`cocoindex-code-plus` Helm chart. This is the single guide for IT / platform teams
deploying the service; engineers who only *query* an existing deployment want
[cli.md](cli.md) instead.

## What gets deployed

- **Indexer** — a singleton worker that watches your repos and writes a vector
  index into Postgres. Needs a **CocoIndex Plus license** at runtime.
- **Query server** — a stateless FastAPI service (`/health`, `/code/v0/semantic_search`); scales
  horizontally; license-free.
- **Postgres + pgvector** — the index store. The chart can run a **bundled**
  Postgres for a quick test, or point at an **external** one (Cloud SQL, …) for
  production.

## Prerequisites

- A Kubernetes cluster + `kubectl` and `helm` (v3.8+ for OCI).
- **Access to the images** — pull `ghcr.io/cocoindex-io/ccx-{indexer,query-server}`
  (we issue a pull token), or [relocate them into your own registry](#air-gapped--relocate-images).
- A **CocoIndex Plus license key** (we issue it; gates the indexer).
- An **embedding-provider API key** — any
  [LiteLLM-supported model](https://docs.litellm.ai/docs/embedding/supported_embedding)
  (`OPENAI_API_KEY` for the default OpenAI model, or another provider's key).
- **Source access** to the repos you index — a **GitHub App** (App ID + PEM key)
  and/or a **GitLab token** — plus a **config repo** holding the per-repo index
  config JSON.
- For production: an **external Postgres with pgvector** (e.g. Cloud SQL — enable
  the `vector` extension).

## Quickstart (bundled Postgres, API-key auth)

Put your secrets in a gitignored `values-secret.yaml`:

```yaml
# values-secret.yaml — do not commit
embedding:
  model: text-embedding-3-small        # any LiteLLM model
  secretEnv: { OPENAI_API_KEY: sk-… }  # or COHERE_API_KEY / GEMINI_API_KEY / …
secrets:
  cocoindexPlus: { licenseKey: "<your-license-key>" }
  apiTokens:     { tokens: "<a-strong-token>" }   # the CLI sends one of these
  githubApp:     { privateKey: |
      -----BEGIN RSA PRIVATE KEY-----
      … }
indexer:
  configProvider: github               # or gitlab
  github: { appId: "123456" }
  config: { repoOwner: your-org, repoName: index-configs, gitRef: main, dir: configs }
```

Install and verify:

```bash
helm install ccx oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus \
  --version <X.Y.Z> -n ccx --create-namespace -f values-secret.yaml

helm test ccx -n ccx                                   # GET /health
kubectl -n ccx port-forward deploy/ccx-cocoindex-code-plus-query-server 8080:8080
# then, from a workstation (see cli.md):
CCX_SERVER_URL=http://127.0.0.1:8080 CCX_API_TOKEN=<a-strong-token> ccx search "rate limiter"
```

The install NOTES print the exact service name + port-forward command.

## Configuration

Set values inline (above) or via `--set`. The chart's `values.yaml` documents
every field (`helm show values oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus --version <X.Y.Z>`).
The **Req?** column says what you must supply: **yes** = no workable default,
provide it; **default** = sensible default, leave alone unless noted; **if prod** /
**if gitlab** = only for that path.

| Area | Keys | Req? | Notes |
|---|---|---|---|
| **License** | `secrets.cocoindexPlus.{licenseKey,existingSecret}` | **yes** | indexer runtime gate |
| **Embedding** | `embedding.secretEnv` / `existingSecret`, `embedding.model`, `embedding.env` | **yes** (credential) | `model` defaults to `text-embedding-3-small`; the provider key has no default |
| **API tokens** | `secrets.apiTokens.{tokens,existingSecret}` | **yes** (apiKey mode) | what the server accepts / the CLI sends; empty → rejects all |
| **Indexer source** | `indexer.config.*`, `indexer.github.appId` (+ `secrets.githubApp.privateKey`), `indexer.configProvider`, `indexer.gitlab.baseUrl` (+ `secrets.gitlab.token`) | **yes** | where configs + repos live; `configProvider` defaults to `github` |
| **Images** | `images.{indexer,queryServer}.{repository,tag,pullPolicy}`, `imagePullSecrets` | default | default to the published GHCR images at the chart version; override `repository` for a [mirror](#air-gapped--relocate-images) |
| **Auth** | `auth.mode` (`apiKey` / `none` dev) | default (`apiKey`) | never expose with `none` |
| **Database** | `database.bundled.enabled`, `database.{target,internal}.{url,existingSecret,schema}` | default (bundled) / **if prod** | bundled Postgres for test; external (Cloud SQL) for prod — see below |
| **Query server** | `queryServer.{replicaCount,service,ingress,autoscaling,resources}` | default | scaling + exposure; ingress off by default |
| **Refresh** | `indexer.refreshIntervalSeconds`, `indexer.repoRefreshIntervalSeconds` | default (300s) | poll cadences |

**Secrets: inline or existingSecret.** Every secret group accepts an
`existingSecret` (name a pre-created k8s Secret — e.g. from your secret manager via
External Secrets/CSI) instead of an inline value. Prefer that in production.

### Production Postgres (Cloud SQL / external)

Disable the bundled DB and point at your own (with `pgvector` enabled):

```yaml
database:
  bundled: { enabled: false }
  target:   { existingSecret: ccx-db }   # key CCX_TARGET_DB_URL (full URL incl. password)
  internal: { existingSecret: ccx-db }   # key CCX_INTERNAL_DB_URL
```

On GKE, reach Cloud SQL via the **Cloud SQL Auth Proxy** sidecar + Workload
Identity.

### Exposing the query server

The CLI, agents, and the **MCP** endpoint (`<host>/mcp` — see [cli.md](cli.md))
all reach the query server over HTTP on the same Service/port. For off-cluster
access enable an Ingress **with TLS** — and only with auth on (the chart defaults
`auth.mode: apiKey`):

```yaml
queryServer:
  ingress: { enabled: true, className: gce, host: ccx.example.com, tls: true, tlsSecretName: ccx-tls }
```

Until then, `kubectl port-forward` is the simplest path.

### GKE notes

- **Autopilot** requires CPU/memory **requests** on every container — set
  `queryServer.resources`, `indexer.resources`, `database.bundled.resources`.
- If an **org policy forbids external node IPs** (`compute.vmExternalIpAccess`),
  create the cluster with **private nodes** + a **Cloud NAT** for egress, and grant
  the node service account `roles/artifactregistry.reader` if pulling from
  Artifact Registry.

## Air-gapped / relocate images

The chart is registry-relocatable. Mirror the images into your registry and point
the chart at them:

```bash
for img in ccx-indexer ccx-query-server; do
  skopeo copy --all docker://ghcr.io/cocoindex-io/$img:<X.Y.Z> docker://<your-registry>/ccx/$img:<X.Y.Z>
done
helm pull oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus --version <X.Y.Z>
helm install ccx ./cocoindex-code-plus-<X.Y.Z>.tgz -n ccx --create-namespace \
  --set images.indexer.repository=<your-registry>/ccx/ccx-indexer \
  --set images.queryServer.repository=<your-registry>/ccx/ccx-query-server \
  -f values-secret.yaml
```

The **CocoIndex Plus license validates offline** — the license key is
signed/self-verifiable, so the indexer never calls home. Once the images are
mirrored and the key is in place, the deployment needs **no egress to us**. The
only remaining outbound dependency is your **embedding provider** (the
`OPENAI_API_KEY` / LiteLLM call); point it at a self-hosted / in-VPC model to run
fully air-gapped.

## Operate

```bash
helm upgrade ccx oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus --version <X.Y.Z> -n ccx -f values-secret.yaml
kubectl -n ccx logs deploy/ccx-cocoindex-code-plus-indexer -f   # watch indexing
helm uninstall ccx -n ccx
```

`/code/v0/semantic_search` returns **503** ("index not built yet") until the indexer has populated
the table, and **401** without a valid API token — both expected.
