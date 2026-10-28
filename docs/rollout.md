# Rolling `ccx` out to your developers

For platform teams: how developers' `ccx` CLI, agent skill and Claude Code
plugin stay current with your deployment, and what you can set so they do
without an announcement. The server side is in [deploy.md](deploy.md); a
developer's own view is in [cli.md](cli.md).

## What keeps each piece current

Each piece reports itself, and every report names the command that fixes it.
A developer at a terminal pastes the command; a coding agent runs it, and its
host asks the developer to approve it first.

| Piece | How it updates | What tells the developer or agent | What you can enforce |
|---|---|---|---|
| `ccx` CLI | reinstall at your server's release | every command of an older CLI ends with one line naming the install command (once a day); the skill's check and the plugin tell the agent once per session | the server refuses a CLI older than the oldest it speaks to (`HTTP 426`); you can raise that floor |
| Agent skill (skills CLI) | `npx -y skills update ccx-codebase-explorer -g` | the skill's first step, `ccx skill-check`, tells the agent once per session | — |
| Claude Code plugin | marketplace update; automatic once auto-update is on | the plugin's hook tells the agent once per session, and warns the developer once a day | managed settings install it and turn auto-update on for everyone |

The CLI and the server release in lockstep. The command a line names pins
your server's release, never the newest on PyPI.

## The server-side values

Two optional chart values, under `queryServer.cli`:

```yaml
queryServer:
  cli:
    # The command every upgrade line names; {version} becomes the release.
    installCommand: "uv tool install --index-url https://pypi.corp.example/simple 'cocoindex-code-plus=={version}'"
    # The oldest ccx release this deployment accepts.
    minVersion: "0.1.82"
```

- **`installCommand`** is for developers who install `ccx` from somewhere
  other than public PyPI — a private package index, an internal tool. Leave it
  empty and each CLI names the command that matches how it was installed
  (`uv tool`, `pipx` or `pip`), which uses the installer's own index
  configuration. `/health` serves the command to anyone, so the server
  refuses to start on one that carries a credential in a URL: give the index
  credential to the installer's own configuration (`uv.toml`, `pip.conf`, a
  keyring) instead.
- **`minVersion`** raises the oldest CLI the server accepts. Every release
  already refuses the CLIs it can no longer speak to; this value can only
  raise that floor, never lower it, and may not be newer than the server's
  own release. A refused CLI gets `HTTP 426` naming the install command, on
  every route except `/health`, the OAuth metadata and `/openapi.json`. MCP
  clients are never refused.
- **Raise the floor after a release has settled**, not with it: once
  Insights shows most CLI requests on the new release, the rest are refused
  with the command that brings them over. A CI job or script pinned below
  the floor fails until its pin moves.

## Claude Code: install the plugin for everyone

The plugin bundles the skill and the hooks that tell agents to use `ccx` and
to keep it current. Claude Code's managed settings — the claude.ai admin
console, an MDM profile, or a `managed-settings.json` file — install it on
every machine and keep it updated:

```json
{
  "extraKnownMarketplaces": {
    "ccx": {
      "source": { "source": "github", "repo": "cocoindex-io/cocoindex-code-plus-pub" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "ccx@ccx": true },
  "env": { "CLAUDE_CODE_PLUGIN_PREFER_HTTPS": "1" }
}
```

- **The key `ccx` must match the marketplace's own name.** Claude Code keys a
  marketplace by the name in its catalog; `ccx@ccx` is the plugin in it.
- **`autoUpdate: true`** keeps the plugin current: Claude Code checks the
  marketplace within ten minutes of a session's first message, and the new
  copy loads at `/reload-plugins` or the next session. Auto-update is off by default for a marketplace you add
  yourself, and an admin-set value overrides each developer's own toggle.
  `DISABLE_AUTOUPDATER` in your managed `env` turns it off for every
  marketplace; add `FORCE_AUTOUPDATE_PLUGINS=1` to keep plugin updates while
  Claude Code's own stay off.
- **`CLAUDE_CODE_PLUGIN_PREFER_HTTPS`** clones this public repository over
  HTTPS, so developers without a GitHub SSH key still receive updates.
- **Developers who installed the skill with the skills CLI** should remove
  that copy (`npx skills remove ccx-codebase-explorer -g`) so Claude Code
  lists the skill once.
- **No access to github.com?** Host a copy of this repository on your own
  git host and give the marketplace a `git` source with its URL; keep the
  catalog's name `ccx`.

### Let agents upgrade without a prompt (optional)

By default an agent's upgrade waits for the developer's approval. To approve
it for everyone, add allow rules for the exact commands to the same managed
settings:

```json
{
  "permissions": {
    "allow": [
      "Bash(uv tool install cocoindex-code-plus==*)",
      "Bash(claude plugin update ccx@ccx)"
    ]
  }
}
```

Match the rule to the command your developers' lines name: with
`installCommand` set, allow its prefix up to `{version}` instead; a CLI with
the `keyring` extra names `'cocoindex-code-plus[keyring]==…'`. Claude Code
matches everything before the `*` as written, and checks each part of a
compound command separately, so a rule like these approves the upgrade and
nothing chained to it.

## Codex and other agents

- **Install the skill** on each machine with the skills CLI, which links it
  into Codex, Cursor, Gemini CLI and the other agents it detects:
  `npx skills add cocoindex-io/cocoindex-code-plus-pub -g -y`. Your device
  management can run it.
- **Updates** come through the skill's own first step: the agent runs
  `ccx skill-check` once per session and runs the command it names. Codex's
  default sandbox blocks the network that update and `ccx` itself need;
  [cli.md](cli.md#for-agents--automation) says how to allow it.
- **A Codex plugin with the same hooks is not published yet.** Until it is,
  an agent that skips the skill's first step is told only by a command's
  output line and, below the floor, by the server's refusal.

## Watching the rollout

Insights' **Queries & agents** view has a *CLI versions in use* chart:
requests per `ccx` version, each marked current, behind your server's
release, or refused below the floor, with the share of CLI requests that
came from versions behind ([insights.md](insights.md#the-web-ui-ccx-ui)). A
refused version also shows as `client_too_old` in the errors table, with
the developers it affected.
