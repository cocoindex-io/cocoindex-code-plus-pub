# CocoIndex Code Plus — Public Docs

Public, user-facing documentation for **CocoIndex Code Plus** — a self-hosted
semantic + structural code search service (indexer + query server) with a `ccx`
CLI and an MCP endpoint.

## Guides

- **[docs/deploy.md](docs/deploy.md)** — deploy the backend (indexer + query
  server) on Kubernetes with the `cocoindex-code-plus` Helm chart. For platform /
  IT teams.
- **[docs/cli.md](docs/cli.md)** — install and use the `ccx` CLI (and the MCP
  integration) to query an indexed codebase. For engineers and coding agents.

## About

CocoIndex Code Plus is built on [CocoIndex](https://cocoindex.io), the real-time
data transformation framework for AI.

This repository is consumed as a Git submodule (mounted at `pub/`) of the product
repository; edits made here flow back upstream.
