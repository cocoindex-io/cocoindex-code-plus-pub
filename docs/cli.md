# The `ccx` CLI (and MCP)

`ccx` is the client engineers and coding agents use to **query** an indexed
codebase from a workstation, CI, or an agent sandbox. It talks to a query server
that your platform team has deployed ([deploy.md](deploy.md)); the CLI itself
holds no index and needs no license.

## Install

`ccx` is published to **public PyPI** (license-free client, **Python 3.11+**).
Install it as an isolated tool so it's on your `PATH`:

```bash
uv tool install cocoindex-code-plus     # recommended
# or: pipx install cocoindex-code-plus
# or: pip install cocoindex-code-plus
ccx version
```

Pin a version for CI/automation (`cocoindex-code-plus==X.Y.Z`), and keep
installs current. Login settings are fully **discovered from the server**
from **0.1.34 on** (client id, scopes, callback ports, Entra's
resource-indicator switch), so on SSO deployments an older `ccx` prompts for
a client id it shouldn't need, and can fail Entra sign-in with
`AADSTS901002` — treat both as "upgrade me", not misconfiguration.

From **0.1.38 on** the CLI says so itself: when the server advertises a login
setting it doesn't recognise, it warns, names the setting, and points at the
upgrade — then carries on, since login often still works without it. An older
CLI stays silent, which is why the 0.1.34 floor is still worth checking by
hand when a login fails.

Driving `ccx` from a coding agent? Install the **agent skill** too — see
[For agents & automation](#for-agents--automation).

## Configure

Run interactively, `ccx` asks for anything it's missing **once** and saves
the answer (`~/.config/ccx/config.json`; `%APPDATA%\ccx` on Windows) — so a
human's setup is just `ccx login` (SSO) or `ccx status` (token deployments).
`ccx config` shows what is saved and changes it. The environment variables
below always **override** the saved answers and are the way to configure
scripts, CI, and agents. They must be **exported**: `ccx` does not read `.env`
files, so a project `.env` cannot silently re-point the CLI at another
deployment.

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server's URL (e.g. `https://ccx.example.com`, or `http://127.0.0.1:8080` via `kubectl port-forward`). Optional interactively: prompted once and saved as your default; a one-off `--server` overrides without changing the default |
| `CCX_API_TOKEN` | your API token — your platform team issues it: a token shared across the deployment, or your own `ccxk_…` key. Both go in this one variable, sent as `Authorization: Bearer`. On an SSO deployment humans skip this and run `ccx login` instead (below) |
| `CCX_CLIENT_TIMEOUT_SECONDS` | optional; **debug override** of the client's read ceiling — default **600 s** (**1200 s** for [`ccx query`](#ccx-query--ask-a-question-get-an-answer)), with connects failing on their own fixed 10 s bound. The server enforces and reports its own deadline (`deadline_exceeded`), so the ceiling is deliberately generous and uncoordinated: it only catches a dead network path or a wedged server, and your platform team raising the server deadline needs **no** change here |

```bash
export CCX_SERVER_URL=https://ccx.example.com   # optional in a terminal (prompted + saved)
export CCX_API_TOKEN=<your-token>               # token deployments only
ccx status        # server reachable + healthy (and which one), then the credential your next request would use
```

`ccx status` reports two facts, separately. The server block — reachable and
healthy, the URL it resolved and where that came from, version, uptime — is
probed with no credential (`/health` is auth-exempt). The last line is the
**credential** your next request would use: a cached login (`valid`, or
`expired and could not be refreshed` with the fix named), `CCX_API_TOKEN`, or
`none`. That line describes the credential; it does not test it — a token the
server rejects is only caught by your first real request (`HTTP 401`; see
[Troubleshooting](#troubleshooting)). The exit code follows the server fact:
`0` whenever the server is healthy, even when the credential line is a warning,
so scripts can keep waiting on `ccx status` for a server to come up. (CLIs
before 0.1.41 print no credential line and fail `status` outright on an
expired login.)

**SSO deployments (OIDC).** If your platform team enabled company-IdP sign-in,
skip `CCX_API_TOKEN` and sign in once:

```bash
ccx login            # opens your IdP in the browser (PKCE, MFA and all)
ccx login --device   # device-code flow instead (no local browser, e.g. over SSH)
ccx logout           # drops the cached token
```

The server advertises its OAuth client id, so a bare `ccx login` is normally
all you need (what your admin registered to make that work: [sso.md](sso.md)). If your deployment doesn't advertise one, the first login asks
for the id your admin provides — you're prompted in a terminal (or pass
`--client-id` / set `CCX_OIDC_CLIENT_ID`, or run `ccx config set client-id
<id>`); it's remembered per server afterwards. `ccx login` also makes that
server your saved
default (with a printed notice). The token is cached and refreshed
automatically. `ccx logout` drops the **credential** only — your remembered
client id and default server stay, so signing back in takes no flags. CI jobs
and agents keep using `CCX_API_TOKEN` — on SSO deployments that's an issued key
of the form `ccxk_<id>_<secret>`.

During a browser login the CLI listens on a local port to catch the redirect
back from your IdP — and the server tells it which ports to use (typically
3276/3277), so there is nothing to configure. If every listed port is busy,
login says so: free one, or — only if your admin registered an alternative
port — pin it with `--redirect-port <port>` (or `CCX_OIDC_REDIRECT_PORT`).
The scopes to request come from the server too — deployments advertise
them (including `offline_access` where refresh tokens need it, as on Okta
and Entra), so there is nothing to pass; `--scope` remains a debugging
override only.

**Where your token is stored.** In your OS keyring when one is available,
otherwise in `~/.config/ccx/tokens.json` (created `0600`). `ccx config` reports
which is in force. The keyring needs an optional package — install it with
`pip install 'cocoindex-code-plus[keyring]'` (or
`uv tool install 'cocoindex-code-plus[keyring]'`) and log in again to move an
existing token. To choose explicitly, `ccx config set token-cache
auto|keyring|file`, or `CCX_TOKEN_CACHE=<value>` for one command; `keyring`
refuses to fall back to a file, which is the point of it.

**Mirrored deployments.** If your platform team enabled code-host-mirrored
authorization, `ccx repos` and every query show only the repos **your**
code-host account can read — a repo you lack access to behaves exactly like
one that doesn't exist. If private repos you expect are missing, you've most
likely never signed into the code host through your company SSO: do that
once (e.g. the org's SSO page on GitHub) and retry — results can take up to
an hour to appear while server-side caches refresh.

## Use

```bash
# Discover what you can search
ccx repos                                        # list indexed repos: alias, stable uid, default branch

# Semantic search (targets explicitly-named repos; no global "search everything")
ccx search "how are vector embeddings stored"   # scopes to the current repo + branch (see note below)
ccx search foo --repo cocoindex-io/cocoindex     # a specific repo
ccx search foo --repo acme/a --repo acme/b       # several repos, one cross-repo-ranked result list
ccx search foo --repo my/repo --git-ref main     # a specific indexed ref (single repo scope)
ccx search foo -k 10                             # more results; --offset paginates
ccx search parse --lang python --lang rust        # restrict by source language (repeatable)
ccx search config --path 'src/*.py'               # restrict by path glob (repeatable)

# AST structural grep (matches the syntax tree, not text; needs -l/--language)
ccx grep 'def \NAME(\(ARGS*\)):' -l python        # every Python function def
ccx grep 'foo(\X)' -l python --git-ref v1.2       # calls to foo (captures \X), at tag v1.2
ccx grep 'isinstance(\X, \Y)' -l python --path 'src/*.py'

# Symbol navigation: definitions & references (resolved, not text matches)
ccx defs QueryService                             # where is this symbol DEFINED?
ccx defs python:db.Repo.find                      # exact qualified name (the ':' selects the mode)
ccx defs Config --kind class --lang python        # filter by kind / language / --path
ccx refs QueryService                             # where is it USED? (by name, broad)
ccx refs python:db.Repo.find                      # every use of this exact qualified name
ccx refs src/db.py Repo.find                      # exactly this one definition — paste the
                                                  #   `uses: ccx refs …` command a defs row prints
ccx refs QueryService --role call                 # restrict to a reference role

# File access (ref-scoped; repo + ref auto-detected like search)
ccx read-file README.md                          # print a file's contents
ccx read-file src/app.py --offset 40 --limit 20  # 20 lines from line 40 (--offset = 1-based line)
ccx find-files "*.py"                            # list files by glob
ccx find-files --git-ref main                    # list all files, on a specific ref

# Repo / ref metadata
ccx git-refs                                     # the current repo's indexed refs + commit shas
ccx git-refs cocoindex-io/cocoindex              # a specific repo ("(default)" marks the default branch)

# Ask a question and get an answer (if your deployment enables it — see below)
ccx query "how does the indexer decide what to re-embed?"
ccx query "compare auth in these two services" --repo acme/a --repo acme/b
ccx query "what changed in the release flow" --git-ref v1.2 --json
```

`ccx git-refs` lists **git** refs (branches and tags) — not to be confused with
`ccx refs`, which finds where a *symbol* is used.

**Symbol navigation** (`ccx defs` / `ccx refs`) answers "where is this defined"
and "who uses it" from a **resolved symbol graph** the indexer builds — cross-file,
alias- and re-export-aware — not from text matching. It covers **Python,
TypeScript/JavaScript (incl. TSX), C/C++, C#, and Rust**; other languages
remain reachable via `search` and `grep`. The two verbs chain: each `ccx defs`
row ends with a paste-ready command —

```
src/db.py:42:4 [method] python:db.Repo.find
  lang=python  uses: ccx refs src/db.py Repo.find
```

— and running that `uses: …` command returns exactly that definition's uses
(it carries any `--repo`/`--git-ref`/`--server` flags you passed, so it
re-queries the same scope). Three precisions of `ccx refs`, broad to exact: a
bare `ccx refs NAME` casts a wide net by unqualified name; the headline's
**qualified name** (`python:db.Repo.find` — every qualified name opens with
its language tag, `python:` / `tsjs:` / `cpp:` / `csharp:` / `rust:`, and
TS/JS and Rust names carry a second `:` between the file path and the entity)
matches exactly, covering
every occurrence and overload under it, with no flag needed; the pasted
`uses:` command pins one definition. Copy rather than compose the exact
pair — the headline's qualified name is *not* the second token. Reference rows are labeled by **role** (`call`, `import`,
`type_use`, `inherit`, `field_access`, …; filter with `--role`) and by
**resolution**: `resolved` is definite, `ambiguous` enumerates each surviving
candidate as its own row, and `name_only` marks a mention whose target couldn't
be resolved (e.g. an external import). Watch stderr for the **coverage note**:
it tells you when the symbol index for the ref isn't built yet, skipped the ref
as too large, parsed only part of it, or lags the ref's head — in all of those,
a missing symbol may just be unindexed, so absence is not completeness.

`ccx search`, `grep`, `read-file`, and `find-files` scope to the current repo
**only when the working directory is a git checkout with a GitHub/GitLab
`origin`** — that origin is mapped to the matching indexed repo. Otherwise (no
git repo, or a non-GitHub/GitLab origin) the command **errors** with guidance:
pass `--repo` (repeatable for `search`, up to the server's per-search cap) —
`ccx repos` lists what's indexed. There is no global "search everything" mode.
With several `--repo`s, each repo is searched at its own server-side default
ref (a stderr note names each resolved ref); `--git-ref` applies to a single
repo scope.

These commands are also **ref-scoped**: they operate on one git ref of the repo.
`--git-ref` takes a branch or tag name (`main`, `v1.2`) — or the explicit
`heads/<branch>` / `tags/<tag>` form if a branch and tag share a name. When you
omit it, the CLI uses **your checked-out branch** if that branch is indexed
(including its `origin` upstream when the local name differs), else the repo's
**default branch**; it prints a `Using git ref …` note to stderr so you always
know which ref answered. `ccx git-refs` lists what's indexed.

Similarly, when you run `search` or `grep` from a **subdirectory** of the
checkout (and gave no `--path`), results are scoped to that subtree — the note
on stderr names the glob; run from the repo root or pass `--path '*'` to cover
the whole repo.

`--offset` differs by command: for `read-file` it's a **1-based line number**; for
`grep` and `find-files` it's a **skip count** for paginating results.

**Server limits.** Requests are bounded server-side with clear `400`s when
exceeded: search `--top-k` ≤ 100, result pages ≤ 500, query/pattern text ≤ 8 KB.
`read-file` returns at most **5 000 lines** (and at most 1 MiB of content) per
call — for a bigger file, page with `--offset`/`--limit`; the response's line
numbers show where the window ended.

### `ccx query` — ask a question, get an answer

Every command above returns *material* — hits, lines, symbol rows — and leaves
the reading to you. `ccx query` returns a **written answer with citations**: a
server-side agent runs the investigation for you, searching, grepping, reading
files, and following symbols, then writes up what it found. Each claim carries
a citation like `[s0:src/app.py#L40-L52]`: `s0` is one of the scopes the command
lists on stderr (`s0: <owner>/<repo> @ <ref> (commit <sha>)`), and the line
numbers are at that commit, so you can open exactly what the agent read.

```bash
ccx query "how does the indexer decide what to re-embed?"
ccx query "compare how these two services authenticate" --repo acme/a --repo acme/b
ccx query "walk me through the release flow" --git-ref v1.2
ccx query "what are the main components?" --json    # exact response model
```

Scoping works exactly like `ccx search`: the current checkout by default,
`--repo` (repeatable) to name repos, `--git-ref` for a single-repo scope. The
answer is Markdown on stdout.

Two things to expect:

- **It is slower.** The agent runs many reads before answering — seconds to a
  couple of minutes for a broad question, up to the server's agentic deadline
  (10 min by default). Reach for `ccx search`/`grep` when you know what you're
  looking for, and `ccx query` when you don't.
- **It may be turned off.** It is off unless your deployment enables it,
  because answering requires sending your question and the code the agent
  reads to a model provider. When it's off the command exits non-zero with
  `agent_query_unavailable`; ask your platform team.

- **A repeated question may come back instantly.** If your deployment enables
  the answer cache, asking something already answered — by you or by a
  colleague — returns the stored answer without re-running the investigation,
  and a rephrasing of the same question counts as the same question. A stored
  answer is only reused while the code it was derived from is unchanged; edit
  the files it cited and the next ask investigates again. `--json` reports
  which happened, under `usage.result_cache_hit`.

By default the command prints the answer and nothing else. Pass `--stats` to
also see what the request cost and how much of that the cache covered — per
metric, the no-cache total and the share served from storage:

```text
stats: queries 6 (reused 3 / 50%), model calls 27 (reused 13 / 48%),
input tokens 238142 (reused 105992 / 45%), output tokens 14554
(reused 6610 / 45%), tool calls 73 (reused 38 / 52%), 47.8s
```

A metric with nothing reused shows just its total. The reuse can be partial:
an investigation reuses whatever stored work still applies — whole
sub-answers, or earlier investigation steps re-checked against the current
code — and pays live for the rest. `--json` carries the full breakdown under
`usage.cost` whether or not `--stats` is set.

The agent can only read what **you** can already read — it runs under your
identity and the same repository permissions as every other command, so it
never surfaces a repo you couldn't search yourself. That applies to cached
answers too: nothing is served from the cache before your own authorization
has been checked against the repositories in question.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HTTP 401` | Missing or wrong `CCX_API_TOKEN` — it must match a token the server accepts. `ccx status` names the credential in use but does not validate it against the server. |
| `login: expired and could not be refreshed` (in `ccx status`), or `Your login for … has expired and could not be refreshed` (from any other command) | Your cached SSO login aged out — the IdP's session lifetime, so an overnight gap can do it. The server itself is fine (`status` still reports it healthy). Run `ccx login` again, or `ccx logout` to fall back to `CCX_API_TOKEN`. |
| `HTTP 503` | Index not built yet — the indexer hasn't populated the table; retry once it has (ask your platform team if it persists). |
| connection refused / unreachable | Wrong `CCX_SERVER_URL`, or a `kubectl port-forward` that dropped. Run `ccx config` to see the server it resolved and where that came from. |
| talking to the wrong server | Something outranks your saved default — `--server`, or an exported `CCX_SERVER_URL`. `ccx config` names the source. (A project `.env` is *not* read by `ccx`.) |
| `is writable by other users` | `~/.config/ccx/config.json` decides where your credentials are sent, so a group/world-writable one is refused: `chmod go-w` it. World-*readable* is fine. |
| `no usable keyring backend` | Your token cache is set to `keyring` on a host without one. `ccx config set token-cache auto`, or `CCX_TOKEN_CACHE=file` for one command. |
| `Cannot bind … login callback port` | Every callback port the server advertises is in use on your machine (another `ccx login`, or an unrelated app). Free one, or pin an admin-registered alternative with `--redirect-port`. |
| IdP shows a redirect-URI error at login | The callback port doesn't match an IdP registration — usually a stale `CCX_OIDC_REDIRECT_PORT` or `--redirect-port` overriding the server-advertised ports. Unset it and log in again; ports the server advertises are registered by your admin ([sso.md → Verifying before rollout](sso.md#verifying-before-rollout) ends with the per-IdP error table). |
| login prompts for a client id on an SSO server, or Entra fails with `AADSTS901002` despite `resourceIndicator: false` | Your `ccx` predates server-advertised login settings — upgrade to 0.1.34+: `uv tool install -U cocoindex-code-plus`. |
| `ccx login` warns about login settings it doesn't recognise | The server advertises a setting this CLI is too old to use. Upgrade: `uv tool install -U cocoindex-code-plus`. Login may still succeed meanwhile. |

## For agents & automation

- **Agent skill** — [`skills/ccx/SKILL.md`](../skills/ccx/SKILL.md) teaches a
  coding agent when and how to drive `ccx` (search vs. structural grep vs.
  symbol navigation, scoping, reading empty results). Install it user-level
  with the [skills CLI](https://skills.sh), which detects Claude Code, Codex,
  Cursor, Gemini CLI and others:

  ```bash
  npx skills add cocoindex-io/cocoindex-code-plus-pub -g
  ```

  (`npx skills update ccx -g` later; or copy the folder to
  `~/.claude/skills/ccx`.)
- **Nothing requires a terminal** — export `CCX_SERVER_URL` + `CCX_API_TOKEN` and
  a coding agent or CI job runs `ccx` directly; prompts only ever appear on a
  TTY (without one, a missing setting is a non-zero exit with the flags to
  pass). Errors exit non-zero; informational notes and prompts go to stderr,
  results to stdout. **Export them** — `ccx` does not read `.env` files, so a
  job that keeps its token in a repo `.env` gets `401`s.
- **Token** — use a dedicated API token for the automation; machines keep using
  tokens even when humans sign in via SSO.
- **Container option** — for sandboxes without Python, a small `ccx` image is a
  possible future add (track via the release docs).
- **Structured output** — machine-readable (`--json`) output is planned so agents
  don't parse formatted text; until then, prefer the MCP path below for agents.

## MCP integration

The query server exposes an **MCP** (Model Context Protocol) server over the same
query service, so a coding agent or MCP-capable IDE calls the tools **natively** —
no CLI install, no output parsing. This is the recommended path for agents; the
CLI remains the path for humans and shell scripts. The MCP tools track the CLI
and REST API closely (same capabilities, same scoping).

- **Endpoint:** `<CCX_SERVER_URL>/mcp` (Streamable HTTP).
- **Auth:** the same API token, sent as `Authorization: Bearer <CCX_API_TOKEN>`.
- **Tools** (`git_ref` is a branch/tag name or `heads/<b>` / `tags/<t>`;
  omitted → the repo's default branch, and responses report the resolved ref):
  - `list_repos(limit?, cursor?)` → the accessible indexed repos (stable
    `repo_key` uid + alias + default branch), as a cursor walk — the
    discovery call before a search.
  - `code_search(query, repos, top_k?, offset?, paths?, languages?)` → one
    cross-repo-ranked list of code chunks (repo, filename, line range, code,
    score). `repos` is 1..10 scopes `{repo, git_ref?}` — each repo searched
    at its own ref; `resolved_scopes` reports every scope's resolution.
  - `code_grep(pattern, language, repo, git_ref?, paths?, limit?, offset?)` → AST
    structural matches (filename, line range, node kind, code, captured metavars).
  - `find_definitions(name, repo, qualified?, git_ref?, kinds?, languages?, paths?,
    limit?, offset?)` → where a symbol is defined (path, span, kind, qualified
    name, `entity_id`); the response's `coverage` states how complete the symbol
    index is for the ref.
  - `find_references(repo, path?+entity_id?|base_name, git_ref?, roles?,
    include_unresolved?, limit?, offset?)` → where a symbol is used — exact
    target (`path` + `entity_id` from `find_definitions`) or by `base_name`;
    rows carry `resolution` (`resolved` / `ambiguous` / `name_only`) and a
    reference role (`roles` filters on those, a different vocabulary from
    `find_definitions.kinds`), plus the same `coverage`.
  - `read_file(repo, path, git_ref?, offset?, limit?)` → a file's line window.
  - `find_files(repo, git_ref?, patterns?, case?, limit?, offset?)` → matching paths.
  - `list_git_refs(repo)` → the repo's indexed refs + each ref's commit sha, and
    the default branch.
  - `query_codebase(question, repos, include_stats?)` → a written,
    citation-backed answer to a natural-language question — the MCP form of
    [`ccx query`](#ccx-query--ask-a-question-get-an-answer).
    A server-side agent investigates with the tools above under the caller's
    own permissions and returns a Markdown answer.
    The tool is always advertised, but **fails with `agent_query_unavailable`
    unless the deployment enables the feature** (answering sends the question
    and the code read to a model provider). It also runs far longer than the
    other tools — up to the agentic deadline, 600 s by default — so give the
    client a generous timeout. Prefer it for open-ended "how/why" questions
    and the typed tools above for targeted lookups. By default the response
    carries the answer and the resolved scopes only; `include_stats: true`
    adds the usage and cache-savings counters, which are operator
    information a querying agent rarely needs.

Most clients take a remote HTTP MCP server with custom headers, e.g.:

```jsonc
{
  "mcpServers": {
    "cocoindex-code-plus": {
      "type": "http",
      "url": "https://ccx.example.com/mcp",
      "headers": { "Authorization": "Bearer <CCX_API_TOKEN>" }
    }
  }
}
```

Or with the Claude Code CLI:

```bash
claude mcp add --transport http cocoindex-code-plus https://ccx.example.com/mcp \
  --header "Authorization: Bearer <CCX_API_TOKEN>"
```

(Client config formats vary; the essentials are the `/mcp` URL + the bearer
header.) Token auth works on every deployment. On SSO (OIDC) deployments an
MCP client that supports OAuth can instead sign in interactively — the server
advertises standard protected-resource metadata; your IdP admin pre-registers
each approved MCP client. (Exception: Entra-direct deployments cannot serve
interactive MCP sign-in — [sso.md → Entra ID](sso.md#entra-id); key records
still work there.)
