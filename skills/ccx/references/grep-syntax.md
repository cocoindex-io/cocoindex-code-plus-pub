# `ccx grep` — AST Pattern Syntax

`ccx grep` matches a **by-example pattern against the syntax tree (AST)** of indexed
source — not its text. You write the code you're looking for and blank out the parts
that vary with **metavariables**. Because matching is structural, it's whitespace- and
comment-insensitive, and it can express things regex can't (balanced generics, "a
`catch` that re-throws the same variable", "an `if` with no `else`").

```bash
ccx grep '<pattern>' -l <language> [--repo o/r] [--git-ref <ref>] [--path 'glob'] [-k N] [--offset N]
```

Only `-l/--language` is required; the repo is auto-detected from the git checkout
(or `--repo`), and the ref defaults to your checked-out branch / the repo's default
branch (`--git-ref` takes a bare branch/tag name to override). `--path` is
repeatable — and note that running from a *subdirectory* of a checkout defaults
`--path` to that subtree (pass `--path '*'` for the whole repo).

---

## The mental model — read this first

Four facts explain almost every surprising result:

1. **You match the AST, not text.** Nodes, not characters. Formatting, extra
   whitespace, and line breaks never matter; content inside comments and string
   literals is never matched as code.
2. **`\` is the only special character.** Everything else in the pattern is literal
   code. A metavariable is `\` followed by a name or a short-form symbol. (A literal
   backslash in target code must be written `\\`.)
3. **A pattern matches a *fragment*, child-aligned.** The pattern covers a contiguous
   run of a node's children; the reported span is exactly what the pattern covers —
   **not** the enclosing statement. `for \X in ast.walk(\*)` reports the loop *header*,
   not the body.
4. **Trailing delimiters are free; closers are significant.** A trailing `;` or `,` at
   the *end* of a pattern is ignored (`if (\X) return \Y` matches `if (c) return foo;`),
   but a closing `)` / `}` / `]` is never skipped — always close your brackets.

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

### Backreferences — reuse a name to require equal text

Repeating a captured name requires the two nodes to have **equal text**:

```bash
ccx grep 'catch (\E) \{{ throw \E \}}' -l java   # re-throw the SAME var it caught
ccx grep '\N === \A || \N === \B'      -l javascript    # same value tested twice
```

This is the headline structural feature — awkward or impossible in regex.

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

Order of tightness: `\{ P \}` (is) ⊂ default fragment ⊂ `\{{ P \}}` (has).

---

## Gotchas (these tripped up the authors too)

These are the common reasons a *correct-looking* pattern returns **0 matches**.

### 1. Containment needs the structural lead-in
`try \{{ \X = ast.parse(\*) \}}` → **0**. `try: \{{ … \}}` → matches. In Python a
`try` statement is `try` `:` `block`; `\{{` brackets the node *immediately following*
the preceding tokens, so without the `:` it brackets the `:`, not the body. **Include
the lead-in** (the `:`), or start the containment at the construct that owns the block.
Same for `def foo(): \{{ … \}}`.

### 2. Qualified names: match the whole path
`make_unique<\X>(\*)` → **0** on `std::make_unique<…>(…)`. The call's *function* child
is the entire qualified id `std::make_unique<…>`; the args are a sibling of that whole
node. **Include the full qualifier** (`std::make_unique<\X>(\*)`) or capture it
(`\Q::make_unique<\X>(\*)`).

### 3. A pattern reports the span it covers, not the enclosing statement
`for \X in ast.walk(\*)` matches but reports only the header `for node in ast.walk(tree)`.
To require something in the body, use containment: `for \X in \Y \{{ … \}}`.

### 4. A literal closer after a metavar must structurally follow it
`if \C { \X = \Y }` → **0** on `if c { x = 1; }`, because the source has `x = 1` **`;`**
`}` — the `;` sits between `\Y` and the `}`, and the trailing-delimiter tolerance only
applies at the *end* of a pattern, not mid-pattern. Fix: account for the terminator
(`{ \X = \Y; }`), add a wildcard (`{ \X = \Y \* }`), or use containment (`\{{ \X = \Y \}}`).

### 5. Trailing delimiters yes, closers no
Omit trailing `;`/`,` freely (`if (\X) return \Y` matches `… return foo;`, and this holds
inside `\{{ … \}}` too). But `f(\X` will **not** match `f(a)` — `)` is a closer and is
never skipped (otherwise `foo(\X)` would creep onto `foo(a).bar()`). **Always close your
brackets.**

### 6. Backslashes and underscores
`\` is the sole sigil: a literal backslash in target code is `\\` (otherwise `\d` reads
as a capture named `d`). A bare `_` is the literal identifier `_`; the metavar is `\_`.

### 7. Never escape literal code (no sed/regex-style escaping)
`class Call\(\_\):` → **0**; the right form is `class Call(\_):`. `\` is not an escape
character here — it *introduces* pattern constructs, and `\(…\)` is the explicit
metavariable delimiter. Literal parens, brackets, and braces are written as-is. If a
regex habit makes you reach for `\(`, stop: you're turning your literal code into a
metavar and the pattern will silently match nothing.

### 8. A string literal is one atomic node — wildcards can't reach inside
`@\R.\M("/project/file\*")` → **0**: `\*` doesn't glob inside a string, and string
*contents* are never matched as code. Match a string literal exactly, or use a **regex
metavar** whose regex covers the quotes: `app.get(\/"\/project.*"/)` matches
`app.get("/project/files")`. (The node's text includes the quote characters.)

---

## When you get 0 matches — the broadening ladder

Structural match is **literal about structure**: a wrong guess returns empty, never a
fuzzy near-miss. An empty result is information ("nothing has this exact shape"), and
the fix is to *loosen the structure*, not abandon it:

1. **Blank out what you're least sure of** — `\_` / `\*` / `\?` for varying parts, a
   regex metavar for a name you half-know (`\/get_.*/(\*)`).
2. **Def vs. call unsure?** `X(\*)` matches both the def header and every call site —
   the right probe when `def X(\*):` came back empty (maybe `X` is only *called* here).
3. **Check the scope** — a stderr note about a CWD-subtree `--path` means you searched
   part of the repo; `--path '*'` widens.
4. **Still nothing** → the shape genuinely isn't in the corpus; pivot to `ccx search`
   for the concept, then grep structurally around what it finds.

Anti-patterns that do **not** broaden: wrapping the whole pattern in `\{{ … \}}`
(containment around the top-level pattern is a no-op), and dropping to a bare
identifier with no metavariable (that's a text grep — it floods hits and throws away
all structure).

---

## Verified recipes (Python examples; the shapes generalize)

| Intent | Pattern |
|---|---|
| every function def (incl. `async`, decorated) | `def \_(\*):` |
| the def of `X`, whatever its signature | `def X(\*):` |
| calls of `X` (also matches its def header) | `X(\*)` |
| every class, with or without a base list | `class \_\?:` |
| classes deriving from `Base` | `class \_(\*Base\*):` — or just `class \_(\*):` and read |
| `isinstance` checks | `isinstance(\_, \_)` |
| a method call on any receiver | `\_.method(\*)` |
| calls to any `get_*` function | `\/get_.*/(\*)` |
| a call with a specific string argument | `open(\/"config.*"/)` |

## More worked examples

```bash
# Find a fluent chain
ccx grep '\_.filter(\*).map(\*)' -l rust

# A Rust match arm with a guard
ccx grep 'Err(\_) if \*' -l rust

# Optional chaining + nullish fallback (JS/TS)
ccx grep '\_?.closest(\*) ?? null' -l typescript

# A 4-deep nullish-coalescing chain
ccx grep '\_ ?? \_ ?? \_ ?? \_' -l typescript

# Variadic C++ template header (the `...` pack is structural)
ccx grep 'template <typename \T, typename... \TS>' -l c++

# A call taking a lambda that returns
ccx grep 'erase_if(\X, [&](\*) \{{ return \* \}})' -l c++
```

---

## Not yet supported (don't reach for these)

The grammar is locked but only the subset above is **implemented**. These designed
features do **not** work today — patterns using them won't parse or won't match:

- **Alternation / grouping** inside a metavar — `\( if | while \)`, `\((\{A\}|\{B\})*\)`.
  To match alternative keywords today, run two greps or use a regex term where it fits
  (`\/if|while/` works *as a single-node text match* on the keyword leaf).
- **Sub-patterns** `\[ … \]`, **the explicit any-node term** `\(.\)` / `\(NAME:.\)`
  (use `\_` / `\X` instead — a bare `.` in a pattern is a literal dot).
- **Separated lists** `%` / `%%`, and **exclusion** `\!( … \)` / `\!{{` / `\!}}`.
- **Node-kind matchers** `\(NAME:kind\)`.

When a pattern gets too complex for the shipped subset, fall back to a broader grep
plus `ccx search`, or read the candidate files with `ccx read-file`.
