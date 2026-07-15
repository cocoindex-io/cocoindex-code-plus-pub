# Security Policy

This is the canonical security policy for **CocoIndex Code Plus** (it is also
vendored into the product repositories via the `pub` submodule).

## Reporting a vulnerability

Email **security@cocoindex.io**. Please do not open public issues for
security reports.

- We acknowledge reports within **3 business days**.
- We prefer coordinated disclosure: we'll work with you on a fix and agree
  on a disclosure timeline before details are published.
- There is currently no bug bounty program; we gladly credit reporters in
  the fix-release advisory unless you prefer otherwise.

## Scope

CocoIndex Code Plus and its distribution channels:

- PyPI package `cocoindex-code-plus` (the `ccx` CLI)
- Container images `ghcr.io/cocoindex-io/ccx-query-server` and
  `ghcr.io/cocoindex-io/ccx-indexer`
- The Helm chart (OCI) and the licensed `cocoindex-plus` engine wheels

For the open-source CocoIndex project, see the security policy in the
[`cocoindex-io/cocoindex`](https://github.com/cocoindex-io/cocoindex)
repository.

## Supported versions

Security fixes land in the latest release; upgrade to the newest version to
receive them.

## Verifying releases

Container images are signed with Sigstore cosign (keyless OIDC) and carry
SBOM and build-provenance attestations; the Helm chart is cosign-signed; the
CLI is published to PyPI via Trusted Publishing.
