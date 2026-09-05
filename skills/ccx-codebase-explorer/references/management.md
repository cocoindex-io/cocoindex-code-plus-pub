# ccx — Install, Configure, Troubleshoot

`ccx` is a lightweight HTTP client (no index, no license, no local daemon). All it
needs is to reach a query server.

## Installation

Published to **public PyPI**. Install as an isolated tool so it lands on `PATH`:

```bash
uv tool install cocoindex-code-plus     # recommended
# or: pipx install cocoindex-code-plus
# or: pip install cocoindex-code-plus
ccx version                             # also: ccx --version
```

For CI/automation, pin a version (`cocoindex-code-plus==X.Y.Z`) and keep it roughly in
step with the query server you target — the CLI warns on a server version mismatch.

To upgrade:

```bash
uv tool upgrade cocoindex-code-plus      # or: pipx upgrade cocoindex-code-plus
```

## Configuration

Two things: **which server**, and **which credential**. `ccx config` shows what is
in force (local only, never a network call) — run it first when a command fails
unexpectedly.

**Server.** Resolved in this order: `--server <url>` on the command, then
`CCX_SERVER_URL`, then the saved default (`~/.config/ccx/config.json`, written by
`ccx login` or by a one-time prompt in a terminal; change it with
`ccx config set server <url>`). `ccx` does **not** read `.env` files — a project
`.env` cannot re-point it; export the variable instead.

**Credential.** Two kinds; the deployment decides which applies:

- **SSO deployments (OIDC):** the human runs `ccx login` once (browser flow;
  `ccx login --device` on a host without a browser prints a URL + code to
  visit). The token is cached and refreshed automatically; `ccx logout` drops
  it. When `ccx` reports the login **expired and could not be refreshed**, the
  fix is `ccx login` again — the refresh lifetime is the deployment's IdP
  policy, so a long gap can need it.
- **Token deployments, CI and agents:** export `CCX_API_TOKEN` — a token the
  platform team issues (on SSO deployments an issued key `ccxk_<id>_<secret>`),
  sent as `Authorization: Bearer`. A cached login, when present, takes
  precedence over the variable; `ccx logout` falls back to it.

```bash
export CCX_SERVER_URL=https://ccx.example.com   # optional once a default is saved
export CCX_API_TOKEN=<your-token>               # token deployments / automation only
ccx status        # reachable + healthy, then the credential the next request would use
```

**None of this is yours to invent.** If the server URL, a token, or a login is
missing or expired, stop and tell the user exactly which one — ask for the URL
and a token, or ask them to run `ccx login` — never guess a value.

## Verifying / health

```bash
ccx status        # server status, URL, version, uptime — then the credential line
ccx config        # what would be used: server, client id, token cache, file paths
ccx version       # just the CLI version
```

Use `ccx status` when **diagnosing** — a query failed, or you're bringing up a new
environment. It's not a pre-flight step for normal use (just run your query). It
reports **two facts, separately**, and its exit code follows the first:

- **Server** (`Query server: healthy`, url, version, uptime) — probed with no
  credential, since the health endpoint is auth-exempt. Unreachable → exit 1.
- **Credential** — the last line names what the next request would use:
  `login: cached for <url>, valid (refreshes automatically)`, `login: expired
  and could not be refreshed … — run ccx login`, `token: CCX_API_TOKEN set`, or
  `credential: none — run ccx login or export CCX_API_TOKEN`. A warning here
  still exits 0 — the server is up; the credential is the user's to fix.

The credential line is **described, not tested**: a missing or wrong
`CCX_API_TOKEN` still passes `status`, and the first real query (`ccx search …`)
is what confirms auth (`HTTP 401`). CLIs before 0.1.41 print no credential line
and fail `status` outright on an expired login.

## Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `command not found: ccx` | not installed / not on PATH | install (above); re-open the shell |
| `Query server unreachable at <url>` | wrong `CCX_SERVER_URL` / saved default, server down, network or port-forward dropped | check `ccx config` for the URL in use; re-establish `kubectl port-forward`; confirm with the user |
| prompted for a server, or told to run `ccx login` / `ccx config set server` | no `--server`, no `CCX_SERVER_URL`, no saved default | ask the user for the server URL |
| `login: expired and could not be refreshed` in `ccx status`, or `Your login for <url> has expired and could not be refreshed` from any other command | the cached SSO login aged out (the IdP's session lifetime — an overnight gap can do it); the server itself is healthy | the user runs `ccx login` again (or `ccx logout` to fall back to `CCX_API_TOKEN`) — never guess a token |
| `HTTP 401` | missing/invalid `CCX_API_TOKEN` (`ccx status` names the credential in use but does **not** validate it) | set a valid token (the server may accept several for rotation) |
| `HTTP 503` "index not built yet" | the server-side indexer hasn't populated this repo/ref yet | this is server state the CLI can't fix — retry later, or pick an indexed ref (`ccx git-refs`) |
| `agent_query_unavailable` (from `ccx query`) | the deployment hasn't enabled agentic query — off by default, because answering sends code to a model provider | server config the CLI can't change: answer with `search`/`grep`/`defs`/`refs` instead, and tell the user their platform team decides |
| `agent_query_busy` / `deadline_exceeded` (from `ccx query`) | the server is at its concurrent agentic-query cap, or the investigation outran the server's deadline | fall back to the other commands for this question; one later retry of a `busy` is fine, a retry loop is not |
| `No results.` / `No matches.` | query/pattern found nothing | for `search`, rephrase or raise `-k`/`--offset`; for `grep`, re-check [grep-syntax.md](grep-syntax.md) gotchas |
| server version mismatch warning | CLI and server versions drifted | `uv tool upgrade cocoindex-code-plus` (or pin to the server's version) |

Remember the division of responsibility: the **indexer is server-side**. The CLI never
builds or refreshes an index — "stale" or "missing ref" issues are resolved on the
server, not by re-running a CLI command. Use `ccx git-refs` to see exactly which
refs (and commit SHAs) are currently indexed.

## MCP

The same query server exposes an **MCP** (Model Context Protocol) endpoint at
`<CCX_SERVER_URL>/mcp` (Streamable HTTP), with tools kept at **parity** with the CLI
(`code_search`, `code_grep`, `find_definitions`, `find_references`, `read_file`,
`find_files`, `list_git_refs`, `list_repos`, and `query_codebase` — the MCP form of
`ccx query`, always advertised but failing with `agent_query_unavailable` unless
the deployment enables it. `git_ref` is optional everywhere and takes bare
branch/tag names, resolved to the repo's default like the CLI). For MCP-capable
agents this is the preferred path — native tool calls, no CLI install, no output
parsing. Auth uses the same bearer token.

Register it with most clients via an HTTP MCP server entry with a custom header:

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

The CLI remains the path for humans and shell scripts; MCP is the agent-native path.
Both go through the same query service, so results and scoping are identical.
