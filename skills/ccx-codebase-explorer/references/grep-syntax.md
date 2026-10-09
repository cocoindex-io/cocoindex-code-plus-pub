# `ccx grep` — AST Pattern Syntax

`ccx grep` matches a **by-example pattern against the syntax tree (AST)** of indexed
source — not its text. You write the code you're looking for and blank out the parts
that vary with **metavariables**. SKILL.md has the essentials and the loosening
ladder; this is the full pattern language, with the gotchas that turn a
correct-looking pattern into a silent zero.

```bash
ccx grep '<pattern>' -l <language> [--repo o/r] [--git-ref <ref>] [--path 'glob'] [-k N] [--offset N]
```

Only `-l/--language` is required; repo and ref are auto-detected like every query
command. Running from a *subdirectory* of a checkout defaults `--path` to that
subtree (pass `--path '*'` for the whole repo).

---

## The mental model — read this first

Four facts explain almost every surprising result:

1. **You match the AST, not text.** Nodes, not characters. Formatting, extra
   whitespace, and line breaks never matter; content inside comments and string
   literals is never matched as code.
2. **`\` is the only special character.** Everything else in the pattern is literal
   code. A metavariable is `\` followed by a name or a short-form symbol. A literal
   backslash in target code is written `\\` (otherwise `\d` reads as a capture named
   `d`); a bare `_` is the literal identifier `_` — the metavar is `\_`.
3. **A pattern matches a *fragment*, child-aligned.** The pattern covers a contiguous
   run of a node's children; the reported span is exactly what the pattern covers —
   **not** the enclosing statement. `for \X in ast.walk(\*)` reports the loop *header*,
   not the body.
4. **Trailing delimiters are free; closers are significant.** A trailing `;` or `,` at
   the *end* of a pattern is ignored (`if (\X) return \Y` matches `if (c) return foo;`,
   inside `\{{ … \}}` too), but a closing `)` / `}` / `]` is never skipped: `f(\X`
   will **not** match `f(a)` (otherwise `foo(\X)` would creep onto `foo(a).bar()`).
   **Always close your brackets.**

---

## Metavariables — the shipped forms

**Anonymous forms first.** For plain searching, `\_` (one node) and `\*` (a sibling
run) cover most patterns — a *name* adds nothing unless you want the capture
reported or you reuse it as a backreference (below). Prefer `\*` inside brackets
(an argument list is several nodes, so `f(\_)` only matches single-argument calls)
and `\_` for a genuine single slot (a receiver, one operand).

| Pattern | Meaning | Example |
|---|---|---|
| `\_` | **one** node, anonymous (any node, not captured) | `\_.method(\*)` → a call on any receiver |
| `\NAME` | capture **one** node, reported as `NAME` | `foo(\X)` → captures the argument as `X` |
| `\(NAME\)` | same as `\NAME` (explicit form) | `foo(\(X\))` |
| `\*` | a **run** of zero-or-more sibling nodes | `f(\*)` → a call with any arguments |
| `\+` | a run of **one**-or-more siblings | `[\+]` → a non-empty list literal |
| `\?` | an **optional** node (zero or one) | |
| `\(NAME*\)` / `\(NAME+\)` / `\(NAME?\)` | a captured run / non-empty run / optional | `def \F(\(ARGS*\)):` → captures the param list |
| `\/re/` | **one** node whose text matches regex `re` (anchored `^(?:re)$`) | `\/get_.*/(\*)` → a call to any `get_*` function |
| `\(NAME:/re/\)` | capture one node whose text matches `re` | `\(M:/foo|bar/\)` |
| `\(NAME:/re/*\)` | capture a run of nodes **each** matching `re` | |

Names are `[A-Za-z0-9_]+`. A single-node term matches *any* node — including a bare
keyword/operator leaf — so `\/if|while/` matches the `if`/`while` keyword itself.
Text inside `\/…/` reaches the regex engine as written; only a literal `/` needs
`\/`: `\/"\/project\/file.*"/`.

### Backreferences — reuse a name to require equal text

Repeating a captured name requires the two nodes to have **equal text**:

```bash
ccx grep 'catch (\E) \{{ throw \E \}}' -l typescript   # re-throw the SAME var it caught
ccx grep '\N === \A || \N === \B'      -l javascript    # same value tested twice
```

---

## Scope: containment (`\{{ }}`) and whole-node (`\{ }`)

The default fragment match sits between two tighter/looser scopes:

- **`\{{ INNER \}}` — "has" (containment).** Brackets exactly one node and asserts
  `INNER` matches some **descendant** of it, at any depth.

  ```bash
  ccx grep 'for \* \{{ panic!(\*) \}}'        -l rust    # a loop that can panic
  ccx grep 'switch (\X) \{{ case \Y: return \Z \}}' -l c # a switch with a returning case
  ```

- **`\{ P \}` — "is" (whole node).** `P` must match an **entire** node (anchored, no
  fragment tolerance). Use it to assert completeness — e.g. an `if` with **no `else`**:

  ```bash
  ccx grep '\{ if (\X) { \Y } \}' -l c    # whole-node coverage ⇒ no else branch
  ```

**Anchor containment, or it's slow on a big repo.** `\{{ INNER \}}` checks every
descendant of every candidate node, so give the *outer* pattern a real identifier to
prefilter on — `fn write_ident(\*) \{{ ".." \}}`, not `\{{ ".." \}}` or
`fn \_(\*) \{{ ".." \}}` (a string literal is not a prefilter term; those scan the
whole corpus) — or narrow the file set with `--path`. To find code that merely
*mentions* a concept, prefer `ccx search`.

---

## Gotchas

These are the common reasons a *correct-looking* pattern returns **0 matches**.

### 1. Containment needs the structural lead-in
`try \{{ \X = ast.parse(\*) \}}` → **0**. `try: \{{ … \}}` → matches. In Python a
`try` statement is `try` `:` `block`; `\{{` brackets the node *immediately following*
the preceding tokens, so without the `:` it brackets the `:`, not the body. **Include
the lead-in** (the `:`), or start the containment at the construct that owns the block.
Same for a def — `def foo(\*) \*: \{{ … \}}`, with the `\*` before the colon (see 3).

### 2. Qualified names: match the whole path
`make_unique<\X>(\*)` → **0** on `std::make_unique<…>(…)`. The call's *function* child
is the entire qualified id `std::make_unique<…>`; the args are a sibling of that whole
node. **Include the full qualifier** (`std::make_unique<\X>(\*)`) or capture it
(`\Q::make_unique<\X>(\*)`).

### 3. A pattern reports the span it covers, not the enclosing statement
`for \X in ast.walk(\*)` matches but reports only the header `for node in ast.walk(tree)`.
To require something in the body, use containment: `for \X in \Y \{{ … \}}`.

Use this deliberately to control how much the output *shows*: extend the pattern to
cover what you want to read. `def parse_config(\*) \*:` prints only the header;
`def parse_config(\*) \*: \*` covers — and prints — the whole function including its
body (often saving a follow-up file read). The `\*` between `)` and `:` matters: a
return annotation `-> T` is two sibling nodes there, so `def parse_config(\*):` matches
only an **un-annotated** def — in a typed codebase that is **0** hits, silently
(`\?` does not cover it either: it spans one node, the annotation is two).

### 4. A literal closer after a metavar must structurally follow it
`if \C { \X = \Y }` → **0** on `if c { x = 1; }`, because the source has `x = 1` **`;`**
`}` — the `;` sits between `\Y` and the `}`, and the trailing-delimiter tolerance only
applies at the *end* of a pattern, not mid-pattern. Fix: account for the terminator
(`{ \X = \Y; }`), add a wildcard (`{ \X = \Y \* }`), or use containment (`\{{ \X = \Y \}}`).

### 5. Never escape literal code (no sed/regex-style escaping)
`class Call\(\_\):` → **0**; the right form is `class Call(\_):`. `\` is not an escape
character here — it *introduces* pattern constructs, and `\(…\)` is the explicit
metavariable delimiter. Literal parens, brackets, and braces are written as-is. If a
regex habit makes you reach for `\(`, stop: you're turning your literal code into a
metavar and the pattern will silently match nothing.

### 6. A string literal is one atomic node — wildcards can't reach inside
Matching is at **lexer-token boundaries**: a string literal is one token, so a
literal string in the pattern matches only the **full** literal, and `\*`/`\_` can't
reach inside one. Two consequences:

- `open("config")` → **0** on `open("app_config.yaml")` — partial content needs a
  **regex metavar** whose regex covers the quotes: `open(\/".*config.*"/)`.
- `@\R.\M("/project/file\*")` → **0** — `\*` doesn't glob inside a string; write
  `@\R.\M(\/"\/project\/file.*"/)` instead. (The node's text includes the quote
  characters, so anchor the regex around them, and write `/` as `\/` inside it.)

---

## When you get 0 matches

Structural match is **literal about structure**: a wrong guess returns empty, never a
fuzzy near-miss. Follow the loosening ladder in SKILL.md — blank out what you're least
sure of; `X(\*)` when unsure whether `X` is defined or only called here; check the
CWD-subtree note; then pivot to `ccx search` for the concept and grep structurally
around what it finds. Wrapping the whole pattern in `\{{ … \}}` does not broaden a
top-level match, and a bare identifier with no metavariable is a text grep that
floods hits.

---

## Verified recipes (Python examples; the shapes generalize)

| Intent | Pattern |
|---|---|
| every function def (incl. `async`, decorated, `-> T` annotated) | `def \_(\*) \*:` |
| the def of `X`, whatever its signature | `def X(\*) \*:` |
| the def of `X` *with its body shown* | `def X(\*) \*: \*` |
| calls of `X` (also matches its def header) | `X(\*)` |
| every class, with or without a base list | `class \_\?:` |
| classes deriving from `Base` | `class \_(\*Base\*):` — or just `class \_(\*):` and read |
| `isinstance` checks | `isinstance(\_, \_)` |
| a method call on any receiver | `\_.method(\*)` |
| calls to any `get_*` function | `\/get_.*/(\*)` |
| a call whose string argument contains `config` | `open(\/".*config.*"/)` |
| an `except … as e:` whose body re-raises | `except \_ as \E: \{{ raise \* \}}` (`raise \E` for the same object) |

## More worked examples

```bash
ccx grep 'Err(\_) if \*' -l rust                              # a match arm with a guard
ccx grep '\_?.closest(\*) ?? null' -l typescript              # optional chaining + nullish fallback
ccx grep 'template <typename \T, typename... \TS>' -l c++     # variadic template header (the `...` pack is structural)
```

---

## Not implemented

Alternation / grouping inside a metavariable (`\( if | while \)`), sub-patterns
`\[ … \]`, separated lists `%`, and exclusion `\!( … \)` are not implemented — and
they do not error: the sigil is read as literal text, so the pattern **silently
matches nothing**. (A node-kind matcher `\(NAME:kind\)` does error.) For
alternatives, run two greps or match a keyword leaf with a regex term
(`\/if|while/`); otherwise fall back to a broader grep plus `ccx search`.
