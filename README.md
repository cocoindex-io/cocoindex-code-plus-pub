# CocoIndex Code Plus — Public Docs

Public, user-facing documentation for **CocoIndex Code Plus** — a self-hosted
code search & navigation service (semantic search, AST structural grep, symbol
definitions/references; indexer + query server) with a `ccx` CLI and an MCP
endpoint.

## Guides

- **[docs/deploy.md](docs/deploy.md)** — deploy the backend (indexer + query
  server) on Kubernetes with the
  [`cocoindex-code-plus` Helm chart](https://github.com/orgs/cocoindex-io/packages/container/package/charts%2Fcocoindex-code-plus)
  (public; released versions listed there). For platform / IT teams.
- **[docs/upgrade.md](docs/upgrade.md)** — upgrade a running deployment
  between releases: the normal one-command upgrade, and an entry for every
  release that needs anything more. For platform / IT teams.
- **[docs/sso.md](docs/sso.md)** — SSO sign-in (OIDC) provider setup: which
  role your provider can play (authorization server vs login-only), and the
  per-provider recipes — Entra ID, Okta, Keycloak (direct or fronting
  Google Workspace, Okta without its API Access Management add-on, or SAML-only IdPs) — each ending in the
  Helm values it produces. For IdP admins and the platform engineer pairing
  with them.
- **[docs/cli.md](docs/cli.md)** — install and use the `ccx` CLI (and the MCP
  integration) to query an indexed codebase. For engineers and coding agents.
- **[docs/security.md](docs/security.md)** — security & deployment guide:
  architecture and trust model, the complete egress list and air-gap recipe,
  hardening checklist, audit-log formats, supply-chain verification, AI/ML
  data handling. For security teams.

## Agent skill

- **[skills/ccx/SKILL.md](skills/ccx/SKILL.md)** — a Claude Code / Agent skill that
  teaches an agent to drive the `ccx` CLI (semantic search, AST `grep`, symbol
  `defs`/`refs` navigation, file access), with a full
  [grep pattern-syntax reference](skills/ccx/references/grep-syntax.md).

## About

CocoIndex Code Plus is built on [CocoIndex](https://cocoindex.io), the real-time
data transformation framework for AI.

This repository is consumed as a Git submodule (mounted at `pub/`) of the product
repository; edits made here flow back upstream.
