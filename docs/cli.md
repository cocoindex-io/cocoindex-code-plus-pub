# The `ccx` CLI (and MCP)

`ccx` is the client engineers and coding agents use to **query** an indexed
codebase from a workstation, CI, or an agent sandbox. It talks to a query server
that your platform team has deployed ([deploy.md](deploy.md)); the CLI itself
holds no index and needs no license.

## Install

`ccx` is published to **public PyPI** (license-free client, **Python 3.11+**).
Install it as an isolated tool so it's on your `PATH`:

```bash
uv tool install cocoindex-code-plus     # recommended
# or: pipx install cocoindex-code-plus
# or: pip install cocoindex-code-plus
ccx version
```

Pin a version for CI/automation (`cocoindex-code-plus==X.Y.Z`), and keep
installs current. Login settings are fully **discovered from the server**
from **0.1.34 on** (client id, scopes, callback ports, Entra's
resource-indicator switch), so on SSO deployments an older `ccx` prompts for
a client id it shouldn't need, and can fail Entra sign-in with
`AADSTS901002` — treat both as "upgrade me", not misconfiguration.

From **0.1.38 on** the CLI says so itself: when the server advertises a login
setting it doesn't recognise, it warns, names the setting, and points at the
upgrade — then carries on, since login often still works without it. An older
CLI stays silent, which is why the 0.1.34 floor is still worth checking by
hand when a login fails.

From **0.1.60 on** you no longer need to watch for releases: the CLI and the
server release in lockstep, every reply from the server names its release,
and a CLI that is older prints one line after its output, naming both
versions and the upgrade command — once a day per server, and again as soon
as the server moves to a new release:

```text
ccx 0.1.55 is older than the server (0.1.59); they release in lockstep. Upgrade: uv tool install -U cocoindex-code-plus
```

`ccx status` always shows the comparison on its `cli:` line. A CLI newer
than the server is never nagged, and the check never consults PyPI: the
right version is your deployment's, not the newest published one.

Driving `ccx` from a coding agent? Install the **agent skill** too — see
[For agents & automation](#for-agents--automation).

## Configure

Run interactively, `ccx` asks for anything it's missing **once** and saves
the answer (`~/.config/ccx/config.json`; `%APPDATA%\ccx` on Windows) — so a
human's setup is just `ccx login` (SSO) or `ccx status` (token deployments).
`ccx config` shows what is saved and changes it. The environment variables
below always **override** the saved answers and are the way to configure
scripts, CI, and agents. They must be **exported**: `ccx` does not read `.env`
files, so a project `.env` cannot silently re-point the CLI at another
deployment.

| Var | What |
|---|---|
| `CCX_SERVER_URL` | the query server's URL (e.g. `https://ccx.example.com`, or `http://127.0.0.1:8080` via `kubectl port-forward`). Optional interactively: prompted once and saved as your default; a one-off `--server` overrides without changing the default |
| `CCX_API_TOKEN` | your API token — your platform team issues it: a token shared across the deployment, or your own `ccxk_…` key. Both go in this one variable, sent as `Authorization: Bearer`. On an SSO deployment humans skip this and run `ccx login` instead (below) |
| `CCX_CLIENT_TIMEOUT_SECONDS` | optional; **debug override** of the client's read ceiling — default **600 s** (**2400 s** for [`ccx ask`](#ccx-ask--ask-a-question-get-an-answer)), with connects failing on their own fixed 10 s bound. The server enforces and reports its own deadline (`deadline_exceeded`), so the ceiling is deliberately generous and uncoordinated: it only catches a dead network path or a wedged server, and your platform team raising the server deadline needs **no** change here |

```bash
export CCX_SERVER_URL=https://ccx.example.com   # optional in a terminal (prompted + saved)
export CCX_API_TOKEN=<your-token>               # token deployments only
ccx status        # server reachable + healthy (and which one), then the credential your next request would use
```

`ccx status` probes health without a credential and shows the resolved host,
server version, uptime, and credential in one header. It adds the CLI version
only when it differs. An older CLI shows the upgrade command.

The index-status request tests the resolved credential; only `/health` is anonymous.
Each observation resolves the credential once, including any login refresh.
`--wait-ready --timeout S` bounds refresh and listing requests by the remaining time.

A rejected credential shows `auth rejected`, its source, and the fix.
For `token (CCX_API_TOKEN) rejected`, check the token or run `ccx login`.
For `login (cached) rejected`, run `ccx login`, or `ccx logout` to use `CCX_API_TOKEN`.
A successful status request without a credential shows `auth off`.
A 401 or 403 with no credential shows `auth required` and a login hint.

`--watch --plain` and piped watch output print timestamped progress changes.
Failed polls print errors and credential advice.
After a failed health or listing request succeeds, watch prints `server reachable again`.

`TERM=dumb` or an unset `TERM` selects plain output without colour or cursor control.
`NO_COLOR` suppresses colour and selects the same progress log during watch.

The exit code follows server health, even when a credential warning appears.
Use `ccx config show` to inspect where the server URL comes from.

**SSO deployments (OIDC).** If your platform team enabled company-IdP sign-in,
skip `CCX_API_TOKEN` and sign in once:

```bash
ccx login            # opens your IdP in the browser (PKCE, MFA and all)
ccx login --device   # device-code flow instead (no local browser, e.g. over SSH)
ccx logout           # drops the cached token
```

The server advertises its OAuth client id, so a bare `ccx login` is normally
all you need (what your admin registered to make that work: [sso.md](sso.md)). If your deployment doesn't advertise one, the first login asks
for the id your admin provides — you're prompted in a terminal (or pass
`--client-id` / set `CCX_OIDC_CLIENT_ID`, or run `ccx config set client-id
<id>`); it's remembered per server afterwards. `ccx login` also makes that
server your saved
default (with a printed notice). The token is cached and refreshed
automatically. `ccx logout` drops the **credential** only — your remembered
client id and default server stay, so signing back in takes no flags. CI jobs
and agents keep using `CCX_API_TOKEN` — on SSO deployments that's an issued key
of the form `ccxk_<id>_<secret>`.

During a browser login the CLI listens on a local port to catch the redirect
back from your IdP — and the server tells it which ports to use (typically
3276/3277), so there is nothing to configure. If every listed port is busy,
login says so: free one, or — only if your admin registered an alternative
port — pin it with `--redirect-port <port>` (or `CCX_OIDC_REDIRECT_PORT`).
The scopes to request come from the server too — deployments advertise
them (including `offline_access` where refresh tokens need it, as on Okta
and Entra), so there is nothing to pass; `--scope` remains a debugging
override only.

**Where your token is stored.** In your OS keyring when one is available,
otherwise in `~/.config/ccx/tokens.json` (created `0600`). `ccx config` reports
which is in force. The keyring needs an optional package — install it with
`pip install 'cocoindex-code-plus[keyring]'` (or
`uv tool install 'cocoindex-code-plus[keyring]'`) and log in again to move an
existing token. To choose explicitly, `ccx config set token-cache
auto|keyring|file`, or `CCX_TOKEN_CACHE=<value>` for one command; `keyring`
refuses to fall back to a file, which is the point of it.

**Mirrored deployments.** If your platform team enabled code-host-mirrored
authorization, `ccx repos` and every query show only the repos **your**
code-host account can read — a repo you lack access to behaves exactly like
one that doesn't exist. If private repos you expect are missing, you've most
likely never signed into the code host through your company SSO: do that
once (e.g. the org's SSO page on GitHub) and retry — results can take up to
an hour to appear while server-side caches refresh.

## `ccx status` — server and index progress

`ccx status` prints the server and credential block, then the indexer and index blocks:

```text
ccx 127.0.0.1:8080: healthy, auth off, 0.1.70, up 18 min
indexer: pass running for 18 min, 1 ref in progress (0.1.70, cycle mode, up 18 min)
acme/library main: indexed 6 min ago at 3f2a1c9e04b7
acme/app main: first pass 37% (742 of 2,004 files, 5,318 chunks), about 10 min; started 18 min ago
1 of 2 ready. To wait: ccx status --wait-ready --timeout 600
```

Pipes and `--plain` use this format. MCP status text uses the same ref lines.
Each ref occupies one line, without colors, bars, or column padding.
A terminal shows REPO, REF, and INDEXED AGE / COMMIT columns.
A state mark appears before each repository name.
Green `✓` means queries read the displayed commit.
The table shows seven SHA characters. Other output formats keep their existing SHA lengths.
When all repositories share one owner, the REPO header shows the owner once.
Rows then show bare repository names. Mixed owners keep full names.
Cyan marks work, dim marks queued refs, and red marks failures or a silent indexer.
Yellow `!` marks stale work that needs attention.
Failure labels keep their scope: first pass, update, or repository check.
A complete row stays green after its reporting indexer stops.
Details appear under the last column. One footer gives `N of M ready` and an unfinished report's watch command.
The minimum table width is 80 columns.
Five repositories with one owner, names through 32 characters, and `main` refs fit that width.
Widths below 80 columns, or overflowing rows, select the pipe format.
The CLI checks width after adding checkout relations. Long relations can select the pipe format.
`NO_COLOR` removes colors. Non-UTF-8 terminals use ASCII marks and bars.

Inside a checkout, its repository rows append the indexed commit's local relation after the SHA.
Examples include `(your HEAD)`, `(HEAD~2)`, and `(not in your clone yet; git fetch to compare)`.
The comparison never fetches. Other repositories keep server facts only. JSON stays unchanged.
Watch caches each SHA comparison until checkout, git ref, or object-store metadata changes.
Local HEAD and ref-name changes print the affected checkout row again.
Update rows retain the relation beside their serving commit, including terminal detail lines.

The header shows the server version and a duration such as `28 min` or `1 h 15 min`.
It adds the CLI version only when it differs. A successful anonymous status request shows `auth off`.
A 401 or 403 establishes that auth is required. A missing credential then earns a separate yellow login hint.
The terminal header drops uptime first, then version, to fit its width.
A healthy server exits 0 even while indexing. An unreachable server exits 1.
Unqueryable refs, missing progress, stalled work, errors, and serving commits remain explicit.
The heartbeat supplies the cycle deadline. No log command is invented.

| State | Meaning |
|---|---|
| `indexed <ago> at <sha12>` | queries read this commit |
| `committed <ago> at <sha12>, repo not queryable yet` | remaining refs must commit first |
| `first pass N%` | files are being indexed for the first time |
| `updating for <elapsed> to <sha12>` | queries still read the commit named by `serving … meanwhile` |
| `walking the tree` | the indexer discovers files and directories |
| `queued behind <ref>` | another ref runs first |
| `symbols: N of M modules` or `symbols: waiting for …` | symbol resolution runs or waits |
| `finishing` | the engine commits the ref |
| `first pass failed (attempt N)` | the next cycle retries; check the indexer's log |
| `not reporting since` | the reporting indexer is no longer running |

During the walk, the report can say:

```text
walking the tree: 1,421 files found so far, 338 of 410 directories listed, about 2 min to finish the walk
```

The estimate starts after 60 seconds of samples and 10% of known directories are listed.
The directory total can grow. This estimate covers only the walk.

After the walk, the files estimate uses the slower recent or whole-attempt file rate.
It says `about N min` after 60 seconds of samples with a final file total.
Without a completed file since the previous sample, it holds the last estimate.
It appends `no progress for 45 s`, or whole minutes after one minute.
Without a previous estimate, it shows only the stall age.
A restart collects fresh samples and discards the previous attempt's estimate.

The walk uses its average directory rate over the attempt.
One slow directory can increase the estimate. A minute without directory progress suppresses it.
A confirmed stall appears even below 10% directory coverage.

The summary counts first passes and updates separately: `1 first pass, 1 updating`.
A first pass remains a first pass through symbol waits and finishing until the repository is queryable.
JSON supplies `summary.first_pass` and `summary.updating`; `summary.in_progress` keeps their sum.

The indexed age measures index completion, not the Git commit time.
Terminal table columns align. Pipe lines use no padding. JSON values do not change.
Pipe rows have no width limit or renderer wrapping.
Long names can exceed 100 columns on an 80-column terminal; the terminal controls visual wrapping.
Above 50 repositories, the footer counts hidden repositories and names `ccx status --all`.
For example: `… and 12 more repos; ccx status --all lists them`.

An idle cycle indexer says `Indexer: idle, next cycle in 40 s`.
The cycle period includes pass time. Older heartbeat rows omit the countdown.
An older indexer that takes over cannot reuse another writer's cycle period.
An overdue or exactly due cycle says `Indexer: idle, next cycle due now`.
A running pass says `pass running for 2 min, 1 ref in progress`.
Live mode says `watching`. Metadata includes the version, mode, and process uptime.

Symbols and finishing show elapsed time: `finishing, 1 min so far`.
Before one minute, they say `under a minute so far`.

File estimates can change when file costs change. `about` does not promise an accuracy bound.
`ccx indexed`, query errors, and MCP carry the same walk estimate.
The MCP `index_status` tool supplies readable status text and structured progress fields.

These examples use the shared renderer. Ages describe indexing, not Git commit time:

```text
indexed 11 min ago at bbbbbbbbbbbb
committed 11 min ago at bbbbbbbbbbbb, repo not queryable yet
updating for 11 min to aaaaaaaaaaaa: 37% (742 of 2,004 files, 900 chunks), about 10 min; serving bbbbbbbbbbbb meanwhile — ccx status --watch
symbols: waiting for heads/other, 1 min so far — ccx status --watch
symbols: 10 of 20 modules, 1 min so far — ccx status --watch
finishing, 1 min so far — ccx status --watch
finishing, under a minute so far — ccx status --watch
Indexer: idle, next cycle in 40 s (v, cycle mode, up 15 min)
Indexer: idle, next cycle due now (v, cycle mode, up 15 min)
Indexer: pass running for 2 min, 1 ref in progress (v, cycle mode, up 15 min)
Indexer: watching (v, live mode, up 15 min)
```


When progress is absent, the report says:

```text
Indexer: no indexer has reported — start ccx-indexer (the chart's indexer deployment), then ccx status --watch
Index: no progress reported (the indexer predates 0.1.70, or has never started) — ccx repos lists what is indexed
```

- `ccx status --watch` redraws a terminal table every 10 seconds.
  Plain watch prints the header once, then UTC timestamped lines for changed refs, folding counts, and ready counts.
  Ref identities include the repository key, so names across instances do not collide.
  Semantic field changes, including progress and phase timestamps, print a new line.
  Clock passage and idle-check timestamps alone do not print a ref line.
  After a minute without changes, it prints one idle notice.
  It exits 0 after it observes work and every repository becomes ready.
  If it starts ready, it waits up to 10 minutes for work to appear.
  `--idle-timeout S` changes this grace period; `0` exits immediately when ready.
  Once work appears, the idle timeout no longer applies.
  Idle expiry prints `Watch stopped: no indexing work observed for 600 seconds.` and exits 0.
  A successful listing must confirm readiness before idle expiry can end the watch.
  Read failures do not restart the idle clock. `--timeout S` bounds the whole command and exits 1.
  JSON suppresses unchanged ready reports during idle; new SHAs or repositories still print.
  Heartbeat and ref-check timestamps alone do not repeat an idle report.
  The stop line goes to stderr.
  SIGINT and SIGTERM exit 1.
  Request failures remain visible. A 429 or 503 respects `Retry-After`.
- `ccx status --wait-ready --timeout 600` prints the final report once.
  It exits 0 immediately when ready, and 1 at timeout or when failures remain without active work.
  `--idle-timeout` does not affect `--wait-ready`.
- `--all` disables folding. Otherwise, complete refs beyond three per repository fold into a count.
  Above 50 repositories, all complete refs fold. Every page is read.
- `--json` preserves the heartbeat and listing responses, including page cursors and wire timestamps.
  JSON adds no timestamps or terminal controls. Diagnostics go to stderr.

### `ccx indexed` during a first pass

```text
Not indexed yet: acme/app, first pass 37% (742 of 2,004 files), about 10 min left — ccx status --watch follows it
Not indexed yet: acme/app, first pass failed (attempt 2): connection failed — retrying next cycle
Indexed: acme/app at heads/main@3f2a1c9e04b7 (your HEAD); updating to 9b81d0c2aa15, 37%, about 10 min
Not indexed: acme/other — ccx status lists the repos this server indexes; add it to the config repo to index it
```

An unfinished or failed first pass exits 1 for humans. The hook retries a failed first pass later.
An indexed ref exits 0 during an update.
`ccx indexed --json` includes the progress snapshot and `queryable`.
The plugin reports a first pass once per agent, then permits ordinary hints when the repository becomes queryable.
A committed ref whose repository is still blocked earns the same indexing hint, without spending ordinary hint markers.

## Use

```bash
# Discover what you can search
ccx repos                                        # list indexed repos: alias, stable uid, default branch, indexed refs as <ref>@<commit>

# Semantic search (targets explicitly-named repos; no global "search everything")
ccx search "how are vector embeddings stored"   # scopes to the current repo + branch (see note below)
ccx search foo --repo cocoindex-io/cocoindex     # a specific repo
ccx search foo --repo acme/a --repo acme/b       # several repos, one cross-repo-ranked result list
ccx search foo --repo my/repo --git-ref main     # a specific indexed ref (single repo scope)
ccx search foo -k 10                             # more results; --offset paginates
ccx search parse --lang python --lang rust        # restrict by source language (repeatable)
ccx search config --path 'src/*.py'               # restrict by path glob (repeatable)
ccx search retry --tests                         # include tests in similarity order
ccx search retry --no-tests                      # exclude test candidates

# AST structural grep (matches the syntax tree, not text; needs -l/--language)
ccx grep 'def \_(\*) \*:' -l python               # function defs (async, decorated, `-> T` too)
ccx grep 'foo(\*)' -l python --git-ref v1.2       # foo(...) with any arguments, at tag v1.2
ccx grep 'isinstance(\X, \Y)' -l python --path 'src/*.py'

# Plain-text grep (a regex over the text of EVERY file — comments, docs, config; no -l needed)
ccx grep --text 'retry_budget'                    # a word or phrase anywhere; smart case
ccx grep --text 'TODO|FIXME' --path 'src/*'       # a regex (Python re syntax), scoped by path
ccx grep --text -w 'timeout' -l yaml -l toml      # whole word; with --text, -l is an optional filter
ccx grep --text -s 'return\s+\d{7};' --path 'src/*' # -s: case-sensitive (cheaper on a large repo); -i: insensitive
ccx grep --text 'retry' --cursor <c>              # continue a scan where its stderr note stopped

# Symbol navigation: definitions & references (resolved, not text matches)
ccx defs QueryService                             # where is this symbol DEFINED?
ccx defs Repo.find                                # a member with its qualifier: every definition
                                                  #   whose qualified name ends with it (C++/Rust: Store::fetch)
ccx defs python:db.Repo.find                      # exact qualified name (the ':' selects the mode)
ccx defs lookup:withDefault:                      # an Objective-C method: its full selector
ccx defs Config --kind class --lang python        # filter by kind / language / --path
ccx refs QueryService                             # where is it USED? (by name, broad)
ccx refs Repo.find                                # uses of every definition matching the dotted name
ccx refs python:db.Repo.find                      # every use of this exact qualified name
ccx refs src/db.py Repo.find                      # exactly this one definition — paste the
                                                  #   `uses: ccx refs …` command a defs row prints
ccx refs QueryService --role call                 # restrict to a reference role

# File access (ref-scoped; repo + ref auto-detected like search)
ccx read-file README.md                          # print a file's contents
ccx read-file src/app.py --offset 40 --limit 20  # 20 lines from line 40 (--offset = 1-based line)
ccx show src/app.py                              # the file's outline: every definition at its line, bodies folded (working tree first)
ccx show src/app.py:142                          # the definition at line 142, framed by its enclosing scopes
ccx show -s QueryService                         # the definitions of a name, rendered; -e expands, --git-ref reads the index
ccx show --at HEAD~3 src/app.py                  # the file as a commit of your clone holds it (read from local git)
ccx find-files "*.py"                            # list files by glob
ccx find-files --git-ref main                    # list files on a specific ref (100 per page; --offset/--limit)

# Commit history (from your clone, up to HEAD)
ccx log QueryService                             # the commits that changed the symbol's lines: sha, date, PR, +X/-Y, subject
ccx log QueryService --patch -n 20               # each commit's diff within the symbol, 20 commits
ccx log -S 'MAX_RETRIES = 5'                     # the commits that added or removed a text, and their files

# Repo / ref metadata
ccx git-refs                                     # the current repo's indexed refs + commit shas (+ where each sits relative to your HEAD)
ccx git-refs cocoindex-io/cocoindex              # a specific repo ("(default)" marks the default branch)
ccx indexed                                      # is this checkout indexed, at which commit, and which local files differ from it

# Ask a question and get an answer (if your deployment enables it — see below)
ccx ask "how does the indexer decide what to re-embed?"
ccx ask "compare auth in these two services" --repo acme/a --repo acme/b
ccx ask "what changed in the release flow" --git-ref v1.2 --json
```

`ccx git-refs` lists **git** refs (branches and tags) — not to be confused with
`ccx refs`, which finds where a *symbol* is used.

**`ccx indexed`** answers the question an agent or a person asks before
reaching for ccx in a checkout: is this repo indexed, and how far is the index
from what I have? Exit 0 when it is:

```text
Indexed: acme/proj at heads/main@1a2b3c4d5e6f (origin/main, 3 commits behind your HEAD)
  server:  https://ccx.example.com
  local:   7 files differ locally (`git diff --name-only 1a2b3c4d5e6f` lists them, plus untracked files): grep those; ccx covers the rest.
  refs:    heads/main@1a2b3c4d5e6f, tags/v1.2@9f8e7d6c5b4a
  checked: 12 min ago (cached; --refresh asks the server now)
```

The ref it names is the one a query from that checkout would run against
(your branch if indexed, else the default branch). The parenthesis says where
the indexed commit sits relative to your `HEAD`: `your HEAD`, a ref name, a
verified `HEAD~N`, `N commits behind/ahead of your HEAD`, `diverged`, or `not
in your clone yet` when you have not fetched it. The `local` line is the
split that matters on a feature branch: files that differ need local grep,
everything else is what the index holds. Exit 1 when the server says the repo
is not indexed (or not visible to you), 2 when it cannot be told (not in a
git checkout with an `origin` remote, no server configured, server
unreachable). The answer comes from a local cache (`~/.cache/ccx/indexed.json`)
that your fetched `origin/*` refs keep honest: a fetch that knows a newer
commit than the cached one re-asks at once, otherwise the entry lives from a
minute to an hour depending on how recent the tip is; `--refresh` asks now,
`--json` emits the facts as one object. `ccx git-refs` for the current repo
also refreshes it.

Rust navigation puts the type definition before its impl fragments.
`ccx defs` collapses impl fragments into one `[impl]` summary with complete
counts. A page-limit note says when more definitions exist.
`ccx refs PATH NAME` resolves a bare method name within that file, or lists
exact commands when several methods match. Name-only reference output groups
uses by definition and lists unresolved mentions separately.

**Symbol navigation** (`ccx defs` / `ccx refs`) answers "where is this defined"
and "who uses it" from a **resolved symbol graph** the indexer builds — cross-file,
alias- and re-export-aware — not from text matching. It covers **Python,
TypeScript/JavaScript (incl. TSX), C/C++, Objective-C, C#, Rust, Java, Go, and Kotlin**; other languages
remain reachable via `search` and `grep`. The two verbs chain: each `ccx defs`
row ends with a paste-ready command —

```
src/db.py:42:4 [method] python:db.Repo.find
  lang=python  uses: ccx refs src/db.py Repo.find
```

— and running that `uses: …` command returns exactly that definition's uses
(it carries any `--repo`/`--git-ref`/`--server` flags you passed, so it
re-queries the same scope). Four precisions of `ccx refs`, broad to exact: a
bare `ccx refs NAME` casts a wide net by unqualified name; a **dotted name**
(`ccx refs Repo.find`, `ccx refs db.Repo.find`, or C++/Rust
`ccx refs Store::fetch`) covers every definition whose qualified name ends
with it — the natural spelling of a member, no tag needed; the headline's
**qualified name** (`python:db.Repo.find` — every qualified name opens with
its language tag, `python:` / `tsjs:` / `cpp:` / `csharp:` / `rust:`, and
TS/JS and Rust names carry a second `:` between the file path and the entity)
matches exactly, covering
every occurrence and overload under it, with no flag needed; the pasted
`uses:` command pins one definition. Copy rather than compose the exact
pair — the headline's qualified name is *not* the second token. Reference rows are labeled by **role** (`call`, `import`,
`type_use`, `inherit`, `field_access`, …; filter with `--role`) and by
**resolution**: `resolved` is definite, `ambiguous` enumerates each surviving
candidate as its own row, and `name_only` marks a mention whose target couldn't
be resolved (e.g. an external import). Watch stderr for the **coverage note**:
it tells you when the symbol index for the ref isn't built yet, skipped the ref
as too large, parsed only part of it, or was built at another commit than the
ref's indexed head (the note names both) — in all of those, a missing symbol may
just be unindexed, so absence is not completeness. A clean note is still not a
proof: a use the resolver could not commit (an unknown receiver, an import
across a Python source root the index could not infer — roots come from package
markers and the repo's own absolute imports, never from build config) appears
as a `name_only` row rather than a resolved one — every target form includes
those rows unless you pass `--no-include-unresolved` — so read them before
concluding a symbol has no callers.

A member written with its qualifier but no language tag, as in
`ccx defs Repo.find` or C++/Rust `ccx defs Store::fetch`, matches every
definition whose qualified name ends with it on segment boundaries
(`python:db.Repo.find`; `cpp:app.Store.fetch` and `rust:src/store:Store.fetch`
alike) — `ccx defs find` alone is the bare base name, and `-b Repo.find`
forces the dotted text to be looked up as one. When a lookup is forced onto
a selector it cannot match (`-b Repo.find`, `-q Store::fetch`), the CLI
prints a `warning:` line on stderr naming the lookup to run instead, and the
MCP response carries it as `warnings`.

`ccx search`, `grep`, `read-file`, and `find-files` scope to the current repo
**only when the working directory is a git checkout with a GitHub/GitLab
`origin`** — that origin is mapped to the matching indexed repo. Otherwise (no
git repo, or a non-GitHub/GitLab origin) the command **errors** with guidance:
pass `--repo` (repeatable for `search`, up to the server's per-search cap) —
`ccx repos` lists what's indexed. There is no global "search everything" mode.
Repo names match case-insensitively, as they do on the code host: a clone of
`Acme/Proj`, or `--repo Acme/Proj`, finds the repo `ccx repos` lists as
`acme/proj`.
With several `--repo`s, each repo is searched at its own server-side default
ref (a stderr note names each resolved ref); `--git-ref` applies to a single
repo scope.

These commands are also **ref-scoped**: they operate on one git ref of the repo.
`--git-ref` takes a branch or tag name (`main`, `v1.2`) — or the explicit
`heads/<branch>` / `tags/<tag>` form if a branch and tag share a name. When you
omit it, the CLI uses **your checked-out branch** if that branch is indexed
(including its `origin` upstream when the local name differs), else the repo's
**default branch** (an explicit `--repo` always gets that repo's default
branch); it prints a `Using git ref …` note to stderr so you always
know which ref answered. `ccx git-refs` lists what's indexed.

Similarly, when you run `search` or `grep` from a **subdirectory** of the
checkout (and gave no `--path`), results are scoped to that subtree — the note
on stderr names the glob; run from the repo root or pass `--path '*'` to cover
the whole repo.

`grep` metavariables use the `\` sigil (`\_`, `\*`, `\NAME`). A pattern written
in ast-grep's `$NAME` / `$$$` dialect matches those tokens literally and
usually finds nothing; the CLI then prints a `warning:` line on stderr showing
the pattern in ccx's forms (the MCP response carries it as `warnings`).

`ccx grep --text` is the **plain-text** mode: the pattern is a regular
expression (Python `re` syntax; a plain word works as-is) matched line by line
against the text of **every** file in the ref — comments, docs, config and
languages the structural grep cannot parse included — so it needs no `-l`
(with `--text`, `-l` is an optional, repeatable filter by language). Case is
**smart** by default (case-insensitive unless the pattern has an uppercase
letter; `--case sensitive|insensitive` forces it, and `-s` / `-i` are the
short forms); `-w/--word` matches whole words only. Output is one
`path:line:text` line per match; the line number is the one `read-file
--offset` takes. A pattern with literal text in it is cheap: the server
prefilters on that text in SQL, and reads only the files holding it when the
deployment has the [text search index](deploy.md#text-search-index); one with
none — `.*`, a character class alone — or whose only literal is in most files
(`return`) scans every file of the ref, so add `--path` on a large repository,
and prefer `-s` when case does not matter to the question (the
case-insensitive scan costs several times more).

**Grep pages by cursor, in a shuffled scan order.** Both grep modes scan files
in a fixed shuffled order (by a hash of the path), so a page is a sample of
the ref rather than its alphabetically-first subtree. When a scan stops short
of the ref's end, the CLI prints one stderr line with the cursor to continue:

```text
… more matches; continue with --cursor 3f2a…c1.0        # the page filled
… scan incomplete; continue with --cursor 3f2a…c1.end   # the server stopped ahead of its deadline
```

The second case comes with a `warning:` line saying how far the scan got and
what to do: continue with the cursor, or narrow with `--path`, a rarer
literal, or `-s`. The same command with that `--cursor` resumes exactly where
the scan stopped and does not read the files already scanned. The exit code
is 0 either way; a scan that could not finish inside the server's deadline
no longer fails with a `503`. The branch may move between pages: each page
reads the ref as it is at that moment, and the cursor stays valid (a file
added since the last page is scanned when the chain reaches it).

`--offset` differs by command: for `read-file` it's a **1-based line number**;
for `find-files` it's a **skip count** for paginating results. `grep` has no
`--offset`: it pages with `--cursor`.

**Server limits.** Requests are bounded server-side with clear `400`s when
exceeded: search `--top-k` ≤ 100, result pages ≤ 500, query/pattern text ≤ 8 KB.
`read-file` returns at most **5 000 lines** (and at most 1 MiB of content) per
call — for a bigger file, page with `--offset`/`--limit`; the response's line
numbers show where the window ended.

By default, semantic search prefers implementation code over test code.
Queries containing test or regression words keep similarity order. This
includes identifiers such as `test_retry` and `TestRetry`. `--tests` forces
similarity order with tests included. `--no-tests` excludes test candidates.
The server reads up to 20,000 candidates to fill a page; a page can be short
when the index or that limit is reached. Returned scores remain raw cosine
similarities, so default results need not have descending scores.

### `ccx show` — a file's outline, or one definition's body

`ccx show PATH` prints a file as an outline, the IDE outline view in a
terminal:

- **Each function is one row at its line**: its signature joined onto one
  line, then how many lines it spans from there.
- **Each type shows its head and fields**, with its methods as rows.
- **Docs and comment blocks show their first line.**
- **The imports are one row**, `... N import lines`.
- **No blank lines.** The line numbers carry the gaps.
- **Test code is collapsed**: a module or type its language marks as test
  code (`#[cfg(test)]`, a `TestCase` subclass, `@Suite`, `[TestFixture]`)
  or whose name starts or ends with a test word (`tests`,
  `integration_tests`, `TestHarness`, `testutil`) shows its head, a
  `// members:` roster of what it holds and a `... N lines` cue. A test
  file itself outlines fully.
- **A long outline folds to depth 1.** Over about 300 rows, the server
  renders the file's items only, each container collapsed to its head, a
  `// members: a, b, c, +N more` roster and a `... N lines` cue, and the
  CLI notes it on stderr: `outline folded to depth 1: the full outline is
  2,483 rows; ccx show PATH:LINE opens one object, --depth 2 shows one more
  level, -e everything.` `--depth N` sets the level yourself and is never
  folded further; `-e` and `--depth` are exclusive.

It reads the file from your **working tree** when it is there (inside or
outside a checkout; outside one no repo is needed), so it is right on the
branch you are on; the index serves only the fallbacks below. `ccx show
PATH:LINE` renders one definition whole, its doc included; on an import line
it prints the imports. `-e/--expand` renders everything verbatim.

```bash
ccx show src/app.py                        # the outline
ccx show src/app.py:142                    # the innermost definition at line 142, its enclosing scopes as frames
ccx show src/app.py:142:8                  # a pasted `ccx defs` headline (path:line:col) works as a target
ccx show src/app.py:142-150                # a pasted `ccx grep` headline too (the first line is used)
ccx show -e src/app.py                     # the whole file, numbered
ccx show --depth 1 src/app.py              # the file's items only, each class or module collapsed to its head and a members roster
ccx show -s QueryService                   # the definitions `ccx defs QueryService` finds, rendered
ccx show -s find --kind method src/db.py   # narrowed by kind and to one file; -q/-b pick the name mode as on defs
ccx show --git-ref main src/app.py         # the indexed copy at that ref, never the working tree
```

Every object prints under a header,
`<path>  <kind> <layer-path>  L<start>-L<end>  (<provenance>)`, whose
provenance is `working tree`, `working tree, differs from indexed <ref>@<sha>`
(your file is not what the index holds) or `indexed <ref>@<sha>`. The body
uses the shared gutter: `N:` an exact source line, `N|` a frame (an enclosing
scope's head), `N~` derived text anchored at line N (a folded row, a doc's
first line), ` ~` a cue. A row `... 16 lines` at line 27 spans lines 27 to
42.

```text
$ ccx show src/db.py
src/db.py  file  L1-L47  (working tree)
 1: """Row storage for the API: a keyed cache in front of Postgres."""
 3~ ... 6 import lines
11: @dataclass
12: class Row:
13:     key: str
14:     value: bytes
17: class Repo:
18~     """Rows by key, cached in memory. …
23~     def __init__(self, pool: Pool) -> None: ... 3 lines
27~     async def find(self, key: str, *, refresh: bool = False) -> Row | None: ... 16 lines
33~         """Look a row up by its key. …
44~     async def put(self, row: Row) -> None: ... 4 lines
45:         """Write a row through to Postgres."""

$ ccx show src/db.py:27
src/db.py  method Repo.find  L27-L42  (working tree)
17| class Repo:
  ~     ...
27:     async def find(
28:         self,
29:         key: str,
30:         *,
31:         refresh: bool = False,
32:     ) -> Row | None:
33:         """Look a row up by its key.
34:
35:         Returns None when the key is absent.
36:         """
37:         if not refresh and key in self.cache:
38:             return self.cache[key]
39:         row = await self.pool.fetch_row(key)
40:         if row is not None:
41:             self.cache[key] = row
42:         return row
```

A position inside a local binding opens the enclosing function, method, or
type. Rust structural grep `SessionView { \* }` excludes impl and type
declarations. Each grep hit displays at most 40 lines and 4096 bytes. A note
names a cut; the hit retains its full line bounds for `ccx show PATH:LINE`.

**Where the text comes from.** The working tree is the default source; the
index serves the file when it is not on disk, when `--git-ref` names a ref or
`--repo` a repo, or when the file is over the request-body bound (8 MiB) — a
stderr note says which, and the header says `indexed`. `-s NAME` resolves the
name in the index (as `ccx defs` does), then renders each definition from your
working-tree file **by structure**, so lines that shifted since the indexed
commit do not matter; where the name is ambiguous in the local file, or the
file is absent, the indexed definition is shown instead and a note says so.
One unique definition renders in full. Several definitions list their paths
and exact commands for you to pick one (`ccx show PATH:LINE`), exit 0.
Add a file path after `-s NAME` to restrict lookup to that file. A
`... N more lines` cue inside a large type folds that type's own lines;
`ccx show -s <name>` or `ccx show PATH:LINE` shows it whole.

**What leaves your machine.** Showing a working-tree file sends its content,
uncommitted edits included, to your deployment's own query server — the same
party that holds the index. The server parses and renders it in memory for
the request, stores nothing, writes no content to its logs or error messages,
and the audit record holds the path, counts (objects rendered, lines and
characters sent and folded) and, inside a checkout, the repository the file
belongs to: the CLI sends the repository it detected as a hint, the server
authorizes it as it authorizes any repository, and usage analytics attributes
the request to it — nothing else depends on the hint. Nothing is sent for a
file over the bound or when `--git-ref` is given; a file with NUL bytes is
refused as binary.

Exit codes: 0 with output (the listing included); 1 when `-s` matches
nothing, when the path is on neither side (not on disk, not in the ref), or
on a usage error such as `-s` together with a `PATH:LINE`; 2 on a malformed
command line.

### `ccx log` — a symbol's commit history

The index holds one commit per ref and no history; your clone holds all of
it. `ccx log SYMBOL [PATH]` finds the definition through the index (the
`ccx defs` selectors: `-q/-b`, `--kind`, a PATH), places its lines in
HEAD's copy of the file — by structure, else by name, when the file has
changed since the indexed commit — and runs `git log -L` on them:

```
$ ccx log FEATURES_10
crates/store/src/schema.rs  constant FEATURES_10  L386-L386  (HEAD 007448888a1c)
fc5dcc10b8c8  2026-10-22  #2814   added +1  Fix session service placement  (LJ)
```

One line per commit, newest first: the short sha, the date, the pull
request number from a `(#N)` subject suffix, the lines added and removed
within the symbol (`added +N` for the commit that brought it in), the
subject and the author. `-n` (default 10) and `--since` (`2d`, `1w`, or a
date) bound the walk; `--patch` adds each diff within the symbol.

`ccx log -S TEXT [PATH…]` is `git log -S`: the commits that added or
removed TEXT (`adds`, `removes`, `moves`) and the files they touched. Use it
for a symbol the index no longer holds, or any string.

`ccx show --at COMMIT PATH` (or `-s NAME`) shows a file or a definition as
any commit of your clone holds it: a sha, `HEAD~3`, a branch. The text is
read with git and rendered as a working-tree file is; the header says
`(read from local git at <sha>, not indexed)`. Nothing here reaches
commits you have not fetched.

### `ccx ask` — ask a question, get an answer

Every command above returns *material* — hits, lines, symbol rows — and leaves
the reading to you. `ccx ask` returns a **written answer with citations**: a
server-side agent runs the investigation for you, searching, grepping, reading
files, and following symbols, then writes up what it found. Each claim carries
a citation like `[s0:src/app.py#L40-L52]`: `s0` is one of the scopes the command
lists on stderr (`s0: <owner>/<repo> @ <ref> (commit <sha>)`), and the line
numbers are at that commit, so you can open exactly what the agent read. If the
ref moved while the agent was reading it — routine on a busy branch — the scope
line ends with `moved during the investigation: <sha>`: the line numbers may
belong to either commit and, unless the trees were identical, the answer is
not stored for reuse (`scope_moved`). `--json` carries every commit a scope's
reads saw under
`resolved_scopes[].observed_commit_shas`, the bound commit first.

```bash
ccx ask "how does the indexer decide what to re-embed?"
ccx ask "compare how these two services authenticate" --repo acme/a --repo acme/b
ccx ask "walk me through the release flow" --git-ref v1.2
ccx ask "what are the main components?" --effort high
ccx ask --parent 7e3a0012 "and where is that retried?"   # continue a stored answer
ccx ask "what are the main components?" --trace   # show the investigation as a tree
ccx ask "what are the main components?" --json    # exact response model
```

Citations use spans supplied by indexed chunks, definitions, matches, or file
windows. A narrower model-written range expands to the smallest observed
span that contains it. Unsupported ranges display `line range unverified`.
A valid span does not prove the answer's claim.

When a cited file differs in your local checkout, the CLI places
`working tree differs from indexed <sha>` beside that citation. It also
marks unavailable local comparisons. These notes include uncommitted edits.
`--json` preserves the server answer without local notes.

Scoping works exactly like `ccx search`: the current checkout by default,
`--repo` (repeatable) to name repos, `--git-ref` for a single-repo scope. The
answer is Markdown on stdout.

Things to expect:

- **It is slower.** The agent runs many reads before answering — seconds to a
  couple of minutes for a broad question, up to the effort level's deadline
  (10 min by default, 20 min at `--effort high`). Reach for `ccx search`/`grep`
  when you know what you're looking for, and `ccx ask` when you don't. Let it
  finish: stopping the command, or a harness timeout that kills it, cancels
  the investigation on the server and keeps nothing of it, so the next ask
  starts over. A coding agent should start it in the background where its
  harness can wake it on completion; the [skill](#for-agents--automation)
  carries the rule, and the Claude Code plugin states it to each agent.
- **It may be turned off.** It is off unless your deployment enables it,
  because answering requires sending your question and the code the agent
  reads to a model provider. When it's off the command exits non-zero with
  `agent_query_unavailable`; ask your platform team.

- **A repeated question may come back instantly.** If your deployment enables
  the answer cache, asking something already answered — by you or by a
  colleague — returns the stored answer without re-running the investigation,
  and a rephrasing of the same question counts as the same question. A stored
  answer is reused only while the repository's files are unchanged; after a
  change the next ask investigates again, reusing the steps that still apply.
  `--json` reports which happened, under `usage.result_cache_hit`.

#### How much investigation: `--effort`

`--effort low|medium|high` sets how much investigation the question gets. Your
deployment decides what each level means — how many steps the agent may take,
and how long it may run — so the same flag works everywhere:

| Level | Use it for |
|---|---|
| `low` | a lookup with a known shape: where is X, what does Y return |
| `medium` | how-does-this-work questions; the default unless your deployment picked another |
| `high` | architecture, comparison, and multi-repo questions, and asking again after a forced answer |

When the agent runs out of steps — or its model runs out of room — before it
is done, it still answers from what it found, and the answer ends with a
`## Not verified` section listing what it could not check. The command says so
on stderr:

```text
Note: this answer was forced — the session's turn allocation of 30 turns ran
out — so it may be incomplete (it ends with what was not verified); narrow the
question, or ask again with --effort high.
```

When the answer was stored and the turn allocation ran out, the notice also
names the continuation command ([Follow-ups](#follow-ups---parent)).

`--json` carries the level applied as `effort` and how the session ended as
`completion`: `complete`, `forced_turns`, or `forced_context`. A stored answer
that was forced when it was made is reported as forced when it is served.

#### Follow-ups: `--parent`

With the answer cache on, an answer that was stored prints the command for a
follow-up on stderr after it:

```text
follow-up: ccx ask --parent 7e3a0012 "<question>"
```

Run it with your question to continue the conversation instead of asking
afresh:

```bash
ccx ask --parent 7e3a0012 "and where is that retried?"
```

The follow-up is answered with the earlier investigation's evidence already in
context — the investigation is not repeated, only verified against the current
code — and its answer prints its own follow-up command for the next one. Any wording
works: the text is what the agent is told next, not a keyword. What to expect:

- **The scope is the answer's.** A follow-up runs on the same repositories at
  the same branches or tags as the answer it continues, whatever directory you
  run it from; the scope lines show what was bound. Pass `--repo` with
  `--git-ref` only to continue on another branch or tag of one of those
  repositories. `--effort` applies to the follow-up itself.
- **A forced answer is worth continuing.** When the notice says the turn
  allocation ran out, it names the continuation, which keeps the evidence the
  cut-off investigation gathered:
  `ccx ask --parent 7e3a0012 "continue: finish what was not verified"`. When
  the model's context ran out instead, continuing would hit the same wall;
  narrow the question or ask again at `--effort high`.
- **The answer may be a question.** When the question is ambiguous in a way
  the code cannot settle, the answer is a short clarifying question headed
  `## Clarification needed`; answer it with `--parent`.
- **The answer may have gone stale.** A follow-up first re-reads what the
  earlier investigation read and found, against the code as it is now. A
  change that leaves every recorded result the same — the files it read,
  the hits its searches returned — changes nothing; a change that alters
  one is shown to the agent as it is now, and the command prints `note: N
  observation(s) the earlier answer relied on have changed since; this
  answer re-read them.` on stderr — the earlier answer may be stale on those
  points, and the new one has seen the current code. `--json` carries the
  count as `parent_observations_changed`.
- **An id can stop resolving.** `parent_not_found` means no stored answer
  with that id is available here: a wrong id, an answer the cache has since
  dropped (a repository purge, or the cache rebuilt by an upgrade), one made
  under an earlier version of the agent, or one on repositories you cannot
  read. Ask the question afresh.
- **`--json` carries `answer_id`**, `null` when nothing was stored (the answer
  cache is off, or the answer was not stored), in which case the stderr line
  is absent too.
- **Right after a server upgrade**, a follow-up can reach a replica that does
  not know follow-ups yet. `ccx ask --parent` without `--repo` then fails with
  a plain `HTTP 400` saying `repos` is required, and the command says the
  server is mid-upgrade: retry shortly. With `--repo`, that replica answers a
  fresh question about that repository instead; the reply lacks `answer_id`,
  which the command reports as a wire-model mismatch, and the retry is the
  same.

#### Usage and cache statistics

By default the command prints the answer and nothing else. Pass `--stats` to
also see what the request cost and how much of that the cache covered — per
metric, the no-cache total and the share served from storage:

```text
stats: turns 18/30, queries 6 (reused 3 / 50%), model calls 27 (reused 13 / 48%),
input tokens 238142 (reused 105992 / 45%), output tokens 14554
(reused 6610 / 45%), tool calls 73 (reused 38 / 52%), answer stored, 47.8s
```

`turns` is how many of the effort level's steps the agent used. The segment
before the wall time says whether the answer is now stored for
the next identical question: `answer stored`, or `answer not stored
(<reasons>)` — [deploy.md → Answer cache](deploy.md#answer-cache-optional)
lists the reasons. `--json` carries the same under `usage.result_stored` and
`usage.not_stored_reasons`.

A metric with nothing reused shows just its total. The reuse can be partial:
an investigation reuses whatever stored work still applies — whole
sub-answers, or earlier investigation steps re-checked against the current
code — and pays live for the rest. `--json` carries the full breakdown under
`usage.cost` whether or not `--stats` is set.

#### What happened behind the answer: `--trace`

Pass `--trace` to see the investigation as a tree on stderr, after the
answer: one line per step with the tool call on the left and what it
returned on the right, the subqueries nested under the calls that asked
them, and a tag wherever stored work was reused.

```text
trace: medium effort · 7/30 turns · 18.3s
  1  find_definitions s0:authorize_repos                   3 definitions · 0.2s
     "The admission check is the place to start."
  2  read_file s0:python/query-server/src/…/authz.py#L40-L120   81 lines (L40-L120 of 310) · 0.1s
  3  2 calls in parallel                                   5.1s
     "Two separable threads: the middleware order, and the resolver."
     ├─ ask_subquery "Trace the middleware order…"          live · 4 turns · 5.1s
     │    1  code_search "auth middleware order"           8 hits in 3 files · 0.3s
     │    2  read_file s0:python/query-server/src/app.py#L100-L159   60 lines · 0.1s
     │    3  find_references s0:require_scope              14 references · 0.2s
     │    4  answer                                        820 tokens · 3.0s
     └─ ask_subquery "How does _resolve_authorized_repo…"   cached (stored 2026-10-19) · saved 5 model calls, 7 reads
  4  code_grep s0:'def \_(\*) \*:' (python)               12 matches in 4 files · 0.4s
  5  read_file s0:service.py#L600-L639                     40 lines · 0.1s · replayed from a stored turn
  6  answer                                                1,240 tokens · 6.0s
```

How to read it:

- **The header** is the effort level, the turns used over the allocation and
  the wall time. An answer that came whole from the cache says so instead
  (`served from a stored answer (stored <date>) · saved …`), followed by the
  steps its producer ran.
- **The quoted lines** are the agent's own words beside its calls: why it
  did what it did.
- **A subquery** is its own session, nested: `live · N turns · <time>` when
  it ran, `cached (stored <date>) · saved …` when a stored answer served it.
- **Reuse tags**: `replayed from a stored turn` means the decision at that
  step was taken from storage and only the call reran; `planned from stored
  subqueries` marks a first step that split the question into sub-questions
  the cache already had answers for.
- **Rounds the agent spent without advancing** show as what they were: a
  repair round (every call it issued was invalid), a confirmation round, or
  an answer it had to shorten.
- **A follow-up** (`--parent`) lists the earlier answers it continues, one
  line each, with how many of their observations the re-read found changed.

With `--json`, the same tree rides the response under `trace` (and nothing
prints on stderr); without `--trace` the field is `null`. The REST body
takes `include_trace: "tree"`, or `"full"` to include the text of every
observation the agent read. The trace is sent to you alone: the server logs
none of it.

The agent can only read what **you** can already read — it runs under your
identity and the same repository permissions as every other command, so it
never surfaces a repo you couldn't search yourself. That applies to cached
answers too: nothing is served from the cache before your own authorization
has been checked against the repositories in question.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HTTP 401` | Missing or wrong `CCX_API_TOKEN` — it must match a token the server accepts. `ccx status` tests the credential with the index-status request and names its source and fix when rejected. |
| `login: expired and could not be refreshed` (in `ccx status`), or `Your login for … has expired and could not be refreshed` (from any other command) | Your cached SSO login aged out — the IdP's session lifetime, so an overnight gap can do it. The server itself is fine (`status` still reports it healthy). Run `ccx login` again, or `ccx logout` to fall back to `CCX_API_TOKEN`. |
| `HTTP 503` ending in `is being indexed: …` | The repo (or the ref you named) is in its first pass, or committed but not queryable yet. `ccx status --watch` follows it; retry after the `retry in …` the error names, and use your native tools meanwhile. |
| any other `HTTP 503` | Index not built yet — the indexer hasn't populated the table; `ccx status` says whether an indexer has reported; retry once it has (ask your platform team if it persists). |
| connection refused / unreachable | Wrong `CCX_SERVER_URL`, or a `kubectl port-forward` that dropped. Run `ccx config` to see the server it resolved and where that came from. |
| talking to the wrong server | Something outranks your saved default — `--server`, or an exported `CCX_SERVER_URL`. `ccx config` names the source. (A project `.env` is *not* read by `ccx`.) |
| `is writable by other users` | `~/.config/ccx/config.json` decides where your credentials are sent, so a group/world-writable one is refused: `chmod go-w` it. World-*readable* is fine. |
| `no usable keyring backend` | Your token cache is set to `keyring` on a host without one. `ccx config set token-cache auto`, or `CCX_TOKEN_CACHE=file` for one command. |
| `Cannot bind … login callback port` | Every callback port the server advertises is in use on your machine (another `ccx login`, or an unrelated app). Free one, or pin an admin-registered alternative with `--redirect-port`. |
| IdP shows a redirect-URI error at login | The callback port doesn't match an IdP registration — usually a stale `CCX_OIDC_REDIRECT_PORT` or `--redirect-port` overriding the server-advertised ports. Unset it and log in again; ports the server advertises are registered by your admin ([sso.md → Verifying before rollout](sso.md#verifying-before-rollout) ends with the per-IdP error table). |
| login prompts for a client id on an SSO server, or Entra fails with `AADSTS901002` despite `resourceIndicator: false` | Your `ccx` predates server-advertised login settings — upgrade to 0.1.34+: `uv tool install -U cocoindex-code-plus`. |
| `ccx login` warns about login settings it doesn't recognise | The server advertises a setting this CLI is too old to use. Upgrade: `uv tool install -U cocoindex-code-plus`. Login may still succeed meanwhile. |
| a command ends with `ccx <version> is older than the server (<version>)`, or `ccx status` shows `cli: … older than the server` | Your deployment moved to a new release; the CLI and the server release in lockstep. Upgrade: `uv tool install -U cocoindex-code-plus` (and refresh the agent skill, [below](#for-agents--automation)). The line repeats once a day until you do. |

## For agents & automation

- **Agent skill** — [`skills/ccx-codebase-explorer/SKILL.md`](../skills/ccx-codebase-explorer/SKILL.md) teaches a
  coding agent when and how to drive `ccx` (search vs. structural grep vs.
  symbol navigation, scoping, reading empty results). Install it user-level
  with the [skills CLI](https://skills.sh), which detects Claude Code, Codex,
  Cursor, Gemini CLI and others and links the skill into each:

  ```bash
  npx skills add cocoindex-io/cocoindex-code-plus-pub -g -y
  ```

  Keep the `-y`: without it the CLI asks which agents to install to, and on a
  first run Claude Code starts unticked.

  (`npx skills update ccx-codebase-explorer -g` later; or copy the folder to
  `~/.claude/skills/ccx-codebase-explorer`.) The skill checks itself: its
  first step has the agent run `ccx skill-check <revision>` with the revision
  the copy carries, and from **0.1.61 on** the CLI prints one update line, once
  a day, when that copy is older than the one it shipped with — on every host
  that runs the skill, Codex included. The agent relays the line; nothing is
  updated behind your back, and nothing scans your skill directories.
  Installed before 2026-09-05? The
  skill was named `ccx` then and counts as a separate entry — remove it first,
  which also cleans its links in every agent's skills directory:

  ```bash
  npx skills remove ccx -g
  ```

- **Getting an agent to reach for `ccx` unprompted** — an agent decides from
  the skill's description whether a task needs it, and leans toward its
  built-in grep and file reads for anything that looks doable locally. In
  rising order of force:
  1. **The skill alone.** Its description asks the agent to use `ccx` before
     its own grep and file reads whenever it, or you, need to find or
     understand code — where a symbol is defined and used, code matching a
     concept, how something works — including the searches the agent starts
     itself in the middle of an implementation task, and to outline a long
     file with `ccx show` before reading it whole. Expect it to fire on a
     minority of those: a skill that overlaps the host's built-in grep is
     consulted only sometimes, and a machine with dozens of skills can lose
     the description entirely (Claude Code budgets about 1% of the context
     for the skill listing and drops the least-used skills' descriptions
     first; the `skillListingBudgetFraction` setting raises the budget). A
     bare "grep for X" does not trigger it, by design.
  2. **The MCP endpoint** ([below](#mcp-integration)) — its tools sit in the
     agent's tool list on every turn, carrying the same routing guidance from
     the server, so there is nothing to trigger.
  3. **The Claude Code plugin** — reaches the moment the skill cannot: the
     agent's own decision to grep in the middle of a task, in subagents too.
     Its hooks add one line of context, once per agent, when the checkout is
     indexed: at the first repository-wide grep or `rg` (naming `ccx defs`,
     `refs`, `search`, `ask` and `show` with what each answers, the indexed
     commit's position relative to `HEAD`, and which local files still need
     grep); at
     a grep that found nothing or far too much; and when a session or
     subagent starts, where the line also says how to run `ccx ask` there
     (in the background from the main conversation; in the foreground with
     the full ten-minute timeout from a subagent, whose run ending would end
     a background command). In a checkout that is not indexed the hooks stay
     silent. Install it from this repository, which is also a plugin
     marketplace:

     ```text
     /plugin marketplace add cocoindex-io/cocoindex-code-plus-pub
     /plugin install ccx@cocoindex
     ```

     It needs the `ccx` CLI on `PATH` and a login to your deployment (the
     hook runs `ccx indexed`; without either it does nothing). The plugin
     bundles the skill above, so on Claude Code install the plugin *or* the
     `npx skills add` copy, not both — two listing entries for one skill
     spend the listing budget twice. The first hook run in a checkout sends
     that repo's `origin` owner/name and hostname to your server, as any
     `ccx` command would; see
     [security.md → The Claude Code plugin's probe](security.md#the-claude-code-plugins-probe).

     **Updates.** The plugin's manifest pins no version, so Claude Code
     treats every change to this repository as a new plugin version — but
     fetches it only when you ask (`/plugin marketplace update cocoindex`)
     or when auto-update is on for the marketplace, which it is not by
     default for a marketplace you added yourself. Turn it on once: `/plugin`
     → **Marketplaces** → `cocoindex` → **Enable auto-update** (an admin can
     set `"autoUpdate": true` on the marketplace's `extraKnownMarketplaces`
     entry in managed settings instead). Claude Code then refreshes the
     plugin shortly after a session's first message and offers
     `/reload-plugins`. Either way, from `ccx` 0.1.60 on the hook tells you,
     as a warning in the session once a day, when the installed plugin is
     older than your CLI expects. If you moved to the plugin from a skills
     CLI install, remove that copy (`npx skills remove
     ccx-codebase-explorer -g`) so Claude Code lists the skill once.
  4. **One line in the repo's agent instructions** (`AGENTS.md` /
     `CLAUDE.md`), for a team that wants `ccx` used on every task:

     ```markdown
     To find or understand code in this repo — including the searches you start yourself mid-task — run `ccx` (search / grep / defs / refs / show / ask) before grepping or reading files; grep only the files you changed since the indexed commit. See the `ccx-codebase-explorer` skill.
     ```

     Codex follows such a line at once; Claude Code treats it as a preference
     and still greps first at times.
  5. **A `UserPromptSubmit` hook**, when it must be enforced on every prompt:
     its output is added to each user prompt, in `.claude/settings.json`
     (it does not reach subagents; the plugin's hooks do). Word it as a rule
     that names the commands. Measured on six implementation tasks (Claude
     Code, Opus 5.5, 2026-10-09): the skill alone put `ccx` first on none; an
     advisory line ("use the skill before you grep") on two; this rule on all
     six:

     ```json
     {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command",
       "command": "echo 'Rule for this repo: before any repository-wide search (the Grep tool, grep -r, rg), run the equivalent ccx command first and read its result: ccx defs NAME for where a symbol is defined, ccx refs NAME --role call for its callers, ccx search \"<concept>\" for code with no exact term, ccx grep PATTERN -l LANG for a syntactic shape. Use grep only on files you changed since the indexed commit. Before your first search, state in one line which of these you are using and why.'"}]}]}}
     ```

     The line rides every prompt, including ones that never touch code, so
     it is a team's choice rather than the default.
- **Nothing requires a terminal** — export `CCX_SERVER_URL` + `CCX_API_TOKEN` and
  a coding agent or CI job runs `ccx` directly; prompts only ever appear on a
  TTY (without one, a missing setting is a non-zero exit with the flags to
  pass). Errors exit non-zero; informational notes and prompts go to stderr,
  results to stdout. **Export them** — `ccx` does not read `.env` files, so a
  job that keeps its token in a repo `.env` gets `401`s.
- **Token** — use a dedicated API token for the automation; machines keep using
  tokens even when humans sign in via SSO.
- **Sandboxes** — an agent sandbox can block two things `ccx` needs:
  - **Network.** `ccx` talks to the query server (and, on a cached login, to
    your IdP); the error names the failure as a connectivity one, not an
    expired login.
  - **Writing the token file.** On an SSO login, each token refresh saves the
    renewed login to `~/.config/ccx/tokens.json` (the default file cache;
    `ccx config` names it). Once the access token expires — minutes to an
    hour, set by your IdP — a sandbox that blocks that write fails the
    command with a `PermissionError`.

  The OpenAI Codex CLI's default sandbox blocks both. Allow them in
  `~/.codex/config.toml` (or run outside the sandbox):

  ```toml
  [sandbox_workspace_write]
  network_access = true
  writable_roots = ["~/.config/ccx"]
  ```
- **Container option** — for sandboxes without Python, a small `ccx` image is a
  possible future add (track via the release docs).
- **Structured output** — `ccx ask --json` emits the response model; the other
  query commands print formatted text, so agents that want typed results use
  the MCP path below.

## MCP integration

The query server exposes an **MCP** (Model Context Protocol) server over the same
query service, so a coding agent or MCP-capable IDE calls the tools **natively** —
no CLI install, no output parsing. This is the recommended path for agents; the
CLI remains the path for humans and shell scripts. The MCP tools track the CLI
and REST API closely (same capabilities, same scoping).

- **Endpoint:** `<CCX_SERVER_URL>/mcp` (Streamable HTTP; `/mcp/` is the same endpoint).
- **Auth:** the same API token, sent as `Authorization: Bearer <CCX_API_TOKEN>`.
- **Tools** (`git_ref` is a branch/tag name or `heads/<b>` / `tags/<t>`;
  omitted → the repo's default branch, and responses report the resolved ref):
  - `list_repos(limit?, cursor?)` → the accessible indexed repos (stable
    `repo_key` uid + alias + default branch + up to ten indexed refs, each
    with the commit indexed for it), as a cursor walk — the discovery call
    before a search.
  - `code_search(query, repos, top_k?, offset?, paths?, languages?)` → one
    cross-repo-ranked list of code chunks (repo, filename, line range, code,
    score). `repos` is 1..10 scopes `{repo, git_ref?}` — each repo searched
    at its own ref; `resolved_scopes` reports every scope's resolution.
  - `code_grep(pattern, language, repo, git_ref?, paths?, limit?, cursor?)` → AST
    structural matches (filename, line range, node kind, code, captured metavars),
    plus `warnings` (e.g. a pattern in ast-grep's `$NAME` / `$$$` dialect, which
    ccx matches literally; the warning shows the ccx form). Files are scanned
    in a fixed shuffled order; `next_cursor` set means the scan stopped short
    — the page filled (`truncated`) or the server stopped ahead of its
    deadline (a `warnings` entry says so) — and passing it back as `cursor`
    continues from there.
  - `text_grep(pattern, repo, git_ref?, paths?, languages?, case?, whole_word?,
    limit?, cursor?)` → plain-text regex matches over every file of the ref
    (filename, 1-based line, line text), no language named; `case` is `smart`
    (default) / `sensitive` / `insensitive`; `next_cursor` and `warnings` as
    for `code_grep`.
  - `find_definitions(repo, name?|name_path?, qualified?, git_ref?, kinds?,
    languages?, paths?, limit?, offset?)` → where a symbol is defined (path,
    span, kind, qualified name, `entity_id`). `name` is a base name, or with
    `qualified` a pack-tagged qualified name; `name_path` is a member with its
    qualifier (`Repo.find`, `db.Repo.find`, `Store::fetch`) and matches every
    definition whose qualified name ends with it. The response's `coverage`
    states how complete the symbol index is for the ref, and `warnings`
    explains a miss on a dotted `name` sent as a base name (naming the
    `name_path` lookup to run instead).
  - `find_references(repo, path?+entity_id?|qualified_name?|name_path?|base_name?,
    git_ref?, roles?, include_unresolved?, limit?, offset?)` → where a symbol is
    used — one exact definition (`path` + `entity_id` from `find_definitions`),
    every occurrence under a pack-tagged `qualified_name` (e.g.
    `python:db.Repo.find`), every definition a `name_path` matches (e.g.
    `Repo.find`), or by `base_name`; rows carry `resolution` (`resolved` /
    `ambiguous` / `name_only`) and a reference role (`roles` filters on those, a
    different vocabulary from `find_definitions.kinds`), plus the same
    `coverage`. An exact or qualified target that matches no definition fails
    with `target_not_found` (a `name_path` or `base_name` answers an empty
    list); when a `qualified_name` lacks its pack tag (e.g. `Store::fetch`), the
    error says to pass it as `name_path`, or to look its base name up with
    `find_definitions` (`suggested_base_name` in its metadata) and pass a
    result's `path` + `entity_id`.
  - `show_code(repo, path, git_ref?, line?, col?, layer_path?, start_line?,
    end_line?, expand?)` → the MCP form of
    [`ccx show`](#ccx-show--a-files-outline-or-one-definitions-body) over
    the indexed source: the file's outline with no target, the innermost
    object at `line` (and `col`), a layer by `layer_path`, or a verbatim
    `start_line`–`end_line` span; `expand` renders everything verbatim. Each
    object carries its span and gutter-rendered `code`; `structural` is false
    when the language has no structural model (the file is shown whole) and
    `counted_cue` says a large type's own lines were folded to a
    `... N more lines` cue. A `find_definitions` row's `path`, `start_line`,
    `start_col` and `end_line` are its natural arguments.
  - `read_file(repo, path, git_ref?, offset?, limit?)` → a file's line window.
  - `find_files(repo, git_ref?, patterns?, case?, limit?, offset?)` → matching paths.
  - `list_git_refs(repo)` → the repo's indexed refs + each ref's commit sha, and
    the default branch.
  - `ask_codebase(question, repos?, parent?, effort?, include_stats?)` → a
    written, citation-backed answer to a natural-language question — the MCP
    form of [`ccx ask`](#ccx-ask--ask-a-question-get-an-answer).
    A server-side agent investigates with the tools above under the caller's
    own permissions and returns a Markdown answer.
    The tool is always advertised, but **fails with `agent_query_unavailable`
    unless the deployment enables the feature** (answering sends the question
    and the code read to a model provider). It also runs far longer than the
    other tools — up to the effort level's deadline, 600 s by default and
    1200 s at `effort: "high"` — so give the client a generous timeout. In
    Claude Code that is a `timeout` field in milliseconds beside `url` in
    the server's `.mcp.json` entry (`"timeout": 1200000`); it also keeps
    Claude Code's idle timeout, five minutes without a response from a
    network server, from aborting a call while the agent investigates (the
    tool reports no progress meanwhile). A main-conversation call still
    running after two minutes moves to a background task on its own. Prefer
    it for open-ended "how/why" questions and the typed tools above for
    targeted lookups. `effort` takes the same `low` / `medium` / `high` as
    `--effort`. The response always carries `completion`: a `forced_turns` or
    `forced_context` answer was extracted at the limit and may be incomplete,
    so narrow the question or ask again with `effort: "high"`. With the answer
    cache on, a stored answer carries `answer_id`: pass it as `parent` with a
    follow-up question to continue with the investigation's evidence in
    context — `repos` is then optional and only picks the refs of the stored
    scope — and a `forced_turns` answer is worth continuing that way. An
    answer may itself be a clarifying question headed `## Clarification
    needed`; reply the same way. A follow-up re-reads the earlier evidence
    against the current code and continues either way;
    `parent_observations_changed` counts what changed. `parent_not_found`
    means no such stored answer is available here
    ([Follow-ups](#follow-ups---parent)). By default the
    response carries the answer, the resolved scopes, the level, the
    completion, and `answer_id` only; `include_stats: true`
    adds the usage and cache-savings counters, which are operator
    information a querying agent rarely needs.

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
header.) Token auth works on every deployment. On SSO (OIDC) deployments an
MCP client that supports OAuth can instead sign in interactively — the server
advertises standard protected-resource metadata; your IdP admin pre-registers
each approved MCP client. (Exception: Entra-direct deployments cannot serve
interactive MCP sign-in — [sso.md → Entra ID](sso.md#entra-id); key records
still work there.)

## Pull request and issue content

When the repository has a change index, semantic search adds a separate
change section after the code results. Use `ccx search --kind code` for code
only, `--kind change` for change records, or `--kind all` for both. `--json`
keeps the server's change section and freshness data.

Use `ccx prior <file>`, `ccx prior -` with stdin, or `ccx prior "<text>"`
before repeating work from a brief. The command splits bullets, numbered
lines, and paragraphs into items. It searches once per item, up to 20 items.
Each item shows its best record and score. `near` and `weak` use the server's
score floor. These labels describe similarity, not whether work shipped.

Use `ccx refs <name> --kind change --since 2d` for touched and mention groups.
`ccx show` adds `touched by` when the server supplies an annotation. Change
text grep (`ccx grep --text --kind change`) requires slice 4 and is refused
until that slice ships.

Read the freshness line before treating absence as evidence. `insufficient`
means the index cannot establish absence. Use the printed `state:` command
to ask the code host about a record's current state.

The CLI remembers shown and followed record identifiers in its disposable
cache when a session identifier exists. Claude Code's SessionStart hook sets
`CCX_SESSION_ID` through its environment file; Codex supplies `CODEX_THREAD_ID`.
The cache stores no record text, credential, or URL.


### A file has no indexed text

`show --repo`, `show --git-ref`, and `read-file` read the indexed ref.
A missing-file response includes one of these reasons:

- `not_on_ref`: the stored tree does not contain a file at that path.
  Check the path and ref, or read the file locally.
- `not_indexed`: the stored tree contains the file, but the index has no text.
  Read the file locally. Size limits, exclusions, binary files, or Git LFS can cause this.

The index does not store the exact skip reason. A branch-only file or an
excluded subtree can also produce `not_on_ref`.

Use `ccx show FILE:LINE` without `--repo` or `--git-ref` for a local file.
The CLI sends its working-tree text. The indexed file size limit does not apply.


## When an index cannot answer

An empty result is useful only when the index covers the requested files.
`defs`, `refs`, and symbol `show` name up to three relevant skipped or failed
files, with reasons and a local grep fallback. They print this note for
empty results or nearby file paths, rather than on every successful lookup.
Older index rows can report an unavailable skip reason. This does not mean
that the file fails to parse.

An exact `grep --text --path <file>`, file-scoped `show -s`, or `read-file`
request reports a known skipped file as `<file> is not indexed (<reason>); grep it locally`.
Read or grep the working-tree file to continue.

`search --kind change`, `search --kind all`, and `refs --kind change` keep
the freshness line even when their results are empty. `changes: insufficient`
means the backfill cannot settle absence. With no index, the line says
`no change index for <repo>; absence proves nothing — use gh/git log`.

`ask` reads one indexed commit per ref on each code read. It cannot read git
history, blame, or commit diffs. It must not infer which PR introduces code
from the current file. Its last line names relevant files it cannot read,
then says `history questions: use git log / ccx --kind change`.
Check change coverage before you use its results as evidence.
