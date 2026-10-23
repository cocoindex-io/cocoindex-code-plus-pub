# Reading files — `ccx show`, `ccx read-file`, `ccx find-files`

`ccx show` renders a file's **outline** or one definition's **body** from your
working tree (the index only when it must); `ccx read-file` and `ccx find-files`
fetch file **contents** and **paths** exactly as they exist in an indexed ref,
over HTTP, for code you **don't have on disk** — a repo that isn't checked out
locally, or a **different ref** than your working tree.

Repo and ref are auto-detected like every query command (`--repo` / `--git-ref`
to override); a `ccx show` of a file outside any checkout needs no repo.

## show

```bash
ccx show src/app.py                                     # the outline: every definition at its line, bodies folded
ccx show src/app.py:142                                 # the innermost definition at line 142, enclosing scopes as frames
ccx show src/app.py:142:8                               # a pasted `ccx defs` headline (path:line:col)
ccx show src/app.py:142-150                             # a pasted `ccx grep` headline (the first line is used)
ccx show -e src/app.py                                  # everything verbatim: the numbered file
ccx show --depth 1 src/app.py                           # the file's items only, each container collapsed to its head and a `// members:` roster; -e and --depth are exclusive
ccx show -s QueryService                                # the definitions `ccx defs QueryService` finds, rendered
ccx show -s find --kind method src/db.py                # -s narrowed by kind and to one file; -q/-b as on `ccx defs`
ccx show --git-ref main src/app.py                      # request the indexed copy at that ref
ccx show src/app.py --repo acme/api                     # request that repo's indexed copy
```

Each object prints under a header, `<path>  <kind> <layer-path>  L<start>-L<end>  (<provenance>)`,
whose provenance includes `working tree`, `working tree, differs from indexed <ref>@<sha>`
(your file is not what the index holds) or `indexed <ref>@<sha>`. The body's gutter
marks each line: `N:` an exact source line, `N|` a frame (an enclosing scope's head),
`N~` derived text anchored at line N (a folded row such as `def f(a): ... 12 lines`,
which spans lines N to N+11; a doc's first line), ` ~` a cue. A `... N more lines` cue
inside a large type folds that type's own lines; `ccx show -s <name>` or
`ccx show PATH:LINE` shows it whole, its doc included. On an import line,
`ccx show PATH:LINE` prints the imports; on a Rust `mod x;` line, the module's
file. A `lines A-B of PATH not shown` note means the 5,000-line output window
cut there: `ccx show PATH:A` continues. A collapsed container — test code, or
any container below `--depth` — is its head, `// members: a, b, c, +N more` (every
direct member) and `... N lines`; the server folds an outline over about 300 rows
to depth 1 on its own and the CLI notes it (`outline folded to depth 1: the full
outline is N rows; …`), never when you passed `--depth`.

By default the working tree supplies a file that exists locally; the header says `indexed`
when the index served instead (the file is not on disk, is over the 8 MiB request
bound, or `--repo` or `--git-ref` was given). `-s NAME` renders one unique definition.
Several matches are **listed** with paths; pick one with `ccx show PATH:LINE`,
or add a file path after `-s NAME` to narrow the lookup. A stderr
note says to narrow with a PATH after the name, `--kind`, or `ccx show PATH:LINE` on
one headline. `-s` with no match exits 1 (unlike `ccx defs`, whose empty page is a result) and prints the
server's warning when the name was spelled for another selector. A `no structure for
this language` note means the whole file was shown, numbered.

## read-file

```bash
ccx read-file README.md                                 # print a file at the ref
ccx read-file src/app.py --offset 40 --limit 20         # a line window
ccx read-file src/app.py --git-ref v1.2                 # the file as of another ref
```

`--offset` is a **1-based line number** here and `--limit` a line count (a
window), unlike `find-files` where `--offset` is a pagination skip count (`grep` pages with `--cursor`).
A long file comes back one bounded window at a time; a stderr note says
`(showing lines A-B of N; continue with --offset B+1)`.

## find-files

```bash
ccx find-files "*.py"                                    # every .py at any depth (`*` spans `/`)
ccx find-files "src/*.py" --case insensitive            # smart (default) | sensitive | insensitive
ccx find-files --git-ref v1.2                           # every indexed path at that ref, a page at a time
```

Several repo-relative globs can be given. `*` spans `/`, so `src/*.py` reaches
every depth under `src/`; a `**/` segment demands one more directory level and
misses top-level files. `--limit` (default 100) and `--offset` page, and a stderr
note (`… N total (showing 100)`) means there are more. Useful before a
`--git-ref`-scoped `read-file`, or to compare paths across refs.
