# Toit Formatter — Design

## Goals

- **Correctness**: the formatter never changes semantics. Enforced, not hoped:
  every format re-parses its own output and checks structural AST equivalence
  plus comment preservation; on mismatch the file is not written.
- **Determinism**: output is a function of (AST + attached trivia + style).
  Two AST-equivalent inputs with the same comments and blank-line structure
  produce byte-identical output, regardless of how the source was laid out.
- **Idempotence**: follows from determinism — `format(format(x)) == format(x)`
  because the second run sees the same AST and trivia.
- **Position-independent layout**: a node's layout depends on its own flat
  width, not on its absolute column. Moving code into deeper nesting does not
  reflow it (better diffs, stable layout). Deeply indented code may run past
  the nominal width rather than being squeezed; a damped absolute backstop
  caps the drift.
- **No hardcoded style scatter**: every layout opinion lives in one
  `FormatStyle` struct (widths, indents, break shapes), calibrated against
  the reference corpus (`artemis/src`).

## Architecture

Three passes over a parsed `ast::Unit`, replacing the previous
incremental-rewrite formatter (verbatim byte-copy with per-construct
canonicalisation):

```
parse  →  attach trivia  →  lower to Doc IR  →  print  →  verify  →  write
```

### Pass 1 — trivia attachment (`format_trivia`)

The AST carries no comments or blank lines. This pass routes every
`Scanner::Comment` and every blank-line run to an AST node, so later passes
never look at source bytes for layout decisions.

Attachment slots are the *list positions* the printer knows how to render:
unit-level declarations, class members, body statements, call arguments,
collection elements, parameters. Rules:

- Comment alone on its line(s) → **leading** trivia of the next slot node
  (or **dangling** at the end of the enclosing list if no next node).
- Comment after code on the same line (EOL `//`, trailing `/*..*/`) →
  **trailing** trivia of the slot node ending on that line.
- Comment *inside* a slot node but not on a slot boundary (e.g.
  `x := foo /* here */ + bar`) → the node is marked **frozen**: it is
  printed verbatim from source bytes (Δ-indented only). This is the single
  escape hatch; it is one rule in one place, not a guard per emitter.
- Toitdoc `/** .. */` comments are leading trivia of their declaration.
- Blank-line runs between slot siblings are recorded as a
  `blank_lines_before` count on the following node (capped by style;
  preserved by default — blank lines are author intent).

### Pass 2 — lowering (`format_lower`)

One function per AST node kind produces a **Doc** tree. All Toit-specific
knowledge lives here: spacing that is semantically load-bearing, paren
insertion, and which break shapes are legal under Toit's
indentation-sensitive grammar (see "Parser contract" below).

### Pass 3 — printing (`format_doc`)

A Wadler-style document printer with a node-relative width policy.

Doc combinators:

- `text(bytes)` — atomic single-line text (source slices or synthesized).
- `verbatim(bytes)` — multi-line source text whose interior lines must not
  be re-indented (multi-line strings, frozen statements).
- `concat(children)`
- `group(child, budget)` — the unit of flat-vs-broken choice.
- `indent(n, child)` — adds `n` to the indentation of lines opened inside.
- `line(sep)` — newline when broken, `sep` (usually one space) when flat.
- `softline` — newline when broken, nothing when flat.
- `hardline` — always a newline; forces every enclosing group broken.
- `if_broken(then, else)` — renders `then` when the nearest enclosing group
  is broken, `else` when flat (needed where Toit's grammar wants different
  *tokens* per mode, e.g. parens around call args).

Fit policy (the part that differs from Prettier): a group renders flat iff

```
flat_width(group) <= budget                          // node-relative
&& start_col + flat_width(group) <= max_width + min(start_col, slack)
```

`flat_width` is computed bottom-up and cached; a `hardline` or multi-line
`verbatim` inside makes it infinite. The first condition makes layout
position-independent; the second is the damped backstop that lets indented
code drift right by at most `slack` columns. Printing is a single linear
walk; there is no backtracking and no budget threading through the lowering.

### Verification (kept from the previous implementation)

- `ast_equivalence.{h,cc}`: re-parse the output, compare ASTs modulo trivia
  and `Parenthesis`. Unchanged.
- **New**: comment preservation — compare the scanner comment sequence
  (normalized text) of input and output. Closes the one hole AST
  equivalence cannot see.
- Opt out with `TOIT_FORMAT_NO_VERIFY=1` (debugging only).

## Parser contract

Layout-relevant facts about Toit's grammar, established by reading
`parser.cc` and enforced by the round-trip verifier. The lowering must obey
these; each is a comment at its point of use:

1. **Calls are greedy.** A same-line call argument is parsed at
   `PRECEDENCE_ASSIGNMENT`, so it absorbs binary operators
   (`foo 10 << 2` is `foo (10 << 2)` — one argument). A call that is not at
   statement level must be parenthesized or it swallows its context.
2. **Newline arguments are full expressions.** In a broken call, every
   argument on its own continuation line is parsed as a complete expression:
   bare nested calls and binaries need no parens there. All newline
   arguments must share one indentation, and once one argument is on a new
   line all following ones must be too. Two positional args on one
   continuation line nest (`f a\n  c d` makes `c d` a single argument).
3. **Breaking a left-assoc binary chain with trailing operators changes the
   AST**: an at-newline RHS is parsed as a full expression, right-nesting
   the chain. Leading operators (`a\n    + b`) preserve left-nesting.
   `and`/`or`/assignment are right-assoc, where trailing operators are safe.
4. **`and` / `or` operands are statement-level boundaries** (parsed via
   `parse_call` directly): bare calls on either side need no parens.
   Same for the operand of keyword `not`.
5. **Minus spacing is semantic.** ` -x` (detached-attached) is prefix minus;
   `a - b` is binary. The printer must keep binary `-` space-padded and
   prefix `-` glued.
6. **Blank lines after an empty-body `foo:` are load-bearing** — the parser
   uses them to decide whether the next line is a body statement or a
   sibling member. Trivia attachment keeps them.
7. **Block-arg `:` placement is indentation-checked** against the call's
   construct indentation; the suite body must be indented deeper than the
   *statement*, not the `:` line.
8. **`{}` is a Set; the empty map is `{:}`.**
9. **`Foo.bar` vs `(Foo).bar` cannot be distinguished without a resolver** —
   source parens on receivers are preserved, never synthesized.

## Style (calibrated on artemis/src, 74 files)

All in `FormatStyle`; corpus evidence in parentheses:

- `indent_step = 2` — suites, control-flow bodies, block/lambda bodies,
  collection elements.
- `continuation_step = 4` — broken call args, wrapped method params, broken
  class-header clauses, broken binary chains (576 occurrences of +4 vs 7 of
  +2 for named-arg continuations).
- `max_width = 100`, `slack = 20` (p99 of all lines = 93, p99.9 = 120).
- Inline suites (`if c: body`, `while`, method bodies, `list.do: it`)
  use the tighter `inline_suite_width = 60` judged against the whole
  construct, plus `max_inline_suite_tokens = 10` — packing two semantic
  chunks on one line is harder to scan than one wide expression. A body
  that itself contains a suite never inlines: at most one suite `:` per
  line.
- When a method header wraps, the body-separator `:` goes on its own
  line at the method's indent.
- Binary arguments on a call's line get parens
  (`foo (end - start)` — bare binaries read as several arguments);
  arguments on their own continuation lines stay bare.
- In a mixed `and`/`or` chain, a nested chain gets parens exactly when
  it breaks (its continuation lines would hide the nesting); the outer
  chain's break points are preferred, so this is rare.
- Broken calls keep the leading positional run on the target's line;
  named arguments each get a continuation line.
- Broken binary chains use **leading** operators (AST-safe for left-assoc,
  see contract #3; uniform across operators).
- Collection literals: broken form puts each element at `indent_step`,
  trailing comma, closing bracket at the opening line's indent.
  `if_broken` supplies the trailing comma.
- No vertical alignment is generated or preserved (one-line changes must
  not reflow neighbours).
- Field/param spacing: `name/Type := value` — no spaces around `/`.
- Method headers: single line if it fits; otherwise return type stays on
  the name's line and each parameter gets its own continuation line, `:`
  after the last.
- Blank lines: preserved as written (capped at `max_blank_lines = 2`).

## Decision procedure for new style questions

1. Measure the reference corpus. Clear majority (~70%+) → match it.
2. Ambiguous → the simpler rule wins; the corpus converges after re-runs.
3. Where AST safety and corpus majority conflict, AST safety wins
   (e.g. leading operators in broken chains).

## Scope markers

- No CST. The AST plus attached trivia is the substrate; missing
  `full_range` precision is fixed in the parser, not worked around.
- No backtracking in the printer; if a layout seems to need it, the node's
  lowering is wrong.
- The resolver-dependent paren decision (contract #9) stays conservative
  until a resolver pass is available.
- Frozen statements (interior comments) are the only verbatim escape hatch.
