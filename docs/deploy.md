# Deploying CocoIndex Code Plus (Helm)

Self-host the **backend** — the indexer and query server — on Kubernetes with the
`cocoindex-code-plus` Helm chart. This is the single guide for IT / platform teams
deploying the service; engineers who only *query* an existing deployment want
[cli.md](cli.md) instead.

## What gets deployed

- **Indexer** — a singleton worker that watches your repos and writes a vector
  index **and a symbol graph** (symbol definitions/references — see
  [Symbol index](#symbol-index) below) into Postgres.
- **Query server** — a stateless FastAPI service; scales horizontally. It serves
  semantic search, AST grep, symbol definitions/references, file reads, repo
  metadata, an optional [agentic query](#agentic-query) endpoint, and an **MCP**
  endpoint for coding agents (the full surface is in [cli.md](cli.md)).

**Both workloads need a CocoIndex Plus license** at runtime — the query server's
`grep` needs it too, not just the indexer.
- **Postgres + pgvector** — the index store. The chart can run a **bundled**
  Postgres for a quick test, or point at an **external** one (Cloud SQL, …) for
  production.

## Access: authentication & authorization

The **query server** is the only surface your engineers, CI jobs, and AI agents
talk to, and it answers two independent questions on every request:

- **Authentication — who is calling?** Set by `auth.mode`. In either real mode a
  missing or invalid credential is a `401` on every route returning code or index
  data, REST and MCP alike; only the dev-only `none` serves anonymous callers.
- **Authorization — what may they see?** Set by `authz.mode`. The default grants
  every authenticated caller the whole index; the alternative mirrors each
  person's real code-host permissions.

Separate knobs, with a coupling worth knowing up front: mirrored authorization
needs real per-person identities, so it requires `oidc`.

**Which credential, for whom.** Callers authenticate with one of three things: a
**shared API token** (one string you invent; every caller presents it), an **API
key record** (a `ccxk_<id>_<secret>` key — labelled, individually revocable,
scoped), or **SSO through your company IdP** (`ccx login`). You never weigh all
three at once — two facts decide it. CI jobs and headless agents cannot sign in
interactively, so they carry one of the two static kinds (an MCP client that
supports OAuth can instead sign in through the human driving it —
[cli.md](cli.md)). And a shared secret is fine while you evaluate, but has a
ceiling once a real team depends on the deployment. Find your row in the
decision table:

| Your deployment | Humans | CI & agents | What you set |
|---|---|---|---|
| **Evaluating, or a small trusted team** (the default) | shared token | the same shared token | `secrets.apiTokens` — the [quickstart](#quickstart-bundled-postgres-api-key-auth) does exactly this |
| **Attributable keys, no IdP yet** | a key record each | a key record each | `auth.apiKeys`, `secrets.apiTokens` empty — [minting](#minting-a-key-record) |
| **Production, on your company IdP** | `ccx login` | key records | `auth.mode: oidc` + `auth.oidc` + `queryServer.publicUrl`, plus records — [setup](#sso-login-oidc--api-key-records) |
| **… plus per-person repo permissions** | `ccx login` | key records (own scope) | add `authz.mode: codeHostMirrored` + attestations + a permission-check credential — [setup](#code-host-mirrored-authorization) |

**Why two static kinds?** The shared token is the getting-started credential,
and its simplicity is exactly its ceiling: the server resolves every shared
token — even distinct strings in the rotation set — to one identity, so the
audit log cannot tell callers apart, they all share one rate-limit bucket
(limits run with defaults on every deployment), and unless you hand-allocate a
string per caller and track who holds which, revoking one caller means rotating
all of them. Key records lift those limits — each is labelled (the audit log
shows its id), individually revocable (delete the record), and rate-limited per
key — and each additionally carries its own repo scope and sits in your values
as a `sha256:` hash rather than the secret. Humans get the same per-person
properties from SSO instead — plus offboarding that happens in your IdP — so a
production deployment uses records only for machines; the no-IdP row presses
them into per-person duty as a stopgap until SSO. The chart never mixes the two
static kinds: configure anything beyond the plain shared token and a non-empty
`secrets.apiTokens` becomes a rendering error (the lane rule below has the
exact trigger list).

**Authentication reference — `auth.mode`**

| Mode | What callers present | Notes |
|---|---|---|
| `apiKey` **(default)** | the shared token, **or** key records — never both | the server accepts a **set** of shared tokens, so rotation needs no downtime — procedure and one `existingSecret` caveat in [Operate](#operate) |
| `oidc` | a JWT from your IdP via `ccx login`; key records auto-enable alongside for machines (no extra switch) | needs an IdP that mints **JWT access tokens for a dedicated audience** — Entra ID, Keycloak, Auth0, Ping do; **Okta only with the API Access Management add-on**. **Google Workspace, Okta without that add-on, and SAML-only IdPs do not**, and need [an authorization server in front](#bring-your-own-authorization-server-google-workspace-okta-without-api-access-management-saml-only-idps). Setup: [SSO login (OIDC)](#sso-login-oidc--api-key-records) |
| `none` | nothing | local development only; warns loudly, never expose it |

**Authorization reference — `authz.mode`**

| Mode | What a caller sees |
|---|---|
| `indexScope` **(default)** | everything indexed. Your [index config repo](#index-config-repo) is the access-control authority — committing a repo to it *is* the access decision, so gate that repo accordingly |
| `codeHostMirrored` | only the repos that person can read on the code host; anything else is indistinguishable from a repo that does not exist. Requires `auth.mode: oidc` — see [Code-host-mirrored authorization](#code-host-mirrored-authorization) |

API-key records are deliberately never mirrored — a key has no code-host
identity — so each record's own `scope` governs it, and CI keeps working.

**The lane rule.** Two config lanes, never blended — which one you're on decides
how you supply caller credentials:

- **The env lane** — `auth.mode` alone (`apiKey` or `none`) plus the bare
  `secrets.apiTokens`. The default, and what the quickstart below uses.
- **The file lane** — set anything richer (`mode: oidc`, an `auth.oidc` block,
  any `auth.apiKeys` record, or any value under the **top-level** `authz:` /
  `audit:` / `rateLimit:` blocks) and the chart renders the *whole* auth policy
  into one mounted config file. There, **`secrets.apiTokens` must be empty** —
  rendering fails otherwise — and `auth.apiKeys` records replace it. (The
  per-instance `codeHosts.<instance>.rateLimit` is an unrelated setting, a
  code-host API budget, and does **not** switch lanes.)

The shared API token is therefore the **default, not a requirement** — every
decision-table shape except the shared-token row runs without one.

**Unauthenticated routes** (`GET`/`HEAD` only, none returning index data), if
you're writing a WAF rule or an allowlist: `/health`, `/openapi.json` (rationale
in [Verify the install](#verify-the-install)), and — under `oidc` only —
`/.well-known/oauth-protected-resource/mcp`, the discovery document an MCP client
reads *before* it has a credential. Swagger/ReDoc are not served at all.

## Prerequisites

- A Kubernetes cluster + `kubectl` and `helm` (v3.8+ for OCI).
- **Access to the images** — the private images `ghcr.io/cocoindex-io/ccx-{indexer,query-server}`
  (granted on request — typically a **pull token** we issue), or
  [relocate them into your own registry](#air-gapped--relocate-images). (The
  [Helm chart itself](https://github.com/orgs/cocoindex-io/packages/container/package/charts%2Fcocoindex-code-plus)
  is public.)
- A **CocoIndex Plus license key** (we issue it; **both** workloads need it — the
  query server's `grep` does too, though it only checks on the first `grep`
  call, not at boot). It is a long string beginning `key/`, validated against
  `api.keygen.sh` — so the cluster needs outbound HTTPS to that host, or an
  [offline-entitled license](#license-key) if it has no internet access.
- An **embedding-provider API key** — any
  [LiteLLM-supported model](https://docs.litellm.ai/docs/embedding/supported_embedding)
  (`OPENAI_API_KEY` for the default OpenAI model, or another provider's key).
- **A credential for callers to present to the query server.** In the chart's
  default `apiKey` mode that is an **API token you invent** — unlike the license
  and pull token above, we don't issue this one. An SSO deployment drops the
  shared token and authenticates people through your IdP instead (machines still
  carry a key record); key records can also stand alone, with no IdP. Which one
  you want changes what else you need, so decide before writing values:
  [Access](#access-authentication--authorization).
- **Source access** to the repos you index. Every code-host **instance** you
  index from — github.com, a GitHub Enterprise Server, gitlab.com, a
  self-managed GitLab — is one entry in the chart's **`codeHosts`** map,
  carrying the instance's `baseUrl`, its indexer credential as a **reference
  to a Secret you create**, and that instance's **config repo**
  ([format](#index-config-repo)) listing the repos to index there. A GitHub
  instance authenticates with a **GitHub App** — needs **Repository →
  Contents: Read-only** (Metadata: Read is automatic), must be **installed on
  the config repo and every repo you index** — via its **App ID** + a Secret
  holding the **PEM private key**. Two things that regularly trip people up:
  **creating an App does not install it** — installation is a separate step
  (App settings → *Install App*), and a created-but-uninstalled App looks
  complete on its settings page while the indexer gets 404s on every repo;
  and the install scope matters — **All repositories** means adding a repo
  later is just a config-repo commit, while **Only select repositories**
  additionally requires granting each new repo to the installation. A GitLab instance authenticates with a
  **token** (**read access**: `read_api` / `read_repository` on the same
  repos) held in a Secret. One deployment can span several instances at once.
- For production: an **external Postgres with pgvector** (e.g. Cloud SQL — enable
  the `vector` extension).

**Getting access.** Your CocoIndex representative provides the **CocoIndex Plus
license key** and **image pull access** — a revocable **pull token**
(GitHub-account read grants are possible case-by-case) — contact them to get
set up. The pull token is the whole credential: registry auth is HTTP Basic, so
a username field must be *present*, but GHCR identifies you by the token alone —
pair it with any non-empty username (convention: `ccx-pull`). The Helm **chart is public**:
released `<X.Y.Z>` versions are listed on its
[GHCR package page](https://github.com/orgs/cocoindex-io/packages/container/package/charts%2Fcocoindex-code-plus),
and `helm show values …` works with no login. Only the images are gated.

**Credentials at a glance** — every secret this deployment can require, and which
component holds it. The bottom four apply only if you enable that feature.

| Credential | Comes from | Held by → presented to | Enables |
|---|---|---|---|
| **CocoIndex Plus license key** | **we issue it** | indexer + query server → `api.keygen.sh` | running the software |
| **Image pull token** | **we issue it** | your cluster → GHCR | pulling the private images |
| **API token** | **you invent it** | CLI / CI / agents → query server | every query — see [Access](#access-authentication--authorization) |
| **API key record** `ccxk_<id>_<secret>` | you mint it; values keep only the hash | CI / agents (every caller, when no IdP) → query server | same, but attributable and revocable |
| **Embedding-provider key** | your model provider | indexer + query server → the provider | computing embeddings |
| **Code-host credential** — GitHub App id + PEM, or GitLab token | you create it at your code host | indexer → code host | reading the repos you index |
| **Postgres URLs** (passwords inline) — a writer and an internal DSN, plus an optional read-only one for the query server | you | both workloads → your database | the index store |
| *(agentic query)* **Completion-model key** | your model provider | **query server only** → the provider | `ccx query` |
| *(`oidc`)* **IdP registrations** — an API/resource id and a public CLI client id | your IdP admin | `ccx login` → your IdP → query server | engineers signing in |
| *(`codeHostMirrored`)* **Permission-check credential** | you create it at your code host | **query server** → code host | checking each caller's repo access |
| *(`codeHostMirrored`, some topologies)* **Identity-mapping credential** — an enterprise PAT, or a GitLab admin token | you create it at your code host | **query server** → code host | joining an IdP identity to a code-host account |

Two that are genuinely easy to conflate:

- The **license key is issued to you** and validated against our service; the
  **API token is one you make up**, checked only by your own query server. Neither
  is the **pull token**, which your cluster uses solely to fetch images.
- The **indexer's** code-host credential reads repo *content*. The **query
  server's** permission-check credential — mirrored mode only — reads only
  *permissions*. By default they are the same GitHub App; see
  [Code-host-mirrored authorization](#code-host-mirrored-authorization) for when
  to split them.

**How credentials are referenced.** Anything the chart never inlines is named as
`{ name, key }`, where `key` defaults to `private-key.pem` for App private keys,
`token` for tokens and PATs, `ca.crt` for CA bundles, and `hmac-key` for the
audit HMAC key. Every inline secret
group also accepts an `existingSecret` instead (see
[Chart configuration](#chart-configuration)); inside those, the data keys are
`COCOINDEX_PLUS_LICENSE_KEY` for the license and `CCX_API_TOKEN` for the API
tokens.

## Quickstart (bundled Postgres, API-key auth)

**First, create your [index config repo](#index-config-repo)** and point your
`codeHosts` entry's `configRepo` at it (below) — the indexer polls it on
startup and indexes nothing until it lists repos.

This path takes the chart's default access model, `apiKey` + `indexScope`
([Access](#access-authentication--authorization)): `secrets.apiTokens` below is a
shared bearer token **you invent here**, your engineers put it in `CCX_API_TOKEN`
([cli.md](cli.md)), and anyone holding it can search **everything you index**.
For company-IdP sign-in instead, read
[SSO login (OIDC)](#sso-login-oidc--api-key-records) before writing values.

Put your values in a gitignored `values-secret.yaml`:

```yaml
# values-secret.yaml — do not commit
imagePullSecrets: [{ name: ghcr-pull }]  # references the pull secret created below
embedding:
  model: text-embedding-3-small        # any LiteLLM model — pin one deliberately (see note below)
  secretEnv: { OPENAI_API_KEY: sk-REPLACE_ME }  # or COHERE_API_KEY / GEMINI_API_KEY / …
secrets:
  # Every placeholder in this block MUST be substituted — the embedding key
  # above included. The chart refuses to render while any of them still looks
  # like one. These two are opposites: the license key is the long `key/…`
  # string your rep ISSUED you; the API token is a strong secret you MAKE UP.
  cocoindexPlus: { licenseKey: "<your-license-key>" }
  # The bearer token every caller sends to the query server. A string, not a
  # list — it may pack several tokens (space/comma/newline-separated) so you can
  # rotate; a caller sends one of them. Generate one, don't hand-pick it:
  #   python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
  apiTokens:     { tokens: "<a-strong-token>" }
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
  --docker-server=ghcr.io --docker-username=ccx-pull --docker-password=<pull-token>
  # any non-empty username works — GHCR identifies you by the token
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
own. The default layout is one per code-host instance: each `codeHosts` entry
names its own (`configRepo: { owner, name, gitRef, dir }`; set in
[Chart configuration](#chart-configuration)), and that repo lists the repos to
index **from that instance** — so the people who govern an instance's config
repo control exactly what gets indexed from it. (Prefer one repo for
everything? See [Central config repo](#central-config-repo) below.) The
indexer reads **every
config file** — `*.yaml`, `*.yml`, `*.json` — under `dir` (at `gitRef`) of each
config repo, **recursively**, concatenates them, and re-polls on
`indexer.repoRefreshIntervalSeconds` — so you add or drop repos by committing
to the config repo, no redeploy.

**Where to put the files — `configRepo.dir` is optional and defaults to the
repo root.** Two supported layouts:

- **A dedicated config repo** — leave `dir` unset and put the config files at
  the root.
- **A subfolder of a repo that has other content** — set `dir` (e.g.
  `dir: ccx-config`), which scopes the scan to that subtree.

Pick deliberately, because the scan takes **every** file with one of those
extensions under `dir`: at the root of a repo that also holds tooling files,
something like `.pre-commit-config.yaml`, `docker-compose.yml`,
`.github/workflows/ci.yml`, or `package.json` would be parsed as index config.
A file that doesn't parse makes the config refresh **fail closed** — the
indexer keeps the previously configured repo set and logs the error rather
than indexing a wrong set (one bad file pauses config changes for **all**
config repos until it's fixed; indexing of already-configured repos
continues) — so the symptom is "my config edits stopped taking effect", not
an outage or data loss. Use `dir` whenever the repo isn't dedicated.

Each file is a **list** of repo entries, written in YAML:

```yaml
# configs/acme.yaml — add as many config files as you like; they're merged
- repo_owner: acme
  repo_name: backend
  branches: main # regex over branch names (whole-name match)
  included_patterns: ["**/*.py", "**/*.md"]
  excluded_patterns: ["**/tests/**"]
  max_file_size: 262144 # bytes; skip files larger than 256 KiB

- repo_owner: acme
  repo_name: frontend
  branches: main|release/.* # main + every release/* branch
  tags: 'v\d+\.\d+' # and every vN.N tag

# GitLab subgroup namespace is preserved (in a GitLab instance's config repo)
- repo_owner: group/subgroup
  repo_name: service
  branches: main

- repo_owner: acme
  repo_name: legacy
  branches: main
  to_delete: true # drops this repo's rows from the index
```

**JSON keeps working.** All three extensions go through the same YAML parser,
and YAML is a superset of JSON — an existing `.json` config repo needs no
change, and those files can even take `#` comments and trailing commas without
being renamed. The one exception: YAML forbids tabs for indentation, so
**tab-indented** JSON has to be re-indented with spaces. A file that is empty,
or whose entries are all commented out, declares no repos rather than
erroring.

| Field | Req? | Meaning |
|---|---|---|
| `repo_owner` | **yes** | org / user (GitLab: full subgroup namespace, `/` kept) |
| `repo_name` | **yes** | repository name |
| `branches` / `tags` | **one required** | **regex** ([`re.fullmatch`](https://docs.python.org/3/library/re.html#re.fullmatch)) selecting refs to index — a plain `"main"` matches exactly that ref; the repo is indexed at every matched ref |
| `included_patterns` / `excluded_patterns` | default: all files | file globs (e.g. `**/*.py`) to include / exclude |
| `max_file_size` | default: `indexer.maxFileSizeBytes`, else 1 MiB | **bytes**; files whose contents exceed it aren't indexed. Set it per repo to skip generated bundles, vendored blobs and lockfiles you'd rather not pay to embed. Wins over the chart-wide default. **Max 1 MiB** — a larger value is rejected at parse time (see below) |
| `to_delete` | default `false` | `true` removes the repo's rows on the next poll |
| `code_host` | central config repos only | which `codeHosts` instance the repo lives on — see [Central config repo](#central-config-repo) |

An entry's **provider and instance come from the config repo that declares
it** — the `codeHosts` entry the repo belongs to — so entries carry neither
(an entry setting `provider` or `instance` is rejected; in a central config
repo, `code_host` selects the instance instead). A bad regex or an
entry missing both `branches` and `tags` fails the config parse with a clear
error (nothing is indexed) rather than failing mid-index.

### File size limits

Every repo has a maximum indexed file size. It defaults to **1 MiB**, which is
also a hard ceiling: `max_file_size` above it is **rejected** at config-parse
time rather than quietly clamped, because 1 MiB is the largest response
`read_file` can return — a bigger file would be indexed but could never be
read back. Lower it (per repo, or fleet-wide via `indexer.maxFileSizeBytes`)
when a repo carries minified bundles, vendored dependencies or generated code
you don't want to spend embedding budget on. On GitHub the oversized file is
skipped **before it is downloaded**, so the saving covers API quota as well as
embedding and storage.

Two behaviors worth knowing, shared with `included_patterns` /
`excluded_patterns` and with binary files:

- **Skipped files still appear in file listings.** The index mirrors each
  ref's full tree, so `ccx find-files` / the `find_files` tool still show the
  file — only its *contents* are missing. Reading one reports that the path was
  not found; if a file you expect to read comes back that way, check it against
  these limits and your include/exclude patterns first.
- **Changing the limit takes effect on the next poll.** Lowering it drops the
  now-oversized files' contents from the index; raising it indexes them. No
  reindex or restart is needed, but the repo is re-walked, so the next cycle
  after the change does more work than a steady-state one.

Binary files are never indexed, at any size.

## Central config repo

If your organization prefers **one config repo governing every code host**,
mark one instance's config repo `scope: central`:

```yaml
codeHosts:
  github.com:
    provider: github
    baseUrl: https://github.com
    indexer: { appId: "12345", privateKeySecret: { name: ccx-github-app } }
    configRepo:
      owner: acme
      name: index-configs
      dir: configs
      scope: central # ← this repo's entries may name ANY instance below
  ghes:
    provider: github
    baseUrl: https://ghes.example.com
    indexer: { appId: "7", privateKeySecret: { name: ccx-ghes-app } }
    # no configRepo — an index target only, declared from the central repo
```

Entries in a central config repo pick their instance with **`code_host`**,
whose value is a **`codeHosts` map key** (not a URL). An entry without
`code_host` belongs to the instance hosting the config repo, so naming it
explicitly everywhere keeps a central repo uniform:

```yaml
- repo_owner: acme
  repo_name: backend
  branches: main
  code_host: github.com

- repo_owner: infra
  repo_name: deploy-tools
  branches: main
  code_host: ghes
```

Notes:

- **Governance:** whoever can merge to the central config repo controls what
  gets indexed — and thus what becomes searchable — across **every** instance
  its entries name. That is the point of the layout; set `scope: central`
  only when that review model is what you want. (With per-instance repos,
  each instance's owners govern only their own exposure.)
- **Credentials are unchanged:** the central repo's host only needs read
  access to that one repo; each instance's own `indexer` credential still
  reads the repos it indexes.
- **Mixing is fine:** some instances can keep their own (default,
  instance-scoped) config repos alongside a central one. A repo declared by
  **two** config repos is an error — the indexer pauses config changes and
  logs both declaring repos until you remove one.
- **Moving an entry between config repos** (e.g. migrating to a central
  repo): remove it from the old repo, wait one poll cycle, then add it to the
  new one. Adding before removing trips the duplicate error above (nothing
  breaks — config changes just pause until it's resolved); the brief absence
  re-indexes that repo, which is much cheaper than a cold index thanks to
  warm caches.
- An instance-scoped config repo (the default) **rejects** `code_host` — the
  error points at the `scope: central` setting.

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
| **License** | `secrets.cocoindexPlus.{licenseKey,existingSecret}` | **yes** | runtime license, wired to both workloads — see [License key](#license-key) |
| **Embedding** | `embedding.secretEnv` / `existingSecret`, `embedding.model`, `embedding.env` | **yes** (credential) | `model` defaults to `text-embedding-3-small`; the provider key has no default. **Pin the model version and keep it fixed:** query vectors are only comparable to index vectors from the same model, so changing `embedding.model` (or pointing at an endpoint that swaps models underneath) requires a full reindex — treat a model change as a deliberate operation: update the value, then rebuild the index |
| **API tokens** | `secrets.apiTokens.{tokens,existingSecret}` | **env lane only** | the shared bearer token the server accepts and the CLI sends. Required on the **env lane** (`auth.mode: apiKey` with nothing richer set) — empty there means every request is rejected. **Must be empty on the file lane** (`mode: oidc`, `auth.oidc`, any `auth.apiKeys` record, any top-level `authz`/`audit`/`rateLimit` value), where rendering fails otherwise and `auth.apiKeys` records replace it. See [Access](#access-authentication--authorization) |
| **Code hosts** | `codeHosts.<instance>.{provider,baseUrl,indexer,configRepo,caBundleSecret,rateLimit}` | **yes** | one entry per code-host instance (github.com, GHES, gitlab.com, self-managed GitLab — a deployment can span several). `indexer` holds the credential as a **Secret reference** (`appId` + `privateKeySecret` for GitHub; `tokenSecret` for GitLab); `configRepo` names that instance's [index config repo](#index-config-repo) (optional if a [central config repo](#central-config-repo) declares this instance's repos; `scope: central` marks the central one); `caBundleSecret` supplies a private/corporate CA (PEM); `rateLimit` overrides the per-instance API budget. The **map key is the instance's frozen identity** — part of every repo's index identity, so renaming it means a full reindex; `baseUrl` is the mutable connection address |
| **Local config lane** | `localConfig.{checkout,gitRef,dir}` + `indexer.{extraVolumes,extraVolumeMounts}` | optional | config for locally-mounted (`local_path`) repos, read from an operator-mounted checkout; omit unless you index local checkouts |
| **Images** | `images.{indexer,queryServer}.{repository,tag,pullPolicy}`, `imagePullSecrets` | default | default to the published GHCR images at the chart version; override `repository` for a [mirror](#air-gapped--relocate-images) |
| **Auth** (who may call) | `auth.mode` (`apiKey` / `oidc` / `none` dev), `auth.apiKeys`, `auth.oidc` | default (`apiKey`) | never expose with `none`; `oidc` = company-IdP SSO for engineers; `auth.apiKeys` = attributable, individually revocable key records — usable **with or without** `oidc`, and distinct from the shared `secrets.apiTokens` above. See [Access](#access-authentication--authorization), [SSO login (OIDC)](#sso-login-oidc--api-key-records) |
| **Authz** (what they see) | `authz.mode` (`indexScope` / `codeHostMirrored`), `authz.attestations`, `authz.codeHosts.<instance>.{identityMapping,mappingClaim,permissionCredential,identityMappingCredential,approvedOrgs}` | default (`indexScope`) | `indexScope` = every authenticated caller reads everything indexed; `codeHostMirrored` mirrors each signed-in engineer's real code-host permissions and requires `auth.mode: oidc` plus operator attestations. The credentials here are **Secret references projected into the query server only** — separate from the indexer's, though the same GitHub App by default. See [Code-host-mirrored authorization](#code-host-mirrored-authorization) |
| **Database** | `database.bundled.enabled`, `database.{target,internal}.{url,existingSecret,schema}` | default (bundled) / **if prod** | bundled Postgres for test; external (Cloud SQL) for prod — see below |
| **DB memory** | `database.bundled.{sharedBuffers,effectiveCacheSize,shmSize}` | default (1GB / 2GB / 256Mi) | size `sharedBuffers` ≈ your vector-index set so searches stay in memory — see [Postgres memory sizing](#postgres-memory-sizing) |
| **Query server** | `queryServer.{replicaCount,service,ingress,publicUrl,mcpExtraAllowedOrigins,autoscaling,resources}` | default | scaling + exposure (ingress off by default); `publicUrl` = the deployment's public origin — see [Exposing the query server](#exposing-the-query-server) for the `/mcp` Origin rules |
| **Refresh** | `indexer.refreshIntervalSeconds`, `indexer.repoRefreshIntervalSeconds` | default (300s) | poll cadences |
| **File size** | `indexer.maxFileSizeBytes` | default (1 MiB) | largest file to index, in bytes, for repos that don't set their own `max_file_size`. 1 MiB is also the ceiling — a larger value is rejected at startup. See [File size limits](#file-size-limits) |
| **Symbol index** | `indexer.symbolIndex.{enabled,maxFilesPerGitRef,maxIrBytesPerGitRef}` | default (on; 50 000 files / 1 GiB per ref) | the graph behind `ccx defs`/`refs`. Unset keys use the indexer's own defaults. **`enabled: false` reclaims the storage rather than pausing** — re-enabling re-extracts everything; see [Symbol index](#symbol-index) |
| **Timeouts & load** | `queryServer.{requestDeadlineSeconds,maxConcurrentRequests}`, `queryServer.ingress.timeoutSeconds` | default (60 / 64 / 75) | the server's per-request deadline and admission cap, and the ingress budget — see [Timeout chain](#timeout-chain) |
| **Agentic query** | `agentQuery.{enabled,model,reasoningEffort,requestDeadlineSeconds,contextWindowTokens,maxOutputTokens,maxConcurrentRequests,maxConcurrentModelCalls,modelCallTimeoutSeconds,secretEnv,existingSecret,cache.*}` | default (**off**) | `ccx query` / MCP `query_codebase`. **Enabling sends questions and read source snippets to your model provider** — `model` is then required, and some models need `reasoningEffort` set to use tools at all. Requires a larger `queryServer.ingress.timeoutSeconds` (the chart enforces it). See [Agentic query](#agentic-query) |

**Secrets: inline or existingSecret.** Every secret group accepts an
`existingSecret` (name a pre-created k8s Secret — e.g. from your secret manager via
External Secrets/CSI) instead of an inline value. Prefer that in production.

### License key

The key your rep issues is a long string beginning `key/`. Set it as
`secrets.cocoindexPlus.licenseKey`, or hand the chart a Secret you created with
`existingSecret` (data key `COCOINDEX_PLUS_LICENSE_KEY`).

**The license is validated against `api.keygen.sh`** — at startup in the
indexer, and on the first `grep` call in the query server — so the cluster
needs outbound HTTPS to that host. Allow it in your egress policy alongside your
code host and embedding provider. If your deployment cannot reach the internet
at all, ask us for an **offline-entitled license** — it is a different license
issued for exactly that case, and it validates without any network access.

**Keep it on one line.** The key is a single unbreakable token, so a YAML form
that wraps it (`|-`, `>-`) puts a newline or a space *inside* the value and
breaks it. Whitespace around the key is trimmed, so a trailing newline — from
`kubectl create secret generic --from-file`, say — is fine.

**If the indexer exits at startup with a license error**, check the value that
actually reached the container rather than the one in your values file. A bad
license fails the two workloads *differently*: the indexer dies at startup, while
the query server starts fine and fails later, when a `grep` query needs the
licensed engine — so check it there too (swap `-indexer` for `-query-server`):

```bash
kubectl -n ccx exec deploy/ccx-cocoindex-code-plus-indexer -- \
  sh -c 'printf "[%s] %s chars\n" "$(printf %.4s "$COCOINDEX_PLUS_LICENSE_KEY")" "${#COCOINDEX_PLUS_LICENSE_KEY}"'
```

That reveals only the first four characters and the length — enough to identify
a bad value without exposing a good one. Expect `[key/]` and a few hundred
characters; `[<you]` or `[REPL]` means a quickstart placeholder was never
substituted, and a much shorter length means a truncated copy.

An error saying the key does not *exist* means the license service did not
recognize the value sent to it. If the check above looks right, send us exactly
that line and we will check the issuance. An error about reaching
`api.keygen.sh` is an egress problem, not a key problem.

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

> **Cloud SQL trap — the read-only role is not read-only by default.**
> A user created with `gcloud sql users create` (or the Cloud SQL console)
> is automatically granted **`cloudsqlsuperuser`**, which holds CREATE on
> the `public` schema. The `GRANT pg_read_all_data` above then does *not*
> make it read-only — the role can still write. After creating it, revoke
> the inherited role:
>
> ```sql
> REVOKE cloudsqlsuperuser FROM ccx_query;
> ```
>
> Verify with a connection as that role — `CREATE TABLE t(i int);` must fail
> with *permission denied for schema public*:
>
> ```sql
> SELECT ARRAY(SELECT b.rolname FROM pg_auth_members m
>   JOIN pg_roles b ON m.roleid = b.oid WHERE m.member = r.oid)
> FROM pg_roles r WHERE r.rolname = 'ccx_query';   -- expect {pg_read_all_data}
> ```

### Database TLS

*(Applies to releases from **0.1.20**. Earlier releases could not negotiate
TLS on the internal state connection at all — if you run one, upgrade, or see
that release's guide.)*

Every database connection follows **libpq semantics**, so a DSN written for
`psql` behaves identically here:

| `sslmode` | Encrypted | Chain verified | Hostname verified |
|---|---|---|---|
| `disable` | no | — | — |
| `prefer` (default) | if offered | no | no |
| `require` | yes | **no** | no |
| `verify-ca` | yes | yes | **no** |
| `verify-full` | yes | yes | yes |

Recommendations:

- **Managed Postgres (Cloud SQL, RDS, …) uses a provider CA that is not in
  system trust stores** — download it and use
  `sslmode=verify-ca&sslrootcert=<path>`. `verify-ca` rather than
  `verify-full` because you typically dial the instance **by IP** while its
  certificate names the instance. Mount the CA into the indexer Pod via
  `indexer.extraVolumes`/`extraVolumeMounts` and point `sslrootcert` at the
  mounted path.
- **`require` encrypts but does not authenticate the server** (that is
  libpq's behaviour too). Acceptable inside a private VPC; prefer
  `verify-ca` when the path matters.
- **Don't rely on `prefer`**: against a server that permits plaintext it
  silently falls back to an unencrypted connection that *looks* like
  success. Enforce TLS server-side (Cloud SQL `ENCRYPTED_ONLY`, RDS
  `rds.force_ssl=1`) and state your `sslmode` explicitly.

Two certificate rules inherited from our TLS stack (rustls), which differ
from `psql`/OpenSSL:

1. **A self-signed server certificate cannot be verified**, even by pointing
   `sslrootcert` at that same file — the CA must be a *separate* certificate
   that signed the server's. Managed providers already work this way.
2. **Certificates must carry a SAN**; there is no fallback to the legacy CN
   field. A CN-only certificate fails `verify-full` (though `verify-ca`
   still works).

### Cloud SQL on GKE

Two supported ways to connect, both keeping the instance `ENCRYPTED_ONLY`:

- **Direct with a verified certificate (simplest):** fetch the instance CA
  (`gcloud sql instances describe <instance>
  --format='value(serverCaCert.cert)'`), put it in a Secret, mount it via
  `indexer.extraVolumes`, and use
  `sslmode=verify-ca&sslrootcert=<mounted path>` in the indexer DSNs (the
  query-server DSN can do the same or use `require`).
- **Cloud SQL Auth Proxy sidecar:** set `database.cloudSqlProxy.enabled:
  true` + `instanceConnectionName`, authenticate via Workload Identity (a
  GSA with `roles/cloudsql.client` named in `serviceAccount.annotations`),
  and point the indexer DSNs at `127.0.0.1:5432?sslmode=disable` (in-Pod
  loopback; the proxy encrypts everything leaving the Pod). Choose this when
  you prefer IAM-authenticated database access or don't want to manage the
  CA file. *IAM changes take minutes to propagate — if the proxy logs a 403
  on `iam.serviceAccounts.getAccessToken`, restart the Pod.*

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

### Symbol index

Alongside the vector index, the indexer builds a **resolved symbol graph** per
indexed git ref — it backs `ccx defs` / `ccx refs` and the MCP
`find_definitions` / `find_references` tools ([cli.md](cli.md)). Covered
languages: Python, TypeScript/JavaScript (incl. TSX), C/C++, C#, Rust; other
languages are still searchable, they just have no symbol graph. Operational
notes:

- **On by default, tunable via `indexer.symbolIndex`.** Every key is optional —
  left unset, the indexer's defaults apply and the chart sets no env var:

  ```yaml
  indexer:
    symbolIndex:
      enabled: true          # false turns symbol indexing off — see the warning below
      maxFilesPerGitRef: 50000       # default; eligible source files per ref
      maxIrBytesPerGitRef: 1073741824 # default 1 GiB of extracted symbol data per ref
  ```

  (They map to `CCX_SYMBOL_INDEX_ENABLED`,
  `CCX_SYMBOL_MAX_FILES_PER_GIT_REF`, `CCX_SYMBOL_MAX_IR_BYTES_PER_GIT_REF`
  should you set the env directly.)
- **Turning it off reclaims storage — it is not a pause.** `enabled: false`
  changes what the indexer's incremental state is keyed on, so the next pass
  re-runs without symbols and the symbol rows (plus their shared parsed-module
  data) are garbage-collected. Re-enabling **re-extracts every indexed ref from
  scratch**, which costs a full symbol rebuild. Flip it as a deliberate
  capacity decision, not to ride out an incident.
- **An upgrade that widens language coverage re-extracts once.** When a release
  adds or changes language packs (the way C# and Rust were added), the
  extraction identity changes and the next indexer pass re-extracts every file
  — that is exactly what gives already-indexed refs their new-language symbols.
  Budget one extra full symbol pass after such an upgrade; steady-state cost is
  unchanged afterwards.
- **Oversized refs are skipped loudly, not truncated.** A ref beyond either cap
  gets **no** symbol graph, and every `defs`/`refs` response for that ref
  carries a coverage status saying so (as do refs that are still building, or
  where some files failed to parse) — clients are told absence is not
  completeness rather than shown silently empty results.
- **Storage** — four additional tables (`symbol_module_roots`,
  `symbol_definition`, `symbol_reference`, plus content-addressed
  `parsed_module` data shared across refs), `repo_key`-partitioned like the
  rest. Plain B-tree rows; they don't compete with the
  [vector-index memory budget](#postgres-memory-sizing).
- **Compute** — symbol resolution is whole-ref: any change on a ref re-resolves
  that whole ref on the next indexer pass (incremental symbol indexing is
  planned). On large, busy repos this shows up as indexer CPU, not query-side
  latency.

### Agentic query

`ccx query "<question>"` (and the MCP `query_codebase` tool) answers a
natural-language question about your code with a cited prose answer, instead of
returning raw search hits. A server-side agent runs the investigation: it
searches, greps, reads files, and follows symbols using **the same authorized
reads the low-level API exposes**, so it can never see a repository the caller
could not already search.

**It is off by default, and turning it on is a data-governance decision.**
Enabling it sends the caller's question and the source snippets the agent
chooses to read to your configured model provider. Nothing else changes: no new
network path into the cluster, no new database, no stored transcripts.

```yaml
agentQuery:
  enabled: true
  model: openai/gpt-5.6-terra # provider-PREFIXED — see the warning below
  reasoningEffort: none # also see the warning below
  contextWindowTokens: 256000 # match your model; chart default is 128000
```

- **Prefix the model with its provider** (`openai/…`, `anthropic/…`,
  `gemini/…`). The images deliberately don't phone home for LiteLLM's model
  registry, so a **bare** name is matched against the registry bundled in the
  installed LiteLLM — which cannot know models released after it. A bare
  recent-model name therefore works on a laptop and fails *every* request in
  the cluster. The server rejects an unresolvable model **at startup** with
  the corrected name, so this shows up as a failed rollout rather than silent
  `503`s. (The same applies to `embedding.model`; the long-standing default
  needs no prefix.)

- **Credentials.** If the completion model uses the same provider as
  `embedding` (e.g. both OpenAI), there is nothing to add — LiteLLM reads the
  same key the embedding secret already supplies. For a *different* provider,
  set `agentQuery.secretEnv` (or `existingSecret`); those credentials are
  injected into the **query server only**, never the indexer.
- **`reasoningEffort` is not cosmetic.** Some models refuse function tools
  entirely unless it is set — `gpt-5.6-terra` rejects the request outright at
  any other value, so the feature cannot work without `reasoningEffort: none`.
  Check your model before rolling out.
- **Raise your ingress timeout.** An agentic query runs far longer than a
  low-level one (`agentQuery.requestDeadlineSeconds`, default **600 s**), and a
  single backend timeout covers every route. The chart **refuses to render** if
  `queryServer.ingress.timeoutSeconds` does not clear it — see
  [Timeout chain](#timeout-chain).
- **Cost is bounded per request, not per knob.** One query is capped at 30
  model turns for the main agent plus at most 8 helper sub-investigations of 15
  turns each; there is no unbounded loop to configure around.
- **Capacity.** `agentQuery.maxConcurrentRequests` (default 4 per pod) admits
  agentic queries; over-capacity callers get an immediate retryable `503` while
  low-level search is unaffected. Each principal may hold 2 at a time.

#### Answer cache (optional)

`agentQuery.cache.enabled` lets the server reuse work across requests: a
repeated question is answered from its stored answer, a paraphrase is
recognised as the same question, and a partially-changed investigation reuses
the parts that still hold. Repeated questions then cost almost nothing.

```yaml
agentQuery:
  cache:
    enabled: true
    # The one schema the query server owns and writes.
    schema: ccx_agentic
```

Three consequences to know before you turn it on.

- **The query server becomes a writer — of exactly one schema.** It owns
  `agentQuery.cache.schema` and creates its tables there at startup; your index
  schemas keep their read-only grants. With the bundled database the chart
  provisions this for you. With an **external** database, create it first:

  ```sql
  CREATE SCHEMA ccx_agentic AUTHORIZATION <your query role>;
  CREATE EXTENSION IF NOT EXISTS vector;  -- if it is a separate database
  ```

  Startup fails loudly if the role cannot do this — an enabled cache never
  quietly turns itself off.

- **The indexer moves to cycle mode.** A cached answer may only be built from
  an index read the indexer has confirmed complete, and only a *finished* pass
  can confirm that. Enabling the cache therefore defaults
  `indexer.cycleSeconds` to 300: the indexer runs a catch-up pass every five
  minutes instead of watching continuously. Index freshness becomes bounded by
  that interval plus the pass duration. Set `indexer.cycleSeconds` to change
  the interval, or to `0` to keep live indexing — in which case the cache will
  serve normally and store nothing.

- **Nothing is evicted automatically.** There is no TTL or capacity limit in
  this release. The two ways to remove cached content are a repository purge
  and dropping the schema:

  ```bash
  # Remove every cached record touching one repository.
  kubectl exec deploy/<release>-query-server -- \
      python -m cocoindex_code_plus.query_server.agentic.cache.purge \
      --repo acme/service --dry-run   # drop --dry-run to apply

  # Start over.
  psql -c 'DROP SCHEMA ccx_agentic CASCADE'
  ```

  Purge is also the answer to "someone asked something they should not have":
  it removes the questions, the answers, and everything derived from them for
  that repository, and it linearizes against in-flight requests, so nothing
  from before the purge can be written after it.

**Seeing whether it pays.** Every request's audit event carries the full cost
split — `cost_spent` (what the request actually consumed, model calls and
tokens included) and `cost_reused` (what it would have cost to recompute the
work served from the cache) — so fleet-level savings aggregate straight from
the audit log. Per request, `ccx query --stats` prints the same numbers as
one line (see [cli.md](cli.md)); the counters never show unless asked, and
the MCP tool omits them unless called with `include_stats`.

If you change `CCX_EMBED_MODEL`, the server refuses to start until the cache's
compatibility epoch is bumped in the same release — searching behaves
differently under a new model, and stored answers must not outlive that. A
companion command re-embeds stored questions after a change that only affects
how they are indexed:

```bash
kubectl exec deploy/<release>-query-server -- \
    python -m cocoindex_code_plus.query_server.agentic.cache.backfill --limit 500
```

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
doesn't create it). Until then, `kubectl port-forward` is the simplest path.

**On GKE, prefer a Google-managed certificate + a reserved static IP** — the
recipe below avoids three separate traps we hit deploying this ourselves:

```yaml
queryServer:
  ingress:
    enabled: true
    className: gce
    host: ccx.example.com
    tls: false            # deliberate: GKE managed certs attach via the
                          # annotation, NOT spec.tls — leave this false
    annotations:
      networking.gke.io/managed-certificates: ccx-cert
      kubernetes.io/ingress.global-static-ip-name: ccx-ip
  publicUrl: https://ccx.example.com   # must match `host` (origin-only)
```

1. **Reserve the IP first** (`gcloud compute addresses create ccx-ip --global`)
   and pin it with the annotation. Without it, GKE allocates an ephemeral
   address tied to the Ingress's own lifecycle — recreating the Ingress (or the
   cluster) silently changes the IP, invalidating your DNS record and the
   certificate with it.
2. **Create the `ManagedCertificate` object** (its `spec.domains` must equal
   `host` exactly) and reference it via the annotation:

   ```yaml
   apiVersion: networking.gke.io/v1
   kind: ManagedCertificate
   metadata: { name: ccx-cert }
   spec: { domains: [ccx.example.com] }
   ```
3. **Point DNS at the reserved IP as a plain A record** — if your DNS provider
   proxies traffic (e.g. Cloudflare's proxied/orange-cloud mode), Google's
   domain validation sees the proxy's IP instead of the load balancer and the
   certificate never provisions. Use DNS-only for this name.

Provisioning is asynchronous: the certificate reports `FailedNotVisible` until
the A record is publicly resolvable, then flips to `Active` — typically 15–60
minutes after DNS propagates. Check with
`kubectl describe managedcertificate ccx-cert`.

**Browser-based MCP clients.** `/mcp` validates the `Origin` header (required
by the MCP transport spec): a request carrying an `Origin` that isn't
allowlisted is refused with `403` — and with **no** `publicUrl` and no
`mcpExtraAllowedOrigins`, the allowlist is empty, so *every* request presenting
an `Origin` is refused. Set `queryServer.publicUrl` to the
deployment's public URL (`https://ccx.example.com` — origin only, no path); a
web app on another origin that embeds an MCP client needs its origin added to
`queryServer.mcpExtraAllowedOrigins`. Non-browser clients — the `ccx` CLI and
coding agents — send no `Origin` header and are unaffected.

### SSO login (OIDC) + API-key records

The default auth is the shared API token above (`secrets.apiTokens`); [Access](#access-authentication--authorization) has the whole model in one place. To let engineers sign in with your company IdP instead (Okta, Entra ID, Keycloak, …— any OIDC IdP issuing JWT access tokens), switch to `oidc`:

```yaml
queryServer:
  publicUrl: https://ccx.example.com   # required for oidc — clients discover the server through it
auth:
  mode: oidc
  oidc:
    issuer: https://your-idp.example.com
    audience: api://ccx                # the API/resource registration's identifier
    cli:
      clientId: ccx-cli                # the public client `ccx login` uses
      # redirectPorts: [3276, 3277]    # login callback ports (the default) — advertised to the
                                       #   CLI automatically; register each at the IdP (see below)
  apiKeys:                             # optional: keys for CI/agents, working alongside SSO
    - { id: ci, secretHash: "sha256:<hex>", label: CI, scope: { mode: indexScope } }
```

**An entitlement is required by default — plan for it.** The server demands the scope **`ccx.search`** on every OIDC token (`auth.oidc.requiredScope`, read from the `scope` claim by default). A token that validates but lacks it is refused with **`403 insufficient_scope`**, not `401` — so a rollout where nobody mapped that scope fails for *every* user, with an error that looks nothing like "misconfigured entitlement". Choose one before you roll out: grant it as a plain OAuth scope on the API registration (the default `requiredScopeClaim: scope`, `requiredScopeEncoding: spaceDelimited`); grant it as a role and read that instead (`requiredScopeClaim: roles`, `requiredScopeEncoding: array` — per-user grantable, the Entra `roles` shape); or opt out explicitly with `requiredScope: ""`, which lets any validly-audienced token from your tenant through.

Your IdP admin registers **two things at minimum**: an **API/resource registration** (its identifier becomes `audience` — it must be distinct from any login client) and a **public CLI client** (PKCE, loopback redirect — its id goes in `cli.clientId`). For the CLI client's **redirect URIs**: if your IdP matches redirect URIs exactly, port included (Okta does — it doesn't honor the RFC 8252 any-loopback-port rule), register `http://127.0.0.1:3276/callback` and `http://127.0.0.1:3277/callback` — the server's default callback ports, which it advertises to the CLI automatically so **engineers never configure a port**; `ccx login` binds the first free one. Different ports? Set `auth.oidc.cli.redirectPorts` to match what you registered — the config list and the IdP registration must stay in step, or logins fail with an IdP-side redirect-URI error. IdPs that do honor RFC 8252 (Keycloak) can instead register a port-wildcard loopback URI, which covers the advertised ports too. Engineers then run `ccx login` (see [cli.md](cli.md)); no per-user setup on the server. **Dynamic client registration is deliberately unsupported** (the server rejects it at startup), so any MCP client that signs in *interactively* — rather than presenting a key record's bearer token — needs its own pre-registration as well. For a self-managed IdP with a private CA, add `auth.oidc.caBundleSecret: { name: <secret> }`.

**Okta notes.** The registrations above — a custom audience, the `ccx.search` scope, custom claims — live on an Okta **custom authorization server**, which requires the **API Access Management add-on**; without that SKU there is no direct path, and Okta joins the [bring-your-own-authorization-server](#bring-your-own-authorization-server-google-workspace-okta-without-api-access-management-saml-only-idps) estates below. With it: Okta grants scopes in the **`scp` array claim** and stamps no RFC 9068 `typ` header, so set `requiredScopeClaim: scp`, `requiredScopeEncoding: array`, and leave `requireTypAtJwt` off. Okta also issues **refresh tokens only for the `offline_access` scope** — enable the Refresh Token grant on the CLI app, allow the scope in the authorization server's access policy, and have engineers sign in with `ccx login --scope "ccx.search offline_access"`; without it every session ends when the access token expires (typically an hour). Finally, remember Okta's exact redirect-URI matching from the paragraph above (register every advertised `redirectPorts` entry), and assign users or a group to the CLI app — an unassigned user's login fails at Okta regardless of token policy.

Anything beyond the plain shared token — `oidc`, `apiKeys` records, or any `authz:` / `audit:` / `rateLimit:` value (`helm show values` documents them) — moves the whole auth configuration into one server-side config file the chart renders. Note `authz:` is a trigger too, so even `authz: { mode: indexScope }` (the default, set explicitly) flips the lane. Two consequences:

- **`secrets.apiTokens` must then be empty** (the chart refuses to render otherwise): shared bare tokens are replaced by `auth.apiKeys` **records** — each carries only a `sha256:` hash of its secret (safe to keep in values), and the presented token becomes `ccxk_<id>_<secret>`. Records are attributable and individually revocable; rotation is editing the list + `helm upgrade`.
- **Rate limiting needs to know your ingress**: the chart derives the client-IP extraction strategy from `queryServer.ingress.className` automatically for `gce` (including the trusted GCLB ranges), and for `gce-internal` / `nginx` requires `rateLimit.trustedProxyCidrs` (your proxy-only subnet / the actual ingress peer CIDRs). Any other ingress class: set `rateLimit.clientIpStrategy` explicitly or rendering fails.

#### Minting a key record

Key records are the **production static credential**: on an SSO deployment they
serve CI and coding agents alongside `oidc`, and with no IdP they serve every
caller (`auth.mode: apiKey` + records — the "Attributable keys, no IdP yet" row
of the [Access](#access-authentication--authorization) decision table). A record's secret is
**exactly 32 random bytes carried as unpadded base64url** (43 characters); the
format is pinned, so a presented token in any other shape is refused before
hashing even reaches the comparison. Generate it, never hand-pick it — you keep
the secret, your values keep only the hash:

```bash
python3 - <<'EOF'
import base64, hashlib, secrets
raw = secrets.token_bytes(32)
print("secret:    ", base64.urlsafe_b64encode(raw).rstrip(b"=").decode())
print("secretHash: sha256:" + hashlib.sha256(raw).hexdigest())
EOF
```

Put `secretHash` in the record; hand the holder `ccxk_<id>_<secret>` to use as
`CCX_API_TOKEN`. The secret is never stored server-side and cannot be recovered —
to reissue, replace the record.

The record **`id` must match `[A-Za-z0-9-]{1,64}`** — hyphens fine, **no
underscores** (that is what separates `<id>` from `<secret>` in the token), so
`id: ci-prod` works and `id: ci_prod` is rejected at startup.

A record's `scope` is normally `{ mode: indexScope }` (the whole index). An
explicit `{ mode: repoAllowlist, repos: [<canonical repo uid>, …] }` also exists
— `ccx repos` prints each repo's stable uid ([cli.md](cli.md)) — but, like
`codeHostMirrored`, once the deployment declares any `codeHosts` instance it is
**refused at startup** unless you accept the instance-key binding contract
(`authz.attestations.instanceBindingContractAccepted`, described
[below](#code-host-mirrored-authorization)): repo uids embed the instance key, so
a re-pointed key would silently re-bind the allowlist to another installation's
repos.

### Code-host-mirrored authorization

By default every authenticated caller can search everything indexed (`authz.mode: indexScope` — the index config repo is the access authority, by governing what gets indexed). With **`codeHostMirrored`**, results instead mirror each signed-in engineer's **real code-host permissions**: public repos serve any authenticated user; a private repo serves only callers whose IdP identity maps to a code-host account with read access — and to everyone else it is **indistinguishable from a repo that doesn't exist** (the same 404, no name, no counts). Requires `auth.mode: oidc`. API-key records are deliberately *not* mirrored — a key has no code-host identity; its own `scope` governs it, so CI and agents keep working.

```yaml
authz:
  mode: codeHostMirrored
  attestations:                          # two explicit operator acknowledgments — below
    contextControlReviewCompleted: true
    instanceBindingContractAccepted: true
  codeHosts:
    github.com:                          # same key as your codeHosts registry entry
      identityMapping: codeHostLookup    # join the IdP claim against GitHub's own SSO linkage
      mappingClaim: email                # the value GitHub's linkage records (usually the SSO email)
      permissionCredential:
        appId: "<app id>"                # the indexer App reused (default) — or a dedicated authz App
        privateKeySecret: { name: ccx-github-app }
      approvedOrgs:                      # the governance boundary: only these installations are ever consulted
        - { orgId: <immutable org id>, installationId: <the App's installation id> }
```

**App permissions.** Reusing the indexer App is the default: every GitHub App already carries the `Metadata: read` the permission checks need, one installation covers both roles, and adding a repo stays a single grant. Org-level SAML mapping additionally needs **Organization → Members: Read-only** and **Organization → Administration: Read-only** — GitHub's docs suggest members-read suffices for `externalIdentities`, but in practice the parent `samlIdentityProvider` field also requires administration-read; the pre-flight check below catches it. A **dedicated, metadata-only authz App** is the hardening option when you want the internet-facing query server to hold no content-capable key, a separate API rate budget, or App-level audit attribution — the values shape is identical, just a different `appId` and key Secret. Find the ids: `orgId` from `GET /orgs/<org>` (`.id`); `installationId` from the App installation page's URL.

**Identity-mapping topologies** — pick the row matching where your SSO linkage lives:

| Linkage | Extra values | Extra credential |
|---|---|---|
| GitHub org-level SAML (common case) | — (the block above) | none — the App reads the org's `externalIdentities` itself |
| GitHub enterprise-level SAML / EMU | `enterpriseSlug: <slug>` + `identityMappingCredential: { patSecret: { name: … } }` | enterprise-owner classic PAT, `read:enterprise` only |
| GitLab | `externProvider: <extern_uid provider, e.g. saml>`; `permissionCredential: { tokenSecret: { name: … } }` | GitLab admin token (the identity lookup requires it) |

**The two attestations** are deliberate, named acknowledgments of facts the server cannot verify itself, so it refuses to start without the one your configuration needs (which is which is spelled out after the two):

- `contextControlReviewCompleted`: you reviewed whether context controls (org/enterprise IP allowlists, IdP conditional access) guard your code host, and either none are in use or you re-imposed the equivalent at this deployment's own front door. No server-side check can see a caller's device or source IP the way your code host does.
- `instanceBindingContractAccepted`: you accept the **instance-key binding contract** as an organizational rule — a `codeHosts` key is permanently bound to one installation; never re-point its `baseUrl` and never reuse a key (relocation = a new key + a reindex). Mirrored decisions are keyed by `{provider}:{instance}:{repo id}`, so a re-pointed key would evaluate *another installation's* same-numbered repos. Every startup logs an `instance-binding snapshot` line — diff it across rollouts.

The two are required under different conditions. `contextControlReviewCompleted` is required whenever `codeHostMirrored` is on. `instanceBindingContractAccepted` is required only while the deployment declares `codeHosts` instances **and** uses uid-scoped authorization (mirrored mode, or an apiKey `repoAllowlist` scope) — and setting it when nothing needs it is **rejected at startup as dead config**, so it cannot sit in your values as a no-op. It substitutes for mechanical binding guardrails that have not shipped yet, so expect it to become unnecessary in a later release.

**Behavior to expect.** An engineer who has never signed into GitHub through your SSO has no linkage row and sees public repos only; the self-service fix is one visit to `https://github.com/orgs/<org>/sso` (mapping and permission answers are cached — roughly an hour and a few minutes respectively — so grants, revocations, and first-time links propagate within those windows plus token lifetime). A check the server *cannot* complete — code-host outage, rate limiting, a missing App permission — fails closed as `503`, never a silent grant and never a silent public-only downgrade.

**Pre-flight check** (run before the rollout, with an org-owner token): confirm the linkage exists and records the claim you configured —

```bash
gh api graphql -f query='query { organization(login: "<org>") { samlIdentityProvider { externalIdentities(first: 3, membersOnly: true) { nodes { samlIdentity { nameId } user { login } } } } } }'
```

`nameId` must byte-match your `mappingClaim` values (typically the SSO email). A `null` `samlIdentityProvider` means the org has no SAML linkage to mirror against — fix that first.

### Bring your own authorization server (Google Workspace, Okta without API Access Management, SAML-only IdPs)

The OIDC integration validates **JWT access tokens minted for a dedicated audience** — an authorization-server capability that Entra ID, Keycloak, Auth0, and Ping provide, and **Okta only with its API Access Management add-on**. Some login providers don't have it: **Google Workspace's** OAuth server issues opaque access tokens and cannot mint tokens for a third-party API (its only JWTs are ID tokens, which this server deliberately rejects as bearer credentials); **Okta without the add-on** has only its org authorization server — no custom audiences, scopes, or claims, and access tokens consumable only by Okta's own APIs; and SAML-only IdPs speak no OAuth at all. For those estates, front the login provider with an authorization server **you** operate — sign-in stays with your IdP (users still see the Google or Okta SSO screen, with your MFA and sign-on policies); the AS brokers the login and mints the API tokens. The server and chart notice nothing special: `auth.oidc.issuer` simply points at your AS.

Keycloak is the reference shape; the realm essentials, portable to any AS:

- **Resource registration** `api://ccx` — a client with every login flow disabled; its id is your `audience`. Never use it as a login client.
- **Audience mapper** on the CLI client adding `api://ccx` to access tokens — single-audience (the server rejects multi-audience tokens unless RFC 9068 `typ` is enforced).
- **Entitlement** `ccx.search` — either a realm role mapped into a flat array claim (`requiredScopeClaim: roles`, `requiredScopeEncoding: array` — per-user grantable) or a plain OAuth scope (`requiredScopeClaim: scope`, `spaceDelimited`). Either way, keep a `ccx.search` **client scope** attached to the CLI client: `ccx login` requests the scope the server advertises, and that request must be honored even when the entitlement itself rides the `roles` claim.
- **CLI client** (`cli.clientId`): public, PKCE S256, loopback redirect URIs (`http://127.0.0.1/*` — Keycloak honors the wildcard, covering the server's advertised `redirectPorts` as-is), device grant optional.
- **Broker** to your IdP — a standard login-app registration there, needing no add-on SKU. For Google: an *internal-only* OAuth client, plus the broker's hosted-domain restriction so only your workspace can sign in. For Okta (or any OIDC IdP): an **OIDC Web App** whose redirect URI is `https://<keycloak-host>/realms/<realm>/broker/<alias>/endpoint`; keep gating sign-in through that app's user/group assignment in Okta.
- **Mirrored deployments** (`codeHostMirrored`): the access token must carry the claim your `mappingClaim` names (typically `email`), **byte-identical to the code-host SSO NameID** — make the broker import that attribute from the IdP (Keycloak imports email by default; verify on a decoded token before rollout).
- Keycloak stamps `typ: JWT` rather than `at+jwt` — leave `requireTypAtJwt: false`.

### Timeout chain

The server enforces a per-request deadline (`queryServer.requestDeadlineSeconds`,
default **60 s**): an over-deadline request is cancelled and answered with a
clear `503` (or, mid-tool on `/mcp`, a `deadline_exceeded` tool error). For that
answer to reach the caller, the transport in between must time out *later* than
the server:

**ingress (75) > server deadline (60 + a ≤5 s grace)**

- The chart's default implements this: `queryServer.ingress.timeoutSeconds: 75`.
  **If you raise `requestDeadlineSeconds`, raise the ingress as well** —
  nothing auto-derives it.
- **The ccx CLI needs no retuning.** Its timeouts are deliberately not
  coordinated with the server: connects fail on a fixed 10 s bound, and the
  read ceiling is a generous fixed 600 s (1200 s for `ccx query`) that only
  catches a dead network path or a wedged server — the server's own error
  always arrives first. A custom REST/MCP client must still keep its own
  timeout above the chain.
- **[Agentic query](#agentic-query) has its own, much longer deadline**
  (`agentQuery.requestDeadlineSeconds`, default 600 s) — and one backend
  timeout covers every route, so the ingress must clear *that* one:
  **ingress (630) > agentic deadline (600 + ≤5 s)**. Raising the ingress
  budget does not weaken the low-level routes: their own 60 s server deadline
  still answers first, and the ingress is only the backstop behind it. The
  chart enforces this at render time — enabling `agentQuery` while leaving the
  ingress at 75 s fails `helm upgrade` with the required value, rather than
  deploying a service whose load balancer cuts off the queries it is waiting
  on.
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
  point `database.target`/`internal` at it via `existingSecret`. RDS presents
  a certificate signed by an **Amazon RDS root CA** that is not in system
  trust stores — download the
  [region bundle](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html),
  mount it via `indexer.extraVolumes`, and use
  `sslmode=verify-ca&sslrootcert=<mounted path>`
  (see [Database TLS](#database-tls)). Plain `require` also connects (encrypts
  without authenticating the server).
- **Secrets:** AWS **Secrets Manager** → k8s Secrets (External Secrets Operator or
  the Secrets Store CSI driver) → the chart's `existingSecret` fields.
- **Ingress/TLS:** the **AWS Load Balancer Controller** (`queryServer.ingress.className: alb`)
  with an **ACM** certificate via `queryServer.ingress.annotations`
  (`alb.ingress.kubernetes.io/certificate-arn`); TLS terminates at the ALB.
- **Node arch:** releases **after 0.1.12** are **multi-arch**
  (`linux/amd64` + `linux/arm64`) — Graviton (or any arm64) nodes work; the
  kubelet pulls the matching arch automatically. Releases **0.1.12 and earlier**
  are amd64-only: schedule those on **x86_64** nodes.

## Verify the install

The same checks our own release automation runs against every deploy — worth
running once after any install or upgrade, in this order (each isolates a
different layer):

```bash
URL=https://ccx.example.com            # or http://127.0.0.1:8080 via port-forward

# 1. The server is up and running the version you installed:
curl -fsS $URL/health                  # {"status":"healthy","version":"<X.Y.Z>",...}

# 2. Auth is actually on — an unauthenticated search must be refused:
curl -s -o /dev/null -w '%{http_code}\n' -X POST $URL/code/v0/semantic_search \
  -H 'Content-Type: application/json' -d '{"query":"x","limit":1}'   # expect 401

# 3. The index is built and queryable end to end:
export CCX_SERVER_URL=$URL CCX_API_TOKEN=<token>
ccx repos                              # lists your indexed repos once built
ccx search --repo <owner>/<repo> "some phrase from that codebase"
```

**Wiring up your own callers?** The server publishes its OpenAPI description at
`GET /openapi.json` — every route, request and response shape, generated from
the running version rather than transcribed here:

```bash
curl -fsS $URL/openapi.json
```

**No token needed** — the description is what a team reads *before* anyone
issues them one, so it is auth-exempt like `/health`. It describes the
interface only; every route that returns code or index data still requires a
credential. Feed the JSON to your client generator or API browser. Note the
paths are **versioned and namespaced** — `/code/v0/semantic_search`, not
`/search`.

The interactive Swagger / ReDoc pages are not served: they load their
JavaScript from a public CDN, which is both a third-party script in your
operators' browsers and a blank page on a network without egress to it. Point
your own API browser at the JSON instead.

Notes on reading the results:

- `/code/v0/semantic_search` returns **503** until the indexer's first pass
  finishes — that's "not built yet", not "broken". Watch the indexer logs; it
  flips to results with no restart needed.
- **Pass `--repo` when running the CLI outside a git checkout** (CI jobs,
  containers, scripts): interactively the CLI infers the repo from the checkout
  you're standing in, and with no checkout it errors with "No repo specified
  and none detected" — which is easy to misread as the index not being ready.
- If step 3 works over `port-forward` but not through your ingress URL, the
  problem is the ingress/TLS layer, not the deployment — recheck
  [Exposing the query server](#exposing-the-query-server).

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

**Ask us for an offline-entitled license.** A standard license validates against
`api.keygen.sh` at startup ([License key](#license-key)), which a disconnected
deployment cannot do; an offline-entitled one is issued for exactly this case
and needs no network. With the images mirrored and that key in place, the
deployment needs **no egress to us**. The only remaining outbound dependency is
your **embedding provider** (the `OPENAI_API_KEY` / LiteLLM call); point it at a
self-hosted / in-VPC model to run fully air-gapped.

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
On the file lane there is no such string — rotate an **`auth.apiKeys` record** by
editing its `secretHash` (or adding a second record and retiring the first) and
`helm upgrade`; see [Access](#access-authentication--authorization).

**Rotating `existingSecret`-managed secrets.** Both workloads read credentials
**at startup only**, and updating a Kubernetes Secret in place changes no pod
checksum — so a rotation via your secret manager takes effect only after an
explicit restart:

```bash
kubectl -n ccx rollout restart deploy -l app.kubernetes.io/name=cocoindex-code-plus
```

Until you restart, pods keep the old value silently — a rotated-but-not-restarted
credential is the first thing to check when a rotation "didn't work". (The
image-pull secret is the exception: it's read at pull time, so it applies on the
next image pull with no restart.)
