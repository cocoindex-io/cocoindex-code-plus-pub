# Security Policy

This is the canonical security policy for **CocoIndex Code Plus** (it is also
vendored into the product repositories via the `pub` submodule).

## Reporting a vulnerability

Email **security@cocoindex.io** — please do not open public issues.
Process, response SLAs, and disclosure terms are defined in the
[CocoIndex organization security policy](https://github.com/cocoindex-io/.github/blob/main/SECURITY.md).

## Scope

CocoIndex Code Plus and its distribution channels:

- PyPI package `cocoindex-code-plus` (the `ccx` CLI)
- Container images `ghcr.io/cocoindex-io/ccx-query-server` and
  `ghcr.io/cocoindex-io/ccx-indexer`
- The Helm chart (OCI) and the licensed `cocoindex-plus` engine wheels

## Supported versions

Security fixes land in the latest release; upgrade to the newest version to
receive them.

## Verifying releases

Container images are signed with Sigstore cosign (keyless OIDC) and carry
SBOM and build-provenance attestations; the Helm chart is cosign-signed; the
CLI is published to PyPI via Trusted Publishing.
