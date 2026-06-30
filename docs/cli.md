# The `ccx` CLI (and MCP)

`ccx` is the client engineers and coding agents use to **query** an indexed
codebase from a workstation, CI, or an agent sandbox. It talks to a query server
that your platform team has deployed ([deploy.md](deploy.md)); the CLI itself
holds no index and needs no license.

## Install

`ccx` is published to **public PyPI** (license-free client). Install it as an
isolated tool so it's on your `PATH`:

```bash
uv tool install cocoindex-code-plus     # recommended
# or: pipx install cocoindex-code-plus
# or: pip install cocoindex-code-plus
ccx version
```

Pin a version for CI/automation (`cocoindex-code-plus==X.Y.Z`); keep it in step
with the query server you target (the CLI warns on a server version mismatch).

## Configure

Two environment variables (or a `.env` in the working directory, auto-loaded):

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server's URL (e.g. `https://ccx.example.com`, or `http://127.0.0.1:8080` via `kubectl port-forward`) |
| `CCX_API_TOKEN` | your API token (the server runs `auth.mode: apiKey`); sent as `Authorization: Bearer` |

```bash
export CCX_SERVER_URL=https://ccx.example.com
export CCX_API_TOKEN=<your-token>
ccx status        # checks the server is reachable + healthy
```

## Use

```bash
# Semantic search
ccx search "how are vector embeddings stored"   # auto-scopes to the current repo
ccx search "rate limiter" --all-repos           # search every indexed repo
ccx search foo --repo cocoindex-io/cocoindex     # a specific repo
ccx search foo --repo my/repo --git-ref heads/main   # a specific indexed ref
ccx search foo -k 10                             # more results

# AST structural grep (matches the syntax tree, not text; ref-scoped, needs -l/--language)
ccx grep 'def \NAME(\(ARGS*\)):' -l python --git-ref heads/main   # every Python function def
ccx grep 'foo(\X)' -l python --git-ref heads/main                 # calls to foo (captures \X)
ccx grep 'isinstance(\X, \Y)' -l python --git-ref heads/main --path 'src/*.py'

# File access (ref-scoped — needs --git-ref; repo auto-detected like search)
ccx read-file README.md --git-ref heads/main            # print a file's contents
ccx read-file src/app.py --git-ref heads/main --offset 40 --limit 20   # a line window
ccx find-files "*.py" --git-ref heads/main              # list files by glob
ccx find-files --git-ref heads/main                     # list all files

# Repo / ref metadata
ccx repositories                                # the current repo's indexed refs + commit shas
ccx repositories cocoindex-io/cocoindex          # a specific repo
```

`ccx search`, `read-file`, and `find-files` filter to the repo of the current git
checkout (detected from its `origin` GitHub/GitLab remote); `--repo <owner>/<repo>`
targets another (and `search` also takes `--all-repos`). The file commands are
**ref-scoped**, so they require `--git-ref` (`heads/<branch>` / `tags/<tag>`).
Before the indexer has populated the index, commands return a clear "index not
built yet" message.

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
CLI remains the path for humans and shell scripts. The MCP tools are kept at
**parity** with the CLI and REST API (same capabilities, same scoping).

- **Endpoint:** `<CCX_SERVER_URL>/mcp` (Streamable HTTP).
- **Auth:** the same API token, sent as `Authorization: Bearer <CCX_API_TOKEN>`.
- **Tools:**
  - `code_search(query, top_k?, offset?, repo?, git_ref?, paths?)` → ranked code
    chunks (repo, filename, line range, code, score).
  - `code_grep(pattern, language, repo, git_ref, paths?, limit?, offset?)` → AST
    structural matches (filename, line range, node kind, code, captured metavars).
  - `read_file(repo, git_ref, path, offset?, limit?)` → a file's line window.
  - `find_files(repo, git_ref, patterns?, case?, limit?, offset?)` → matching paths.
  - `repositories(repo)` → the repo's indexed refs + each ref's commit sha.

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
