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

Two environment variables (or a `.env` found from the working directory upward,
auto-loaded — already-exported vars take precedence):

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server's URL (e.g. `https://ccx.example.com`, or `http://127.0.0.1:8080` via `kubectl port-forward`) |
| `CCX_API_TOKEN` | your API token — your platform team issues it (one of the server's configured tokens); sent as `Authorization: Bearer` |

```bash
export CCX_SERVER_URL=https://ccx.example.com
export CCX_API_TOKEN=<your-token>
ccx status        # checks the server is reachable + healthy
```

`ccx status` checks **reachability only** — the server's `/health` is auth-exempt,
so it passes even with a missing or wrong token. Your first `ccx search` is what
confirms auth (a bad token returns `HTTP 401`; see [Troubleshooting](#troubleshooting)).

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

# File access (ref-scoped; repo + ref auto-detected like search)
ccx read-file README.md                          # print a file's contents
ccx read-file src/app.py --offset 40 --limit 20  # 20 lines from line 40 (--offset = 1-based line)
ccx find-files "*.py"                            # list files by glob
ccx find-files --git-ref main                    # list all files, on a specific ref

# Repo / ref metadata
ccx repositories                                # the current repo's indexed refs + commit shas
ccx repositories cocoindex-io/cocoindex          # a specific repo ("(default)" marks the default branch)
```

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
know which ref answered. `ccx repositories` lists what's indexed.

Similarly, when you run `search` or `grep` from a **subdirectory** of the
checkout (and gave no `--path`), results are scoped to that subtree — the note
on stderr names the glob; run from the repo root or pass `--path '*'` to cover
the whole repo.

`--offset` differs by command: for `read-file` it's a **1-based line number**; for
`grep` and `find-files` it's a **skip count** for paginating results.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HTTP 401` | Missing or wrong `CCX_API_TOKEN` — it must match a token the server accepts. `ccx status` won't catch this (`/health` is auth-exempt). |
| `HTTP 503` | Index not built yet — the indexer hasn't populated the table; retry once it has (ask your platform team if it persists). |
| connection refused / unreachable | Wrong `CCX_SERVER_URL`, or a `kubectl port-forward` that dropped. |
| version-mismatch warning | Align `ccx` with the server: `uv tool install cocoindex-code-plus==X.Y.Z`. |

## For agents & automation

- **No interactive setup** — everything is env-driven (`CCX_SERVER_URL`,
  `CCX_API_TOKEN`), so a coding agent or CI job can run `ccx` directly. Errors
  exit non-zero; informational notes go to stderr, results to stdout.
- **Token** — use a dedicated API token for the automation; it stays valid for
  machines even after interactive SSO login lands for humans.
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
  - `read_file(repo, path, git_ref?, offset?, limit?)` → a file's line window.
  - `find_files(repo, git_ref?, patterns?, case?, limit?, offset?)` → matching paths.
  - `repositories(repo)` → the repo's indexed refs + each ref's commit sha, and
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
header.) Token-based MCP auth is the current model; OAuth/SSO for MCP is on the
roadmap.
