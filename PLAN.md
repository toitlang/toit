# Toit Formatter — Plan

## Goals (unchanged)

- **Correctness**: formatter never changes semantics.
- **Idempotence**: `format(format(x)) == format(x)`.
- **No hard line limit**: soft width heuristics per node kind, deeper nodes may go further right.
- **No backtracking**: inside-out layout. Each subtree decides its own shape from its own content and a local node-kind heuristic; parents don't pass budgets down.

## Architecture (recap)

- **Shape** `{first_line_width, max_width, height}` — already in place. A parent only sees a shape, never a budget from above.
- **Frozen subtrees** report their shape from preserved source. Parents don't distinguish.
- **Co-walked comments**: sorted comment list advances in lockstep with the AST walk. No sidecar data structure. (Not yet implemented beyond verbatim passthrough.)
- **Vocabulary**: "suite" / "indented region" for what other languages call a code block. "Block" in Toit means a closure.

## Done (M0–M5)

- **M0**: `format_unit` is an identity; ctest harness exists under `tests/formatter/`.
- **M1**: `Formatter` class walks top-level nodes; output byte-identical to input.
- **M2**: indentation recomputed from AST nesting for `Class` members and `Method` bodies. Δ-shifted continuation lines. Control-flow bodies still ride with their enclosing statement.
- **M3**: `Shape` struct + `shape_from_source_range` infrastructure.
- **M4**: first real layout decision — flat `Call` emitted with canonical single-space separators. Verbatim-equality check retired; idempotence remains the permanent invariant.
- **M5**: dogfooded over all 144 files under `lib/`. Fixed two correctness bugs (Block-argument spacing, Index/IndexSlice receiver drop). Test corpus expanded to the full `lib/` tree.

## Tiers ahead

Tiers are ordered by a mix of frequency-in-code, blast radius, and unblocks-later. Each tier is a small group of commits, not one.

### Tier 1 — expand the safe set (low risk, opens coverage)

Goal: more Calls become canonicalizable without touching the layout logic.

- Add `Dot`, `Unary`, `Parenthesis`, `Return`, `LiteralStringInterpolation` to `has_reliable_full_range`. Verify each case empirically (their `full_range` actually covers the full source span).
- `Parameter` and `NamedArgument` as arguments, where applicable.
- Fix the `Index` / `IndexSlice` AST bug (full_range excludes the receiver). Cleaner than carrying the workaround forward — Tier 3 will hit these expressions constantly.

### Tier 2 — close the indentation hole

Goal: every indented region gets re-indented, not just class/method bodies.

- Recurse into `If` / `While` / `For` / `TryFinally` body suites the same way `Method` already does.
- Recurse into `Block` and `Lambda` bodies. `list.do: | x | body` is one of the most common idioms; getting blocks right unblocks a lot of real code.
- `Sequence` itself becomes the generic "suite" emitter that every body-bearing node calls into.

### Tier 3 — always-flat mode with paren insertion

Goal: nail paren correctness in isolation, before any width heuristic can muddy it.

- Build flat emission for every expression kind: `Binary`, `Dot`, broken `Call` → flat, collection literals, etc. Assume infinite width — the only decision per composite is "do I need parens around this child to keep the re-parse semantically equal."
- Expose an `--flat-test` CLI flag (or similar) that forces always-flat mode. Used by tests, not by default.
- **Ship a structural AST-equivalence check** (parse S, parse format(S), compare modulo trivia/parens). This is the only real validation that always-flat preserves semantics — without it we're flying blind.
- Run over the whole `lib/` tree under `--flat-test`. Every file must round-trip through AST-equivalence. This establishes the paren rules are correct.
- Keep `--flat-test` in CI permanently. Any future regression in paren handling gets caught immediately, independent of layout heuristics.

### Tier 4 — width-based flat/broken decisions

Goal: produce actually pleasant output. Paren correctness already nailed down by Tier 3.

- Introduce per-node soft-width thresholds. Flat if it fits, broken if it doesn't.
- Broken-form emissions: canonical continuation indent (+4 for Call args, operator-aligned for Binary chains, etc.).
- When transitioning flat→broken, drop parens that the indentation now disambiguates.
- Start thresholds generous, dogfood, tune. Don't start with "I bet 80 is right."

### Tier 5 — collection literals and polish

- `LiteralList`, `LiteralMap`, `LiteralSet`, `LiteralByteArray`: flat/broken with the width framework from Tier 4.
- `DeclarationLocal` (`x := expr`, `x/T ::= expr`) — mostly benefits from what the RHS does.
- Specials (`TokenNode`, `Error`, `LspSelection`, `ToitdocReference`, toitdoc comments): punt unless they surface a real bug.

## Orthogonal workstreams (schedule into the tiers above)

### Multi-line block-comment freeze

Lands **before Tier 4**. Width-driven breaking interacts with frozen spans; easier to lock down freeze semantics first. Rules (from the brainstorm):

1. A multi-line `/* ... */` freezes the enclosing statement-equivalent. Emit that whole unit verbatim; shift all interior lines by the re-indent Δ, clamped at column 0.
2. Single-line inline `/*...*/`: attach to the side with no whitespace; if both/neither, lean leading-of-next.
3. Standalone multi-line: leading trivia of the next sibling at the comment's own indent level, searching outward.
4. EOL `//` comments: trailing trivia of their line's statement-equivalent; lock that line's horizontal layout.

### Comment co-walk

Currently the formatter emits inter-node bytes verbatim, which handles comments by accident. Once Tier 3 starts reformatting aggressively, we need an explicit cursor into `scanner.comments()` that advances with the AST walk, routing each comment through the attachment rules above. Land alongside Tier 3.

### AST-equivalence check

**Tier 3 hard requirement.** Must treat `foo (bar 499)` and `foo\n    bar 499` as equal (skip `Parenthesis` wrappers). Implement once; it's the safety net for every subsequent layout change.

### Index / IndexSlice AST bug

Fix in Tier 1. Cleaner than dragging the workaround into Tier 3.

### One-line-paren invariant (Tier 4 aesthetic guard)

During Tier 4 development: if a statement is one line in input and one line in output, its paren count must not increase. That's an unambiguous bug signal — no layout change happened, so there's no excuse for new parens. Anything involving multi-line reformatting is context-dependent and not worth automating; eyeball those during dogfooding. Temporary ratchet — retire it once paren rules are tight enough to keep it green.

## Scope markers / where to stop (unchanged)

- Don't build CST classes parallel to AST classes. Dispatch on AST kind.
- Don't build a standalone trivia-attachment pass outside the formatter yet. LSP can extract it later.
- Don't add `last_line_width` until a real case demands it.
- Don't add backtracking. If a layout decision seems to need it, the node's heuristic is wrong.
