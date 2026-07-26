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
- **Access to the images** — the private images `ghcr.io/cocoindex-io/ccx-{indexer,query-server}`
  (granted on request — typically a **pull token** we issue), or
  [relocate them into your own registry](#air-gapped--relocate-images). (The
  [Helm chart itself](https://github.com/orgs/cocoindex-io/packages/container/package/charts%2Fcocoindex-code-plus)
  is public.)
- A **CocoIndex Plus license key** (we issue it; gates the indexer).
- An **embedding-provider API key** — any
  [LiteLLM-supported model](https://docs.litellm.ai/docs/embedding/supported_embedding)
  (`OPENAI_API_KEY` for the default OpenAI model, or another provider's key).
- **Source access** to the repos you index. Every code-host **instance** you
  index from — github.com, a GitHub Enterprise Server, gitlab.com, a
  self-managed GitLab — is one entry in the chart's **`codeHosts`** map,
  carrying the instance's `baseUrl`, its indexer credential as a **reference
  to a Secret you create**, and that instance's **config repo**
  ([format](#index-config-repo)) listing the repos to index there. A GitHub
  instance authenticates with a **GitHub App** — needs **Repository →
  Contents: Read-only** (Metadata: Read is automatic), must be **installed on
  the config repo and every repo you index** — via its **App ID** + a Secret
  holding the **PEM private key**. A GitLab instance authenticates with a
  **token** (**read access**: `read_api` / `read_repository` on the same
  repos) held in a Secret. One deployment can span several instances at once.
- For production: an **external Postgres with pgvector** (e.g. Cloud SQL — enable
  the `vector` extension).

**Getting access.** Your CocoIndex representative provides the **CocoIndex Plus
license key** and **image pull access** — a revocable **pull token** plus the
username to pair it with (GitHub-account read grants are possible case-by-case) —
contact them to get set up. The Helm **chart is public**:
released `<X.Y.Z>` versions are listed on its
[GHCR package page](https://github.com/orgs/cocoindex-io/packages/container/package/charts%2Fcocoindex-code-plus),
and `helm show values …` works with no login. Only the images are gated.

## Quickstart (bundled Postgres, API-key auth)

**First, create your [index config repo](#index-config-repo)** and point your
`codeHosts` entry's `configRepo` at it (below) — the indexer polls it on
startup and indexes nothing until it lists repos.

Put your values in a gitignored `values-secret.yaml`:

```yaml
# values-secret.yaml — do not commit
imagePullSecrets: [{ name: ghcr-pull }]  # references the pull secret created below
embedding:
  model: text-embedding-3-small        # any LiteLLM model — pin one deliberately (see note below)
  secretEnv: { OPENAI_API_KEY: sk-REPLACE_ME }  # or COHERE_API_KEY / GEMINI_API_KEY / …
secrets:
  cocoindexPlus: { licenseKey: "<your-license-key>" }
  apiTokens:     { tokens: "<a-strong-token>" }   # a string, not a list — may pack several tokens (space/comma/newline-separated); the CLI sends one
codeHosts:
  github.com:                          # one entry per code-host instance; the map key is the instance's identity
    provider: github
    baseUrl: https://github.com        # for GHES / self-managed GitLab: the instance root, e.g. https://github.example.com
    indexer:
      appId: "123456"
      privateKeySecret: { name: ccx-github-app }   # Secret created below; key defaults to private-key.pem
    configRepo: { owner: your-org, name: index-configs, gitRef: main, dir: configs }
```

Code-host credentials are **never inlined in values** — each `codeHosts` entry
*references* a Secret you create (a GitLab entry uses
`indexer: { tokenSecret: { name: … } }` instead of an App; a private-CA
instance adds `caBundleSecret`). The Helm **chart is public** — no login to
install it. The **images are private**, so the cluster needs a pull secret
built from the pull token (and its paired username) your rep issues:

```bash
# Namespace + a docker-registry secret so the cluster can pull the images
# (referenced by imagePullSecrets in values-secret.yaml above):
kubectl create namespace ccx
kubectl -n ccx create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<username-we-provide> --docker-password=<pull-token>
# The GitHub App's private key, referenced by codeHosts.github.com above:
kubectl -n ccx create secret generic ccx-github-app \
  --from-file=private-key.pem=/path/to/github-app.private-key.pem
```

Install and verify:

```bash
helm install ccx oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus \
  --version <X.Y.Z> -n ccx -f values-secret.yaml

helm test ccx -n ccx                                   # GET /health
kubectl -n ccx port-forward svc/ccx-cocoindex-code-plus-query-server 8080:8080
# then, from a workstation (see cli.md):
CCX_SERVER_URL=http://127.0.0.1:8080 CCX_API_TOKEN=<a-strong-token> ccx search "rate limiter"
```

The install NOTES print the exact service name + port-forward command.

## Index config repo

Which repos to index isn't a chart setting — it lives in **config repos** you
own, one per code-host instance: each `codeHosts` entry names its own
(`configRepo: { owner, name, gitRef, dir }`; set in
[Chart configuration](#chart-configuration)), and that repo lists the repos to
index **from that instance** — so the people who govern an instance's config
repo control exactly what gets indexed from it. The indexer reads **every
`*.json` file** under `dir` (at `gitRef`) of each config repo, concatenates
them, and re-polls on `indexer.repoRefreshIntervalSeconds` — so you add or
drop repos by committing to the config repo, no redeploy.

Each file is a **JSON array** of repo entries:

```jsonc
// configs/acme.json — add as many *.json files as you like; they're merged
[
  {
    "repo_owner": "acme",
    "repo_name": "backend",
    "branches": "main",                  // regex over branch names (whole-name match)
    "included_patterns": ["**/*.py", "**/*.md"],
    "excluded_patterns": ["**/tests/**"]
  },
  {
    "repo_owner": "acme",
    "repo_name": "frontend",
    "branches": "main|release/.*",        // main + every release/* branch
    "tags": "v\\d+\\.\\d+"                 // and every vN.N tag
  },
  {
    "repo_owner": "group/subgroup",       // GitLab subgroup namespace is preserved
    "repo_name": "service",               // (in a GitLab instance's config repo)
    "branches": "main"
  },
  {
    "repo_owner": "acme",
    "repo_name": "legacy",
    "branches": "main",
    "to_delete": true                     // drops this repo's rows from the index
  }
]
```

| Field | Req? | Meaning |
|---|---|---|
| `repo_owner` | **yes** | org / user (GitLab: full subgroup namespace, `/` kept) |
| `repo_name` | **yes** | repository name |
| `branches` / `tags` | **one required** | **regex** ([`re.fullmatch`](https://docs.python.org/3/library/re.html#re.fullmatch)) selecting refs to index — a plain `"main"` matches exactly that ref; the repo is indexed at every matched ref |
| `included_patterns` / `excluded_patterns` | default: all files | file globs (e.g. `**/*.py`) to include / exclude |
| `to_delete` | default `false` | `true` removes the repo's rows on the next poll |

An entry's **provider and instance come from the config repo that declares
it** — the `codeHosts` entry the repo belongs to — so entries carry neither
(an entry setting `provider` or `instance` is rejected). A bad regex or an
entry missing both `branches` and `tags` fails the config parse with a clear
error (nothing is indexed) rather than failing mid-index.

## Chart configuration

These are the **Helm chart** values (which repos to index lives separately, in the
[index config repo](#index-config-repo) above). Set them inline (above) or via
`--set`; the chart's `values.yaml` documents every field
(`helm show values oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus --version <X.Y.Z>`).
The **Req?** column says what you must supply: **yes** = no workable default,
provide it; **default** = sensible default, leave alone unless noted;
**if prod** / **optional** = only for that path.

| Area | Keys | Req? | Notes |
|---|---|---|---|
| **License** | `secrets.cocoindexPlus.{licenseKey,existingSecret}` | **yes** | runtime license for the indexer **and** the query server (its structural `grep` needs it; other query surfaces run license-free) |
| **Embedding** | `embedding.secretEnv` / `existingSecret`, `embedding.model`, `embedding.env` | **yes** (credential) | `model` defaults to `text-embedding-3-small`; the provider key has no default. **Pin the model version and keep it fixed:** query vectors are only comparable to index vectors from the same model, so changing `embedding.model` (or pointing at an endpoint that swaps models underneath) requires a full reindex — treat a model change as a deliberate operation: update the value, then rebuild the index |
| **API tokens** | `secrets.apiTokens.{tokens,existingSecret}` | **yes** (apiKey mode) | what the server accepts / the CLI sends; empty → rejects all |
| **Code hosts** | `codeHosts.<instance>.{provider,baseUrl,indexer,configRepo,caBundleSecret,rateLimit}` | **yes** | one entry per code-host instance (github.com, GHES, gitlab.com, self-managed GitLab — a deployment can span several). `indexer` holds the credential as a **Secret reference** (`appId` + `privateKeySecret` for GitHub; `tokenSecret` for GitLab); `configRepo` names that instance's [index config repo](#index-config-repo); `caBundleSecret` supplies a private/corporate CA (PEM); `rateLimit` overrides the per-instance API budget. The **map key is the instance's frozen identity** — part of every repo's index identity, so renaming it means a full reindex; `baseUrl` is the mutable connection address |
| **Local config lane** | `localConfig.{checkout,gitRef,dir}` + `indexer.{extraVolumes,extraVolumeMounts}` | optional | config for locally-mounted (`local_path`) repos, read from an operator-mounted checkout; omit unless you index local checkouts |
| **Images** | `images.{indexer,queryServer}.{repository,tag,pullPolicy}`, `imagePullSecrets` | default | default to the published GHCR images at the chart version; override `repository` for a [mirror](#air-gapped--relocate-images) |
| **Auth** | `auth.mode` (`apiKey` / `none` dev) | default (`apiKey`) | never expose with `none` |
| **Database** | `database.bundled.enabled`, `database.{target,internal}.{url,existingSecret,schema}` | default (bundled) / **if prod** | bundled Postgres for test; external (Cloud SQL) for prod — see below |
| **DB memory** | `database.bundled.{sharedBuffers,effectiveCacheSize,shmSize}` | default (1GB / 2GB / 256Mi) | size `sharedBuffers` ≈ your vector-index set so searches stay in memory — see [Postgres memory sizing](#postgres-memory-sizing) |
| **Query server** | `queryServer.{replicaCount,service,ingress,publicUrl,mcpExtraAllowedOrigins,autoscaling,resources}` | default | scaling + exposure (ingress off by default); `publicUrl` = the deployment's public origin — see [Exposing the query server](#exposing-the-query-server) for the `/mcp` Origin rules |
| **Refresh** | `indexer.refreshIntervalSeconds`, `indexer.repoRefreshIntervalSeconds` | default (300s) | poll cadences |
| **Timeouts & load** | `queryServer.{requestDeadlineSeconds,maxConcurrentRequests}`, `queryServer.ingress.timeoutSeconds` | default (60 / 64 / 75) | the server's per-request deadline and admission cap, and the ingress budget — see [Timeout chain](#timeout-chain) |

**Secrets: inline or existingSecret.** Every secret group accepts an
`existingSecret` (name a pre-created k8s Secret — e.g. from your secret manager via
External Secrets/CSI) instead of an inline value. Prefer that in production.

### Production Postgres (Cloud SQL / external)

Disable the bundled DB and point at your own (with `pgvector` enabled). There are
two logical DBs: **target** holds the vector index; **internal** holds CocoIndex's
own bookkeeping state. They can share one Postgres instance via separate schemas
(`ccx` / `ccx_internal`) — but the single `ccx-db` secret must then hold **both**
keys (`CCX_TARGET_DB_URL` **and** `CCX_INTERNAL_DB_URL`):

```yaml
database:
  bundled: { enabled: false }
  target:   { existingSecret: ccx-db }   # key CCX_TARGET_DB_URL (full URL incl. password)
  internal: { existingSecret: ccx-db }   # key CCX_INTERNAL_DB_URL
```

**Give the query server a read-only role** (recommended for production): the
indexer needs the writer credential, but the query server only reads. Create a
role such as

```sql
CREATE ROLE ccx_query LOGIN PASSWORD '…';
GRANT pg_read_all_data TO ccx_query;   -- covers current and future tables
```

and point `database.target.queryUrl` (or `queryExistingSecret`, key
`CCX_TARGET_DB_URL`) at its DSN. The **bundled** Postgres sets this split up
automatically on first init. Left unconfigured on an external DB, the query
server falls back to the writer credential. Also run
`CREATE EXTENSION pg_prewarm;` at provisioning (see
[Postgres memory sizing](#postgres-memory-sizing)).

On GKE, reach Cloud SQL via the **Cloud SQL Auth Proxy** sidecar + Workload
Identity.

### Postgres memory sizing

Semantic search is memory-bound: each indexed repo's vector (HNSW) index must be
resident in Postgres's buffer cache, or a cold search reads hundreds of MB from
disk and the first query after a restart or idle period can take tens of
seconds. Rules of thumb:

- **Bundled Postgres:** set `database.bundled.sharedBuffers` (default `1GB`) to
  roughly the total size of your vector indexes — budget **~2.5 KB per indexed
  chunk** (e.g. a 170k-chunk repo ≈ 450 MB), and `effectiveCacheSize` (default
  `2GB`) to roughly the pod's memory. `sharedBuffers` + `shmSize` count against
  the pod, so set `database.bundled.resources` accordingly.
- **External / Cloud SQL:** set the `shared_buffers` / `effective_cache_size`
  flags on the instance with the same sizing.
- The query server also **pre-warms** every vector index into the database
  cache at startup (best-effort), so a freshly started server doesn't serve a
  slow first search. It needs the **`pg_prewarm` extension provisioned at DB
  setup** — the bundled Postgres does this on first init; on an external
  database run `CREATE EXTENSION pg_prewarm;` once as the provisioning user
  (the query server itself never runs DDL, and just skips prewarm with a log
  hint when the extension is absent).

### Exposing the query server

The CLI, agents, and the **MCP** endpoint (`<host>/mcp` — see [cli.md](cli.md))
all reach the query server over HTTP on the same Service/port. For off-cluster
access enable an Ingress **with TLS** — and only with auth on (the chart defaults
`auth.mode: apiKey`):

```yaml
queryServer:
  ingress: { enabled: true, className: gce, host: ccx.example.com, tls: true, tlsSecretName: ccx-tls }
```

The query server serves **plain HTTP** — TLS is terminated at the Ingress.
`tlsSecretName` must name a TLS secret **you pre-create** (the chart references but
doesn't create it); on GKE you can instead attach a managed certificate via the
Ingress annotations. Until then, `kubectl port-forward` is the simplest path.

**Browser-based MCP clients.** `/mcp` validates the `Origin` header (required
by the MCP transport spec): a request carrying an `Origin` that isn't
allowlisted is refused with `403`. Set `queryServer.publicUrl` to the
deployment's public URL (`https://ccx.example.com` — origin only, no path); a
web app on another origin that embeds an MCP client needs its origin added to
`queryServer.mcpExtraAllowedOrigins`. Non-browser clients — the `ccx` CLI and
coding agents — send no `Origin` header and are unaffected.

### Timeout chain

The server enforces a per-request deadline (`queryServer.requestDeadlineSeconds`,
default **60 s**): an over-deadline request is cancelled and answered with a
clear `503` (or, mid-tool on `/mcp`, a `deadline_exceeded` tool error). For that
answer to reach the caller, each outer layer must time out *later* than the one
inside it:

**client (90) > ingress (75) > server deadline (60 + a ≤5 s grace)**

- The chart's defaults implement this: `queryServer.ingress.timeoutSeconds: 75`
  and the CLI's 90 s default. **If you raise `requestDeadlineSeconds`, raise
  the outer two as well** — nothing auto-derives them.
- The **ingress budget is controller-specific** and the chart emits the right
  form for the classes it knows: `gce`/`gce-internal` get a `BackendConfig`
  with `timeoutSec` attached via the Service (GKE's default backend timeout is
  30 s — *below* the server deadline, so leaving it unset cuts long requests
  off first); `nginx` gets the `proxy-read/send-timeout` annotations. Any other
  controller: set its equivalent yourself via `queryServer.ingress.annotations`.
- The server also caps concurrency (`queryServer.maxConcurrentRequests`,
  default **64** per pod): past capacity, requests get an immediate `503`
  (retryable) while `/health` stays green — scale `replicaCount` if you see
  sustained capacity 503s.

### GKE notes

- **Autopilot** requires CPU/memory **requests** on every container — set
  `queryServer.resources`, `indexer.resources`, `database.bundled.resources`.
  Starter values (see `values-gcp.yaml`): query server `requests {cpu: 250m,
  memory: 512Mi}` / `limits {cpu: 1, memory: 1Gi}`; indexer `requests {cpu: 250m,
  memory: 512Mi}` / `limits {cpu: 1, memory: 2Gi}` (embedding + chunking is the
  heavier path). Size Postgres to your corpus.
- If an **org policy forbids external node IPs** (`compute.vmExternalIpAccess`),
  create the cluster with **private nodes** + a **Cloud NAT** for egress, and grant
  the node service account `roles/artifactregistry.reader` if pulling from
  Artifact Registry.

### EKS / AWS notes

The friendliest path on EKS pulls images from **your own ECR via IAM** — no
in-cluster pull secret at all:

1. **Mirror** the two images into ECR (see [Air-gapped / relocate images](#air-gapped--relocate-images))
   and set `images.{indexer,queryServer}.repository` to the ECR repo URIs.
2. **Grant the pull role** — attach `AmazonEC2ContainerRegistryReadOnly` to the
   node group role (or a pod role via **IRSA**), then **omit `imagePullSecrets`**.
   Add an **ECR VPC endpoint** to keep image pulls in-VPC.

- **Database:** RDS / Aurora **PostgreSQL** with the `pgvector` extension enabled;
  point `database.target`/`internal` at it via `existingSecret`.
- **Secrets:** AWS **Secrets Manager** → k8s Secrets (External Secrets Operator or
  the Secrets Store CSI driver) → the chart's `existingSecret` fields.
- **Ingress/TLS:** the **AWS Load Balancer Controller** (`queryServer.ingress.className: alb`)
  with an **ACM** certificate via `queryServer.ingress.annotations`
  (`alb.ingress.kubernetes.io/certificate-arn`); TLS terminates at the ALB.
- **Node arch:** releases **after 0.1.12** are **multi-arch**
  (`linux/amd64` + `linux/arm64`) — Graviton (or any arm64) nodes work; the
  kubelet pulls the matching arch automatically. Releases **0.1.12 and earlier**
  are amd64-only: schedule those on **x86_64** nodes.

## Air-gapped / relocate images

The chart is registry-relocatable. Mirror the images into your registry and point
the chart at them:

```bash
VERSION=<X.Y.Z>                        # re-run the image copy for each version you adopt
for img in ccx-indexer ccx-query-server; do
  skopeo copy --all docker://ghcr.io/cocoindex-io/$img:$VERSION docker://<your-registry>/ccx/$img:$VERSION
done
helm pull oci://ghcr.io/cocoindex-io/charts/cocoindex-code-plus --version $VERSION
helm install ccx ./cocoindex-code-plus-$VERSION.tgz -n ccx --create-namespace \
  --set images.indexer.repository=<your-registry>/ccx/ccx-indexer \
  --set images.queryServer.repository=<your-registry>/ccx/ccx-query-server \
  -f values-secret.yaml
```

Run these from a **connected host**. `skopeo copy` needs image pull access (your
pull token); the **chart is public**, so `helm pull` needs no auth. `--all`
copies every architecture **plus the SBOM/provenance attestation manifests** —
the `unknown/unknown` entries you'll see next to `linux/amd64` / `linux/arm64`
on package pages are those attestations (build metadata, never selected by a
runtime), not broken images. `helm pull` fetches the chart `.tgz` — carry that to the disconnected side
(or re-host it in your own OCI registry) so the install never reaches GHCR. The
image copy is **per version**: only versions you actually upgrade to need
mirroring — re-run the copy (and `helm upgrade`) each time you move to a new one.

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
the table, and **401** without a valid API token — both expected. The indexer runs
**continuously** (live mode): there's no "done" log line — it's ready once the
`503` clears (or `ccx search` returns hits). `helm upgrade` briefly restarts the
**singleton** indexer (`Recreate` — indexing pauses for the restart while the
query server keeps serving), so pin `<X.Y.Z>` deliberately.

**Rotating the API token.** `secrets.apiTokens.tokens` is a single string (not
a YAML list) that can hold multiple tokens, whitespace/comma/newline-separated. To rotate without downtime: add the new
token, `helm upgrade`, migrate clients, then drop the old token and upgrade again.
