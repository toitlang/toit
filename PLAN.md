# Toit Formatter — Plan

## Goals

- **Correctness**: formatter never changes semantics.
- **Idempotence**: `format(format(x)) == format(x)`.
- **Determinism (primary goal going forward)**: output is a function of (AST + width budget). Two AST-equivalent inputs with different layouts must produce byte-identical output. The only allowed escape hatches are comment-induced freezes — multi-line `/* ... */` freezes the enclosing statement, and EOL `//` (or inline `/*...*/` after the last token) locks that line's horizontal layout. Everything else is up to the formatter, not the source.
- **No hard line limit**: soft width heuristics per node kind, deeper nodes may go further right.
- **No backtracking**: inside-out layout. Each subtree decides its own shape from its own content and a local node-kind heuristic; parents don't pass budgets down.

## Architecture (recap)

- **Shape** `{first_line_width, max_width, height}` — in place. A parent only sees a shape, never a budget from above.
- **Frozen subtrees** report their shape from preserved source. Parents don't distinguish.
- **Comments**: currently byte-adjacent (survive by sitting next to the code they describe); `has_interior_comment` / `has_line_locking_comment` / `has_interior_multiline_block_comment` guard against reshaping that would displace them. A full co-walk with AST-routed comments is still future work — land when Tier 4 width decisions surface cases byte-adjacency can't handle.
- **Vocabulary**: "suite" / "indented region" for what other languages call a code block. "Block" in Toit means a closure.
- **Canonical indents**: `INDENT_STEP = 2` (body suites, control-flow, block/lambda bodies) and `CALL_CONTINUATION_STEP = 4` (broken-call args, method param continuations). Two constants; the distinction matches the dominant convention in the reference corpus.
- **Width budgets**: `MAX_LINE_WIDTH = 100` (general flat-vs-broken), `NAMED_ARG_CALL_WIDTH = 80` (Calls with ≥2 NamedArguments — config-call shape), `INLINE_CONTROL_FLOW_WIDTH = 60` (`if cond: body` / `while cond: body`). The tighter inline-control-flow budget exists because packing two semantic chunks (header + body) on one line is harder to read at high width — the eye has to mentally split before processing each part.

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

### Tier 4 — canonical continuation indents

- Statement-position broken `Call` args re-indented to `indent + CALL_CONTINUATION_STEP` (4).
- Same for `return <broken-call>`, `x := <broken-call>`, `x = <broken-call>` / `x += ...` etc. (all assignment-kind Binaries).
- Same for `Method` parameters on continuation lines (`constructor\n    --.id`).

### Tier 4 — pure-AST flat-if-fits

Formatter output is a function of the AST and a width budget. Input line
breaks and paren counts are ignored — two source files with the same AST
produce the same output, so authors don't have to "pre-format" their code.

- `MAX_LINE_WIDTH = 100` (first cut; per-node thresholds will come if dogfooding demands it).
- `try_emit_call_flat_canonical` accepts multi-line source and collapses to flat when the width fits, the target and every arg are each single-line in source, and the gap between tokens contains only whitespace. (The single-line-in-source guard is the only shape check left — it's about byte copy safety, not style.)
- `emit_stmt_flat` takes a `max_width` param and renders via `emit_expr_flat` into a buffer. Wired into `emit_stmt` for every flat-emittable statement kind except bare `Call` (which keeps its source-byte flat path) and control-flow (`If`/`While`/`For`/`TryFinally`).
- Preceding trivia (blank lines, standalone comments) is Δ-shifted consistently with the stmt's new indent, not copied verbatim.

Paren rules in `emit_expr_flat`:

- **Associativity-aware**: `and`/`or` and assignment ops are right-assoc, everything else left-assoc. Same-precedence chains (`a + b + c`) no longer over-paren.
- **ASSIGN-RHS at NONE**: the right side of an assignment-precedence Binary is a stmt-level boundary, so it recurses at `PRECEDENCE_NONE` rather than `prec-1`. `x := foo a b c` stays that way instead of becoming `x := (foo a b c)`.
- **Parenthesis preservation**: Parenthesis AST nodes wrapping non-trivial sub-expressions (Binary / Unary / Call / Dot / Index …) are preserved. `(a + b) * c` stays grouped. `(x)` around a bare identifier / literal still peels as pure noise.
- **Bitwise clarity**: whenever a bitwise op (`<<`, `>>`, `>>>`, `&`, `|`, `^`) meets a different op across a Binary/Binary boundary, the child gets parens even if the source didn't have them. Readers don't trust the precedence table past `+`/`-`/`*`/`/`, so the formatter makes the grouping explicit. Same op on both sides reads unambiguously as a chain and stays unwrapped.

### Tier 4 — width-based flat/broken decisions

Done. Goal was: produce actually pleasant output once paren correctness is nailed down.

- **Soft-width thresholds.** `MAX_LINE_WIDTH = 100` for the general flat-vs-broken decision. Config-call shapes — Calls with two or more `NamedArgument` args — get a tighter `NAMED_ARG_CALL_WIDTH = 80` budget. Short `foo --a=1 --b=2` stays flat under both; long `provides X --handler=this --priority=P` crosses 80 and breaks, while the same shape would have stayed flat under the 100-col general limit.
- **Broken-form emission for `Binary` chains** — when a Binary-rooted stmt is one line and over MAX_LINE_WIDTH, its same-operator chain is flattened (`flatten_binary_chain`, assoc-aware) and each operand emits on its own continuation line at `indent + CALL_CONTINUATION_STEP` with the operator leading.
- **Nested broken Calls** — when a Call's Parenthesis-wrapped arg doesn't fit flat on its continuation line, `emit_arg_bytes_or_recurse` opens `(`, then calls `emit_call_broken_inline` which places the inner target on the current line and each inner arg at `target_col + CALL_CONTINUATION_STEP`. Recursive — handles nested Parenthesis(Call) all the way down. Bails to verbatim when the inner Call has Block/Lambda args or an interpolated-string arg (unsafe ranges).
- **Method signature layout** — when parameters wrap, the `-> Type` return annotation is placed on the first line with the method name (and any same-line parameters), and the header-closing `:` ends up flush with the last continuation param.

### Tier 5 — collection literals

Done. `LiteralList` / `LiteralSet` / `LiteralMap` / `LiteralByteArray` get a per-element broken form when the single-line render exceeds `MAX_LINE_WIDTH` (and the wrapper is a bare stmt / Return / DeclLocal / assignment Binary). Each element on its own line at `indent + INDENT_STEP`, trailing comma, closing bracket flush with the stmt's indent.

### Tier 6 — paren rules driven by artemis dogfood

- **No synthesised constructor-receiver parens.** Without a resolver the formatter can't tell `Foo.bar` (named constructor / static call) from `(Foo).bar` (instance method on the class object). It honours what the source had: bare Identifier receiver stays bare, source-provided Parenthesis around a receiver is preserved. The earlier "uppercase-first ⇒ wrap" heuristic was wrong for Toit's `Type.member` syntax (which is the static / named-constructor form, not the rare instance-on-class-object form).
- **`or` / `and` Binary children parsed at NONE.** `parse_logical_spelled` parses each operand via `parse_call` directly (no Pratt climbing), so both sides are stmt-level boundaries. The Binary handler in `emit_expr_flat` sets both `left_prec` and `right_prec` to `PRECEDENCE_NONE` for `or` / `and` — bare Calls on either side stay bare (`a or foo b c`, not `a or (foo b c)`).

### Testing

- Gold-file tests under `tests/formatter/gold/normal/` and `tests/formatter/gold/flat/`. One `.toit` input + one `.gold` expected output per case.
- `ninja update_formatter_gold` regenerates. Also checks idempotence (re-format of gold-matching output).
- Three Toit-driven tests for corpus-level coverage: `idempotence-test`, `round-trip-test` (normal mode over every `lib/` file), `flat-dogfood-test` (flat mode over every `lib/` file).
- Manual dogfood against `artemis/src` (74 files, ~1500 lines of diff vs source) used to surface paren / break-decision regressions; all current diff is intentional pure-AST behaviour (broken-by-style maps that fit flat get collapsed).

### Tier 7 — close the determinism gaps (primary goal)

Today the formatter is a function of (AST + width + source layout). The remaining source-layout dependencies are the ones to eliminate, modulo the comment-induced freezes that are explicit escape hatches.

#### 7.a — control-flow inline-vs-broken

Done for `If` (with full else / else-if chain handling) and `While`. `try_emit_if_canonical` walks the chain (else-if continues via `If.no = inner If`, final else via `If.no = Sequence`), then either:

- Inline form `if cond: body` when there's no else, the body is single-stmt and flat-emittable, and the rendered total fits `INLINE_CONTROL_FLOW_WIDTH = 60`. Inline forms with else aren't a shape the formatter produces (`if A: a else: b` packs three semantic chunks — strictly less readable than broken).
- Broken form (each branch + body on its own lines) emitted from AST otherwise, regardless of source layout.

`try_emit_while_canonical` is the same shape (no else clause to handle).

Also fixed in this round: the `not Call` paren bug. `not` is parsed via `parse_not_spelled` → `parse_call` directly, so `not foo a b` doesn't need parens. Unary handler passes `PRECEDENCE_NONE` to the operand for `Token::NOT`.

Done for Method bodies too. `try_emit_method_body_canonical` runs before the existing emit_method chain; same inline-vs-broken logic. Header bytes (up to and including `:`) are taken verbatim from source; body is rendered from AST. Bails when the header is multi-line (wrapped params — let `try_emit_method_canonical` handle), or when broken-synth would emit a too-wide body line (let `emit_with_suite` handle).

Done for Call's trailing block-arg too. `try_emit_call_trailing_block_inline` runs in emit_call before `emit_call_with_trailing_suite`. For a Call whose last argument is a Block / Lambda with single-stmt parameter-less body, renders inline `<call header>: <body_stmt>` (or `:: ` for Lambda) when fits, otherwise broken. Source-inline `list.do: it.print` was already handled by `try_emit_call_flat_canonical`; this fills the symmetric broken→inline direction.

Done for For too. `try_emit_for_canonical` shares `try_emit_byte_header_body_canonical` with the Method-body path: both have headers too varied to render from AST (For has init/cond/update + semicolons), so the header is byte-copied verbatim up to the body separator `:`, body rendered from AST. The colon-finder skips `:=`, `::`, and `::=` (so `for i := 0; ...:` finds the right colon).

Still open in 7.a:

- **Wrapped Calls with trailing block** (`x := catch: body`, `return list.do: it.print`). The Block-arg early-bail in `try_canonicalize_broken_call_in_range` / `emit_call_forced_broken` means wrapped trailing-block Calls fall through to leaf — source-preserving, determinism gap.
- **Method body when source-inline + body too wide for body_indent.** Bails to leaf, preserves source-inline.
- **Block parameters in trailing block-arg** (`list.do: | x | x.print` style).
- **String literals in headers** (`foo x="hello: world": ...`). The colon-finder doesn't track string state, so a `:` inside a header string would be mis-identified as the body separator. Latent bug; Toit headers rarely contain strings.

Bonus fix in this round: `Compiler::format` was skipping the file write when the formatted size matched the source size, even if the bytes differed (`&&` instead of `||` in the change check). Same-size-different-content cases were silently no-ops.

#### 7.b — broken-Call arg distribution

Done. `try_canonicalize_broken_call_in_range` now puts every arg on its own continuation line at `indent + CALL_CONTINUATION_STEP`, regardless of how the source distributed args between the target's line and continuation lines. Two safety fallbacks remain:

- **Multi-line arg in source.** `emit_arg_bytes_or_recurse` byte-copies and can't re-indent a multi-line arg's continuation lines — they'd land at the wrong column (caught in `lib/system/api/service_discovery.toit`). Falls back to source-distribution emission.
- **Wrapper broke before the Call's target** (`x :=\n  Call`). Args at `outer_indent + CALL_CONTINUATION_STEP` would land at the same column as the target on its continuation line; parser treats them as sibling stmts (caught in `lib/tls/session.toit`). Resolving cleanly needs to render wrapper + target on one line first; for now, fall back.

Note: Toit's parser groups continuation-line positional args into a nested Call (`f a b\n  c d` is `Call(f, [a, b, Call(c, [d])])`), so source positional-arg breaks aren't AST-equivalent to the single-line form anyway. Named-arg continuations don't have that issue and are the main case that benefits from canonicalisation.

#### 7.c — verbatim-fallback audit

Worked through the audit. Determinism experiments now pass for everything tested: bare/wrapped Calls (with and without trailing block-arg), Binary chains, collection literals, Method bodies (single-stmt + multi-stmt), If/else/else-if chains, While, For, trailing block-arg with parameter-less or parametered single-stmt body, try/finally, class / interface / monitor / mixin headers (single-line vs broken with extends / with / implements clauses).

Closed in this round:

- **try / finally** — `try_emit_try_finally_canonical` always emits broken from AST.
- **Block-arg with parameters** — `try_emit_call_trailing_block_inline` now renders `| x y |` from each Parameter's source bytes (preserves type annotations).
- **Wrapped Calls with trailing block** — `try_emit_call_trailing_block_inline` parameterised on outer_start / outer_end so `x := catch: body`, `return list.do: it.print`, `decl := list.do: ...` all canonicalise the same way as the bare Call case.
- **Class headers** — `try_emit_class_header_canonical` renders the header from AST: single-line when fits MAX_LINE_WIDTH, otherwise broken with each clause on its own continuation line.
- **Import / Export internal whitespace** — `try_emit_import_canonical` / `try_emit_export_canonical` render from AST with single canonical spacing. Cursor advances to end-of-line because `Import::full_range()` doesn't include `show ...` / `as ...`.
- **Field declaration internal whitespace** — `try_emit_field_canonical` renders from AST. Type and initializer go through `emit_expr_flat` (byte-copying `Nullable` only gets `?` since Nullable doesn't override `full_range`). Normalises column-alignment hacks (`META-X     ::= ...`) — author loses alignment, gains determinism.
- **String literals in Method/For headers** — `find_node_header_colon` walks backward from body's first byte (skipping whitespace + at most one newline). Avoids mis-stopping on `:` inside string literals or `:=` / `::` / `::=` combinators.
- **Method / Constructor header internal whitespace + wrap** — `try_emit_method_full_canonical` renders the entire method header from AST via `render_method_header_parts`: modifiers + name + params + return type. Single-line when fits MAX_LINE_WIDTH; otherwise broken with each param on its own continuation line at indent + CALL_CONTINUATION_STEP, return type on the first line. Handles inline body (when total fits INLINE_CONTROL_FLOW_WIDTH), broken-synth body (single-stmt that doesn't fit inline), emit_stmt body (non-flat-emittable single-stmt or multi-stmt), abstract methods (no body, no `:`), interface methods (no body, no `:`), empty-body methods (`foo:` keeps `:`). Each Parameter rendered via `render_parameter` (`[name]` for block, `--name` for named, `.name` for field-storing, `name/Type=default`).
- **Method body source-inline + body too wide** — handled by emit_stmt path in `try_emit_method_full_canonical`. emit_stmt's break logic kicks in for the body via source_cursor_ adjustment.
- **Blank-line counts** — preserved verbatim (with continuation-line delta-shift). Forcing a fixed count and even capping at 1 lost too much author intent (compact field lists, intentional grouping inside method bodies). Blank lines are explicitly not part of the determinism target.

Bonus fix: `advance_to` was unconditionally setting `source_cursor_`, even backward — discarding cursor advances from earlier emission. Now a no-op when called with a position behind the cursor.

Output is a function of (AST + width + author's blank-line layout). Blank lines are the only remaining source-shape dependency.

### Tier 8 — whatever the next dogfood pass surfaces (after Tier 7)

Re-run artemis after determinism is closed; remaining patterns will be true heuristic gaps (where the AST-driven choice disagrees with the corpus majority) rather than source-leakage.

## Orthogonal workstreams

### Resolver integration

Some layout decisions need name resolution: the constructor-vs-static-call distinction is the obvious one (`Foo.bar` could be either, and the right paren rule depends on which). Land a resolver pass before format emission; in error-zones (where resolution fails) fall back to the conservative "honour what the source had" rule.

### Comment co-walk (proper routing)

Byte-adjacency + the interior/line-locking guards cover the cases we've hit so far. Once flat→broken or broken→flat starts moving tokens across lines for cases the current guards miss, an explicit cursor into `scanner.comments()` that advances with the AST walk will be needed — route each comment to its attachment point instead of relying on where its bytes sit. Land when a concrete regression forces it; don't build speculatively.

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
