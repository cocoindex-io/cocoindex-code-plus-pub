# ccx — When a command fails: diagnose, then hand back

`ccx` is a thin HTTP client; the query server, its index, and every credential
are set up by the user's platform team. When a command fails for a reason other
than its query, the fix is almost always the user's — this file says which, so
you can tell them precisely.

## What the client needs

- **Which server.** `--server <url>` on the command, else `CCX_SERVER_URL`, else
  the saved default. `ccx config` shows what is in force (local only, never a
  network call). `ccx` never reads `.env` files, so a project `.env` cannot
  re-point it.
- **Which credential.** A cached SSO login (`ccx login`, a browser flow the human
  runs once; refreshed automatically) or `CCX_API_TOKEN` (issued by the platform
  team; what CI and headless agents use — in a human's session an agent usually
  rides their cached login). `ccx status` probes the server with no
  credential, then names the credential the next request would use — it
  describes it, it does not test it; a wrong token is caught by the first real
  query (`HTTP 401`).

**None of this is yours to invent.** If the server URL, a token, or a login is
missing or expired, stop and tell the user which one — the server URL to export,
the token to set in their environment, or `ccx login` to run. Never guess a
value, and never ask for a token to be pasted into the conversation.

## Symptom → what to tell the user

| Symptom | Cause | What to do |
|---|---|---|
| `command not found: ccx` | not installed / not on PATH | ask the user to install it: `uv tool install cocoindex-code-plus` |
| `Query server unreachable at <url>` | wrong server URL or saved default, server down, a dropped `kubectl port-forward` | `ccx config` shows the URL in use; the user confirms it or re-establishes the tunnel |
| `No query server configured` (or a prompt for one) | no `--server`, no `CCX_SERVER_URL`, no saved default | ask the user for the server URL |
| `expired and could not be refreshed` (the login line of `ccx status`, or `Your login for <url> has expired …` from any other command) | the cached SSO login aged out (an overnight gap can do it); the server itself is fine | the user runs `ccx login` again, or `ccx logout` to fall back to `CCX_API_TOKEN` |
| `HTTP 401` | missing or invalid `CCX_API_TOKEN` | the user sets a valid token |
| `HTTP 503` `index tables … do not exist yet` (or `symbol tables …`, from `defs`/`refs`) | the server-side indexer hasn't populated this deployment yet | server state the CLI can't fix — tell the user. A different ref does not help; an unknown ref is a separate error that lists the indexed refs |
| a connection error from a sandbox that blocks outbound network | `ccx` must reach the server (and the IdP, on a cached login) | ask the user to allow network for the sandbox |
| `agent_query_unavailable` (from `ccx ask`) | the deployment hasn't enabled agentic query (off by default: answering sends code to a model provider) | answer with `search`/`grep`/`defs`/`refs`; tell the user their platform team decides; don't retry this session |
| `agent_query_busy`, or `HTTP 503` `Request deadline exceeded` (from `ccx ask`) | the server is at its concurrent agentic-query cap, or the investigation outran the server's deadline | fall back to the other commands for this question; at most one later retry, never a loop |

The **indexer is server-side**: no CLI command builds or refreshes an index.
"Stale" or "missing ref" is resolved on the server; `ccx git-refs` shows which
refs are indexed and at which commit.

## MCP

The same query server exposes an MCP endpoint at `<CCX_SERVER_URL>/mcp` with
tools at parity with the CLI: `code_search`, `code_grep`, `find_definitions`,
`find_references`, `read_file`, `find_files`, `list_git_refs`, `list_repos`, and
`ask_codebase` (= `ccx ask`; always advertised, failing with
`agent_query_unavailable` unless the deployment enables it). There is no
checkout auto-detection: every tool names its repo, and an omitted `git_ref`
means the repo's default branch (bare branch/tag names work). If your session
already has these tools, use them directly — same index, same results.
Registering the endpoint is the human's step:
<https://github.com/cocoindex-io/cocoindex-code-plus-pub/blob/main/docs/cli.md#mcp-integration>.
