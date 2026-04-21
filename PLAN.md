# Toit Formatter — Plan

## Goals (unchanged)

- **Correctness**: formatter never changes semantics.
- **Idempotence**: `format(format(x)) == format(x)`.
- **No hard line limit**: soft width heuristics per node kind, deeper nodes may go further right.
- **No backtracking**: inside-out layout. Each subtree decides its own shape from its own content and a local node-kind heuristic; parents don't pass budgets down.

## Architecture (recap)

- **Shape** `{first_line_width, max_width, height}` — in place. A parent only sees a shape, never a budget from above.
- **Frozen subtrees** report their shape from preserved source. Parents don't distinguish.
- **Comments**: currently byte-adjacent (survive by sitting next to the code they describe); `has_interior_comment` / `has_line_locking_comment` / `has_interior_multiline_block_comment` guard against reshaping that would displace them. A full co-walk with AST-routed comments is still future work — land when Tier 4 width decisions surface cases byte-adjacency can't handle.
- **Vocabulary**: "suite" / "indented region" for what other languages call a code block. "Block" in Toit means a closure.
- **Canonical indents**: `INDENT_STEP = 2` (body suites, control-flow, block/lambda bodies) and `CALL_CONTINUATION_STEP = 4` (broken-call args, method param continuations). Two constants; the distinction matches the dominant convention in the reference corpus.

## Done

### M0–M5 (original milestones)

- **M0**: identity `format_unit`; ctest harness under `tests/formatter/`.
- **M1**: `Formatter` class walks top-level nodes; byte-identical output.
- **M2**: indentation recomputed from AST nesting for `Class` members and `Method` bodies. Δ-shifted continuation lines.
- **M3**: `Shape` struct + `shape_from_source_range`.
- **M4**: first real layout decision — flat `Call` with canonical single-space separators.
- **M5**: dogfooded over `lib/`. Fixed Block-argument spacing and Index/IndexSlice receiver drop. Test corpus expanded.

### Tier 1 — safe-full-range expansion

- Added `Dot`, `Unary`, `Parenthesis`, `Return`, `LiteralStringInterpolation`, `Parameter` to `has_reliable_full_range`.
- Fixed `Index` / `IndexSlice` AST bug (`full_range` now extends to the receiver).
- Fixed `Parser::peek_range` to return the peeked token's range rather than the current one (was affecting every `current_range_if_delimiter()` caller).

### Tier 2 — indentation recursion

- Recursion into `If` (+ else-if chain + final else), `While`, `For`, `TryFinally` body suites.
- Recursion into the body of a `Call`'s trailing `Block` / `Lambda` argument.
- Inter-statement comments shift with the body's Δ (not just with verbatim gaps).
- Standalone `else if` nesting handled correctly (the `.no` chain walked while it's an `If`).

### Tier 3.1 — structural AST-equivalence check

- `ast_equivalence.{h,cc}`: full recursive comparison of two ASTs modulo trivia and `Parenthesis` wrappers. Symbol comparison is content-based (different `SymbolCanonicalizer` instances).
- `Compiler::format` runs it on every format: re-parses the output, refuses to write on mismatch. Opt out with `TOIT_FORMAT_NO_VERIFY=1`.
- `SourceManager::load_from_memory` added to avoid going through the filesystem for the re-parse; copies with a null terminator to satisfy the scanner's sentinel.

### Tier 3.2 — always-flat mode with paren insertion

- `TOIT_FORMAT_FLAT_TEST=1` env var, plumbed through `FormatOptions.force_flat`.
- Flat emission for `Binary`, `Unary`, `Dot`, `Index`, `IndexSlice`, `LiteralList`/`Set`/`Map`/`ByteArray`, `Call`, `NamedArgument`, `Nullable`, `LiteralStringInterpolation`, `BreakContinue`, `Return`, `DeclarationLocal`. Paren insertion driven by the token-precedence table.
- Call paren rule: wrap whenever `outer_prec != NONE` — Toit's Call is greedy across binary operators (empirically confirmed: `foo 10 << 2` calls `foo` with `40`). Over-parens in benign contexts but always AST-safe.
- Interior-comment and line-locking guards prevent flat emission from silently dropping or displacing trivia.
- `tests/formatter/flat-dogfood-test.toit` runs flat mode over every `lib/` file in CI (~15s). Idempotent.

### Tier 3.3 — comment rules (pragmatic)

- Multi-line `/* ... */` freezes the enclosing statement-equivalent: emit verbatim with Δ-shift, no finer re-indent.
- EOL `//` and inline `/*...*/` after the last token of a line lock that line against horizontal reshaping. `has_line_locking_comment` is checked by both flat emission and by `try_emit_call_flat_canonical`.
- Inter-statement trivia (blank lines, standalone comments between body expressions) shifts with the body's Δ. Implemented by routing the leading-trivia portion of `emit_range_reindent` / `try_emit_call_flat_canonical` through `emit_with_indent_shift` instead of a verbatim `advance_to`.

### Tier 4 (started) — canonical continuation indents

- Statement-position broken `Call` args re-indented to `indent + CALL_CONTINUATION_STEP` (4).
- Same for `return <broken-call>`, `x := <broken-call>`, `x = <broken-call>` / `x += ...` etc. (all assignment-kind Binaries).
- Same for `Method` parameters on continuation lines (`constructor\n    --.id`).

### Testing

- Gold-file tests under `tests/formatter/gold/normal/` and `tests/formatter/gold/flat/`. One `.toit` input + one `.gold` expected output per case.
- `ninja update_formatter_gold` regenerates. Also checks idempotence (re-format of gold-matching output).
- Three Toit-driven tests for corpus-level coverage: `idempotence-test`, `round-trip-test` (normal mode over every `lib/` file), `flat-dogfood-test` (flat mode over every `lib/` file).

## Tiers ahead

### Tier 4 (remainder) — width-based flat/broken decisions

Goal: produce actually pleasant output. Paren correctness already nailed down by Tier 3.

- **Per-node soft-width thresholds.** Flat if it fits, broken if it doesn't. Start thresholds generous, dogfood, tune. Don't start with "I bet 80 is right." Artemis measurements: 99.5% of lines ≤ 100 cols, 99.9% ≤ 120 cols; max 221. A first cut around 100 looks reasonable but needs dogfooding.
- **Broken-form emission for `Binary` chains** — operator-aligned or breakable at operator boundaries. Not yet implemented.
- **Nested broken Calls** — `return foo (bar\n  arg)` where the inner `bar` Call's continuation indent should be relative to the inner's line, not the outer statement's indent.
- **Drop parens that the indentation now disambiguates** when transitioning flat → broken. The over-parens that Tier 3.2 sprinkles liberally become unnecessary once a break pins structure visually.
- **One-line-paren invariant** as a development-time guard: a statement that was one line in input and one line in output must not have more parens. Catches width-driven rules that over-paren in the wrong direction. Retire once it's stably green.

### Tier 5 — collection literals and polish

- `LiteralList` / `Map` / `Set` / `ByteArray` broken forms with the width framework.
- Whatever else shows up during dogfooding that nothing else covers.

## Orthogonal workstreams

### Comment co-walk (proper routing)

Byte-adjacency + the interior/line-locking guards cover the cases we've hit so far. Once Tier 4 starts moving tokens across lines (flat→broken or broken→flat), an explicit cursor into `scanner.comments()` that advances with the AST walk will be needed — route each comment to its attachment point instead of relying on where its bytes sit. Land when a concrete regression forces it; don't build speculatively.

Brainstorm rules (for reference when it lands):

1. Multi-line `/* ... */` freezes the enclosing statement-equivalent. ✓ done.
2. Single-line inline `/*...*/`: attach to the side with no whitespace; if both/neither, lean leading-of-next.
3. Standalone multi-line `/* ... */`: leading trivia of the next sibling at the comment's own indent level, searching outward.
4. EOL `//` comments: trailing trivia of their line's statement-equivalent; lock that line's horizontal layout. ✓ done.

### Heuristics driven by the reference corpus

When a layout decision has multiple AST-equivalent options, pick the form dominant in the reference corpus (currently `artemis/src` — `lib/` is old and less representative). Measured at development time, baked into the rule as a constant. Runtime measurement risks idempotence loss.

Decision procedure:

1. **Clear majority (~70%+ one way)** → match it.
2. **Ambiguous (~40/60 or closer)** → simpler rule wins. Formatter becomes predictable; corpus converges toward the choice as it gets re-run.
3. **Human review of the final diff** catches edge cases frequency counting misses.

Derived this way so far: flat-Call single-space separators; `CALL_CONTINUATION_STEP = 4` (61 vs 31 in artemis); `INDENT_STEP = 2` for block/lambda body.

## Scope markers / where to stop (unchanged)

- Don't build CST classes parallel to AST classes. Dispatch on AST kind.
- Don't build a standalone trivia-attachment pass outside the formatter yet. LSP can extract it later.
- Don't add `last_line_width` until a real case demands it.
- Don't add backtracking. If a layout decision seems to need it, the node's heuristic is wrong.
