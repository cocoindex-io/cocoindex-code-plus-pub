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

Pin a version for CI/automation (`cocoindex-code-plus==X.Y.Z`); keep it in step
with the query server you target (the CLI warns on a server version mismatch).

## Configure

Run interactively, `ccx` asks for anything it's missing **once** and saves
the answer (`~/.config/ccx/`; `%APPDATA%\ccx` on Windows) — so a human's
setup is just `ccx login` (SSO) or `ccx status` (token deployments). The
environment variables below always **override** the saved answers and are
the way to configure scripts, CI, and agents (also loadable from a `.env`
found upward from the working directory — already-exported vars win):

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server's URL (e.g. `https://ccx.example.com`, or `http://127.0.0.1:8080` via `kubectl port-forward`). Optional interactively: prompted once and saved as your default; a one-off `--server` overrides without changing the default |
| `CCX_API_TOKEN` | your API token — your platform team issues it (one of the server's configured tokens); sent as `Authorization: Bearer`. On an SSO deployment humans skip this and run `ccx login` instead (below) |
| `CCX_CLIENT_TIMEOUT_SECONDS` | optional; per-request client timeout, default **90** — deliberately above the server's own deadline chain so the server's clearer error arrives instead of a client-side cutoff. Keep it above the ingress timeout if your platform team raised the server deadline |

```bash
export CCX_SERVER_URL=https://ccx.example.com   # optional in a terminal (prompted + saved)
export CCX_API_TOKEN=<your-token>               # token deployments only
ccx status        # checks the server is reachable + healthy, and names the server it resolved
```

`ccx status` checks **reachability only** — the server's `/health` is auth-exempt,
so it passes even with a missing or wrong token. Your first `ccx search` is what
confirms auth (a bad token returns `HTTP 401`; see [Troubleshooting](#troubleshooting)).

**SSO deployments (OIDC).** If your platform team enabled company-IdP sign-in,
skip `CCX_API_TOKEN` and sign in once:

```bash
ccx login            # opens your IdP in the browser (PKCE, MFA and all)
ccx login --device   # device-code flow instead (no local browser, e.g. over SSH)
ccx logout           # drops the cached token
```

The first login needs the OAuth client id your admin provides — you're
prompted for it in a terminal (or pass `--client-id` / set
`CCX_OIDC_CLIENT_ID`); it's remembered per server afterwards, and `ccx login`
also makes that server your saved default (with a printed notice). The token
is cached and refreshed automatically. CI jobs and agents keep using
`CCX_API_TOKEN` — on SSO deployments that's an issued key of the form
`ccxk_<id>_<secret>`.

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
```

`ccx git-refs` lists **git** refs (branches and tags) — not to be confused with
`ccx refs`, which finds where a *symbol* is used.

**Symbol navigation** (`ccx defs` / `ccx refs`) answers "where is this defined"
and "who uses it" from a **resolved symbol graph** the indexer builds — cross-file,
alias- and re-export-aware — not from text matching. It covers **Python,
TypeScript/JavaScript (incl. TSX), and C/C++**; other languages remain reachable
via `search` and `grep`. The two verbs chain: each `ccx defs` row ends with a
paste-ready command —

```
src/db.py:42:4 [method] python:db.Repo.find
  lang=python  uses: ccx refs src/db.py Repo.find
```

— and running that `uses: …` command returns exactly that definition's uses
(it carries any `--repo`/`--git-ref`/`--server` flags you passed, so it
re-queries the same scope). Three precisions of `ccx refs`, broad to exact: a
bare `ccx refs NAME` casts a wide net by unqualified name; the headline's
**qualified name** (`python:db.Repo.find` — every qualified name opens with
its language tag, `python:` / `tsjs:` / `cpp:`, and TS/JS names carry a
second `:` between the file path and the entity) matches exactly, covering
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

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HTTP 401` | Missing or wrong `CCX_API_TOKEN` — it must match a token the server accepts. `ccx status` won't catch this (`/health` is auth-exempt). |
| `HTTP 503` | Index not built yet — the indexer hasn't populated the table; retry once it has (ask your platform team if it persists). |
| connection refused / unreachable | Wrong `CCX_SERVER_URL`, or a `kubectl port-forward` that dropped. |
| version-mismatch warning | Align `ccx` with the server: `uv tool install cocoindex-code-plus==X.Y.Z`. |

## For agents & automation

- **Nothing requires a terminal** — set `CCX_SERVER_URL` + `CCX_API_TOKEN` and
  a coding agent or CI job runs `ccx` directly; prompts only ever appear on a
  TTY (without one, a missing setting is a non-zero exit with the flags to
  pass). Errors exit non-zero; informational notes and prompts go to stderr,
  results to stdout.
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
each approved MCP client.
