# ccx — Install, Configure, Troubleshoot

`ccx` is a lightweight HTTP client (no index, no license, no local daemon). All it
needs is to reach a query server.

## Installation

Published to **public PyPI**. Install as an isolated tool so it lands on `PATH`:

```bash
uv tool install cocoindex-code-plus     # recommended
# or: pipx install cocoindex-code-plus
# or: pip install cocoindex-code-plus
ccx version
```

For CI/automation, pin a version (`cocoindex-code-plus==X.Y.Z`) and keep it roughly in
step with the query server you target — the CLI warns on a server version mismatch.

To upgrade:

```bash
uv tool upgrade cocoindex-code-plus      # or: pipx upgrade cocoindex-code-plus
```

## Configuration

Two environment variables, or a `.env` found from the working directory upward
(auto-loaded, non-overriding — values already in the shell win):

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server's base URL (e.g. `https://ccx.example.com`, or `http://127.0.0.1:8080` over a `kubectl port-forward`) |
| `CCX_API_TOKEN` | the API token; sent as `Authorization: Bearer` (the server runs `auth.mode: apiKey`) |

```bash
export CCX_SERVER_URL=https://ccx.example.com
export CCX_API_TOKEN=<your-token>
ccx status        # confirm reachable + healthy
```

`--server <url>` overrides `CCX_SERVER_URL` per command. There is no flag for the
token — it comes from the environment/`.env`.

**The token and URL are the user's to provide.** If they're unset, do not invent
them — ask the user for the server URL and an API token (a dedicated token for
automation is fine and stays valid for machines).

## Verifying / health

```bash
ccx status        # server status, URL, version, uptime
ccx version       # just the CLI version
```

`ccx status` is the first thing to run in a new environment — but it checks
**reachability only**: the server's health endpoint is auth-exempt, so `status`
passes even with a missing or wrong token. The first real query (e.g. a `ccx
search`) is what confirms auth — a bad token returns `HTTP 401`.

## Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| `command not found: ccx` | not installed / not on PATH | install (above); re-open the shell |
| `Query server unreachable at <url>` | wrong/empty `CCX_SERVER_URL`, server down, network/port-forward dropped | check the URL; re-establish `kubectl port-forward`; confirm with the user |
| `HTTP 401` | missing/invalid `CCX_API_TOKEN` (`ccx status` does **not** catch this — health is auth-exempt) | set a valid token (the server may accept several for rotation) |
| `HTTP 503` "index not built yet" | the server-side indexer hasn't populated this repo/ref yet | this is server state the CLI can't fix — retry later, or pick an indexed ref (`ccx repositories`) |
| `No results.` / `No matches.` | query/pattern found nothing | for `search`, rephrase or raise `-k`/`--offset`; for `grep`, re-check [grep-syntax.md](grep-syntax.md) gotchas |
| server version mismatch warning | CLI and server versions drifted | upgrade the CLI (or pin to the server's version) |

Remember the division of responsibility: the **indexer is server-side**. The CLI never
builds or refreshes an index — "stale" or "missing ref" issues are resolved on the
server, not by re-running a CLI command. Use `ccx repositories` to see exactly which
refs (and commit SHAs) are currently indexed.

## MCP

The same query server exposes an **MCP** (Model Context Protocol) endpoint at
`<CCX_SERVER_URL>/mcp` (Streamable HTTP), with tools kept at **parity** with the CLI
(`code_search`, `code_grep`, `read_file`, `find_files`, `repositories` — `git_ref`
is optional everywhere and takes bare branch/tag names, resolved to the repo's
default like the CLI). For MCP-capable
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
