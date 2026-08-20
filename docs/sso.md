# SSO sign-in (OIDC): provider setup

This guide is for the people who make your identity provider mint tokens for
CocoIndex Code Plus: the **IdP admin** (app registrations, roles, policies) and
the **platform engineer** pairing with them. Each provider section ends in the
Helm values block its registrations produce (paired with the operator-side
values that live in deploy.md). The server-side
switch, the meaning of each `auth.oidc.*` key, and the config-lane rules live
in [deploy.md → SSO login (OIDC)](deploy.md#sso-login-oidc); the engineer-side
login experience lives in [cli.md](cli.md).

## Two roles: login IdP and authorization server

Every SSO deployment needs two jobs done:

- **Authenticating the person** — the *login IdP*: the sign-in screen your
  users already know, with your MFA and sign-on policies.
- **Minting the API token** — the *authorization server (AS)*: issuing a JWT
  access token for the CCX audience, carrying the entitlement claim the query
  server checks.

Some products do both jobs; some only log people in. **Entra ID, Keycloak,
Auth0, Ping — and Okta *with* its API Access Management add-on — are full
authorization servers**: configure them directly. **Google Workspace, Okta
*without* that add-on, and SAML-only IdPs are login-only.** Why: Google's
OAuth server issues opaque access tokens and cannot mint tokens for a
third-party API (its only JWTs are ID tokens, which this server deliberately
rejects as bearer credentials). Okta's base-tier org server has no custom
audiences, scopes, or claims. SAML speaks no OAuth at all. For those, you compose an
authorization server **you** operate in front — the documented shape is
[Keycloak brokering to your IdP](#keycloak): sign-in stays on your IdP's
screen, Keycloak mints the API tokens, and the server and chart notice nothing
special (`auth.oidc.issuer` simply points at Keycloak).

## Which recipe applies to you

| Your provider | Role it can play | Recipe |
|---|---|---|
| Entra ID | full authorization server | [Entra ID](#entra-id) — but see its MCP-sign-in limitation |
| Okta **with** API Access Management | full authorization server | [Okta](#okta-with-api-access-management) |
| Okta **without** the add-on | login IdP only | [Keycloak in front](#fronting-google-workspace-okta-without-the-add-on-or-a-saml-only-idp) — or add the add-on and use the direct recipe |
| Keycloak | full authorization server (and the documented front) | [Keycloak](#keycloak) |
| Google Workspace | login IdP only | [Keycloak in front](#fronting-google-workspace-okta-without-the-add-on-or-a-saml-only-idp) |
| SAML-only IdP | login IdP only | [Keycloak in front](#fronting-google-workspace-okta-without-the-add-on-or-a-saml-only-idp) |
| Auth0, Ping, another OIDC AS | full authorization server | [Any OIDC authorization server](#any-oidc-authorization-server) |

## What every provider must end up providing

Whatever the provider, the finished setup delivers the same contract — the
per-provider sections below are this list in each vendor's vocabulary:

1. **An API/resource registration** whose identifier (or registration id)
   becomes the token audience — the `auth.oidc.audience` value. It must be
   distinct from every login client and never used to sign in. Tokens must
   carry a **single** audience.
2. **A public CLI client** (PKCE, no secret) — its id goes in
   `auth.oidc.cli.clientId`, and the server advertises it so engineers never
   type it. Its registered redirect URIs must cover the server's advertised
   callback ports (default `http://127.0.0.1:3276/callback` and
   `http://127.0.0.1:3277/callback`); enable the device grant if some
   engineers work on browserless hosts (`ccx login --device`).
3. **The entitlement `ccx.read`, carried in a claim the provider gates per
   user.** This is provider-determined, not a style choice: on Okta the
   access policy grants the *scope* per user/group at mint time (`scp`
   claim); on Entra and Keycloak the per-user primitive is a *role*
   (`roles` claim) — Entra's `scp` is client-wide consent evidence, never
   user entitlement. A token without the entitlement is refused
   `403 insufficient_scope`.
4. **Refresh tokens** where sessions should outlive the ~1-hour access token:
   Okta and Entra issue them only when `offline_access` is requested — put it
   in `auth.oidc.advertisedScopes` so a bare `ccx login` requests it;
   Keycloak refreshes from its own session without it.
5. **Registrations for any interactive MCP clients.** There is no dynamic
   client registration (deliberately — selecting it in the chart config is
   refused at startup), so an MCP client that signs in interactively —
   rather than presenting an API-key record — needs its own pre-registered
   client id.
6. *(Mirrored deployments only)* the access token must carry the claim your
   `authz` `mappingClaim` names (typically `email`), **byte-identical to the
   code-host SSO NameID** — see [Verifying before rollout](#verifying-before-rollout).

For a self-managed provider with a private CA, also hand the platform team
the CA bundle (`auth.oidc.caBundleSecret` in the chart).

---

## Entra ID

**Role & prerequisites.** A full authorization server on every tenant — no
add-on SKU. Decide one thing up front: **MCP clients cannot sign in with
OAuth against an Entra-direct deployment** (the MCP spec requires clients to
send the RFC 8707 `resource` parameter, which Entra's v2 endpoints reject
with `AADSTS901002`). The ccx CLI is unaffected — a chart switch below omits
the parameter — and MCP clients presenting an **API-key record** work fine;
what's blocked is only interactive MCP sign-in. If that matters to you, use
[Keycloak in front](#keycloak) instead; the remedies beyond it are upstream
(Microsoft accepting the parameter, or the MCP spec relaxing the
requirement).

**Your Entra admin registers** (portal: Microsoft Entra ID → App
registrations):

1. **The API registration** (one per environment), e.g. `ccx` with App ID URI
   `api://ccx`. In its **manifest** set `requestedAccessTokenVersion: 2` —
   v1-format tokens carry a different issuer (`sts.windows.net`) and fail
   validation.
2. On that registration, **one delegated scope for token acquisition** —
   Entra's conventional `user_impersonation` is fine. Interactive sign-in
   cannot mint a token without a delegated scope; it carries no entitlement.
3. On the same registration, **the app role `ccx.read`** (member type
   *Users/Groups*) — the entitlement. App-role and scope *values* share one
   namespace per registration, so the role holds the meaningful name and the
   scope stays a throwaway. On the API's **enterprise application**: assign
   the entitled group to the role and enable **"Assignment required?"** so
   unentitled users fail at sign-in instead of receiving tokens the server
   then refuses.
4. **The CLI client registration**, e.g. `ccx-cli`: a public client — enable
   **"Allow public client flows"** (device sign-in). Add its redirect URIs
   through the **manifest** (`replyUrlsWithType`, type `InstalledClient`):
   `http://127.0.0.1:3276/callback` and `http://127.0.0.1:3277/callback` —
   the portal's Redirect URI box refuses `http://` loopback-IP entries, and
   Entra ignores the port only for the literal hostname `localhost`, never
   for the `127.0.0.1` the CLI actually uses.
5. **API permission + admin consent**: on the CLI registration add the
   delegated permission `api://ccx/user_impersonation`, then **Grant admin
   consent** for the tenant — without it, tenants that restrict user consent
   fail the first login with `AADSTS65001`.
6. *(Mirrored deployments)* add the **`email` optional claim** to the API
   registration's **access** tokens.

**Reply to the platform team with:** the tenant ID, the API registration's
**client ID (a GUID)**, the App ID URI (`api://ccx`), and the CLI
registration's client ID.

**Helm values this produces:**

```yaml
queryServer:
  publicUrl: https://ccx.example.com                # required for oidc
auth:
  mode: oidc
  oidc:
    issuer: https://login.microsoftonline.com/<tenant-id>/v2.0
    audience: <API registration client ID (GUID)>   # NOT the api:// URI — v2 tokens carry the GUID
    requiredScopeClaim: roles                       # the entitlement rides the app role
    requiredScopeEncoding: array
    requireTypAtJwt: false                          # Entra stamps typ: JWT, not RFC 9068 at+jwt
    advertisedScopes: ["<App ID URI>/user_impersonation", "offline_access"]  # e.g. api://ccx/user_impersonation
    cli:
      clientId: <CLI registration client ID>
      resourceIndicator: false                      # Entra rejects RFC 8707 `resource` (AADSTS901002)
```

Pair it with the operator half in
[deploy.md → SSO login (OIDC)](deploy.md#sso-login-oidc): `queryServer.publicUrl`
is required for `oidc`, and the config-lane rule empties `secrets.apiTokens`.

**Verify** with [the checklist below](#verifying-before-rollout): the decoded
token's `iss` ends in `/v2.0`, `aud` is the GUID, and `roles` contains
`ccx.read`.

## Okta (with API Access Management)

**Role & prerequisites.** A full authorization server **only with the API
Access Management add-on** — custom audiences, scopes, and claims live on its
*custom authorization servers*, which are that add-on. To check whether you
have it: Admin console → **Security → API** — if you cannot see or create
**authorization servers** there, your org lacks the add-on (your Okta account
team can confirm). Without it there is no direct path: either add the SKU and
use this recipe, or use
[Keycloak in front](#fronting-google-workspace-okta-without-the-add-on-or-a-saml-only-idp).

**Your Okta admin registers** (Admin console → Security → API, and
Applications):

1. **A custom authorization server** (the built-in `default` works) with its
   **Audience** set, e.g. `api://ccx` — one audience per server, so separate
   environments mean separate servers (each with its own issuer).
2. On that server, **the scope `ccx.read`** — the entitlement — and an
   **access policy** for the CLI client whose rule grants the scope **only to
   members of the entitled group**. The rule's grant-type condition covers
   the Authorization Code (and, if wanted, Device Authorization) grants; its
   scope condition must include `offline_access`, and its token settings
   govern refresh-token lifetime. The group condition is what makes the
   scope per-user evidence; a rule granting it to any authenticated user
   defeats the entitlement. (A fresh org's default server can ship with
   **no** access policy — without one, no token mints at all.)
3. **The CLI app**: a **Native / OIDC** application, PKCE, no client secret,
   with the **Authorization Code and Refresh Token** grants enabled (plus
   Device Authorization if wanted) — the Refresh Token grant lives on the
   app, refresh lifetime on the policy rule. Register the redirect URIs
   **exactly** —
   Okta matches the port too (it does not honor RFC 8252's any-loopback-port
   rule): `http://127.0.0.1:3276/callback` and
   `http://127.0.0.1:3277/callback`.
4. **Assign users or the group to the CLI app** — an unassigned user's login
   fails at Okta ("User is not assigned to the client application")
   regardless of token policy.

**Reply to the platform team with:** the authorization server's **issuer URL**
(`https://<org>.okta.com/oauth2/default`, or `/oauth2/<serverId>` for a named
server), the audience value, and the CLI app's client ID.

**Helm values this produces:**

```yaml
queryServer:
  publicUrl: https://ccx.example.com   # required for oidc
auth:
  mode: oidc
  oidc:
    issuer: https://<org>.okta.com/oauth2/default
    audience: api://ccx
    requiredScopeClaim: scp            # Okta grants scopes in the scp ARRAY claim
    requiredScopeEncoding: array
    requireTypAtJwt: false             # Okta access tokens carry no typ header
    advertisedScopes: [ccx.read, offline_access]
    cli:
      clientId: <CLI app client ID>
```

Pair it with the operator half in
[deploy.md → SSO login (OIDC)](deploy.md#sso-login-oidc): `queryServer.publicUrl`
is required for `oidc`, and the config-lane rule empties `secrets.apiTokens`.

**Verify** with [the checklist below](#verifying-before-rollout): the decoded
token's `scp` array contains `ccx.read`, and a non-member of the group gets
no such scope.

## Keycloak

Keycloak plays **both roles**: your primary authorization server, or the
documented front for login-only providers. The realm essentials (all of this
is one realm's configuration):

- **Resource registration** `api://ccx` — a client with every login flow
  disabled; its id is your `audience`. Never use it as a login client.
- **Audience mapper** on the CLI client adding `api://ccx` to access tokens —
  single-audience (the server rejects multi-audience tokens unless RFC 9068
  `typ` is enforced).
- **Entitlement**: the realm role `ccx.read`, mapped into a **flat array
  `roles` claim** (`requiredScopeClaim: roles`, `requiredScopeEncoding:
  array`) — grant it via groups, or add it to the realm's default roles for
  whole-org access. Keep a `ccx.read` **client scope** attached to the CLI
  client (optional scope is enough): `ccx login` requests the scope the
  server advertises, and Keycloak refuses requests for scopes a client does
  not have — even though the entitlement itself rides the `roles` claim.
- **CLI client** (`cli.clientId`, conventionally `ccx-cli`): public, PKCE
  S256, loopback redirect URIs (`http://127.0.0.1/*` — Keycloak honors the
  wildcard, covering the server's advertised ports as-is), device grant
  optional. Refresh comes from the Keycloak session — no `offline_access`
  needed.
- Keycloak stamps `typ: JWT`, not `at+jwt` — leave `requireTypAtJwt: false`.

**Helm values this produces:**

```yaml
queryServer:
  publicUrl: https://ccx.example.com   # required for oidc
auth:
  mode: oidc
  oidc:
    issuer: https://<keycloak-host>/realms/<realm>
    audience: api://ccx
    requiredScopeClaim: roles
    requiredScopeEncoding: array
    requireTypAtJwt: false
    cli:
      clientId: ccx-cli
    # advertisedScopes: omit it — the default advertisement is [requiredScope],
    #   i.e. [ccx.read], and the realm's client scope honors that request
```

Pair it with the operator half in
[deploy.md → SSO login (OIDC)](deploy.md#sso-login-oidc): `queryServer.publicUrl`
is required for `oidc`, and the config-lane rule empties `secrets.apiTokens`.


### Fronting Google Workspace, Okta without the add-on, or a SAML-only IdP

**Build the realm above first — the broker is added to it.** Then one
standard login-app registration at your provider (no add-on SKU anywhere);
users still see your provider's sign-in screen, MFA and policies included.
Keycloak itself is a component you deploy, upgrade, and back up like any
other — its own documentation covers operations; all sign-in gating stays in
your IdP.

- **Google Workspace** — your Google admin creates an *internal-only* OAuth
  client and replies with its **client id and secret**; the secret goes into
  Keycloak's broker configuration (never into the ccx chart). Set the
  broker's hosted-domain restriction so only your workspace can sign in.
- **Okta (or any OIDC IdP)** — your Okta admin creates an **OIDC Web App**
  with redirect URI
  `https://<keycloak-host>/realms/<realm>/broker/<alias>/endpoint`, gates it
  by user/group assignment, and replies with the **client id, client secret,
  and the org URL** (the broker's issuer); id and secret go into Keycloak's
  broker configuration.
- **SAML-only IdPs** — the same shape, as a SAML broker.

*(Mirrored deployments)*: the access token must carry the claim your
`mappingClaim` names (typically `email`) **byte-identical to the code-host
SSO NameID** — make the broker import that attribute from the IdP (Keycloak
imports email by default; verify on a decoded token before rollout).

## Any OIDC authorization server

Auth0, Ping, and any other OIDC AS that mints **JWT access tokens for a
dedicated audience** works through the same configuration — there is no
per-provider code. Walk [the contract above](#what-every-provider-must-end-up-providing)
in your vendor's vocabulary: a dedicated audience distinct from every login
client; a public PKCE CLI client with the advertised loopback ports
registered; `ccx.read` in a per-user-gated claim (set `requiredScopeClaim`
and `requiredScopeEncoding` to match where and how your AS emits it);
`offline_access` advertised if refresh tokens require it; `requireTypAtJwt`
on only if your AS emits RFC 9068 `at+jwt`.

## Verifying before rollout

Decode an access token minted for a test user (paste into a JWT inspector, or
run `ccx login` and decode the cached token) and check:

1. `iss` equals your configured `issuer` **byte-for-byte** (Entra: ends in
   `/v2.0` — a `sts.windows.net` issuer means `requestedAccessTokenVersion`
   is still 1).
2. `aud` is exactly your configured `audience`, and single-valued (Entra:
   the GUID, not the `api://…` URI).
3. The entitlement is present: `roles` contains `ccx.read` (Entra,
   Keycloak) or `scp` contains `ccx.read` (Okta) — and a token for a user
   **outside** the entitled group does not carry it (that user should either
   fail at sign-in, or reach the server and get `403 insufficient_scope`,
   never results).
4. *(Mirrored deployments)* the `mappingClaim` value (typically `email`) is
   present and byte-identical to the user's code-host SSO NameID.

Then the smoke test: a bare `ccx login` (no flags — the server advertises the
client id, scopes, and callback ports) followed by `ccx repos`.

Common sign-in errors and what they mean:

| Error | Meaning |
|---|---|
| `invalid_scope` (Keycloak), `AADSTS65005` (Entra) | the CLI requested a scope the provider doesn't recognize for this client — `advertisedScopes` names a scope that was never registered, or the client-scope / API-permission step was skipped |
| `AADSTS65001` (Entra) | admin consent for the CLI client's delegated permission was never granted (step 5 of the Entra recipe) |
| `AADSTS50011` (Entra), Okta's redirect-URI error | the callback port isn't registered — register every advertised `redirectPorts` entry (Entra: via the manifest) |
| `AADSTS50105` (Entra), "User is not assigned to the client application" (Okta) | the user isn't assigned (Entra: to the API's enterprise app / role; Okta: to the CLI app) — the fail-at-sign-in gate working as intended |
| Login succeeds but every query is `403 insufficient_scope` | the token lacks `ccx.read` — the role/scope wasn't granted to the user, or `requiredScopeClaim`/`requiredScopeEncoding` doesn't match where the provider emits it |
| `AADSTS901002` (Entra) | the RFC 8707 `resource` parameter reached Entra — set `auth.oidc.cli.resourceIndicator: false` |
