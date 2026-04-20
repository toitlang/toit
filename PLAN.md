# Toit Formatter — Plan

## Goals

- **Correctness**: formatter never changes semantics.
- **Idempotence**: `format(format(x)) == format(x)`.
- **No hard line limit**: soft width heuristics per node kind, deeper nodes may go further right.
- **No backtracking**: inside-out layout. Each subtree decides its own shape from its own content and a local node-kind heuristic; parents don't pass budgets down.

"Experiment-ready" is the first milestone we actually ship — a formatter that is correct and idempotent, even if aesthetically rough. Heuristic tuning comes after.

## Architecture

### Inside-out layout via shape abstraction

Each subtree computes its own layout and reports a **shape**:

```
shape := { first_line_width, max_width, height }
```

(`last_line_width` omitted for now — Toit's indentation model rarely continues on the same line after a multi-line chunk. Add if a real case demands it.)

Parents use child shapes to pick their own flat-vs-broken layout. No budget passed downward. Per-node-kind soft-width thresholds decide when a node prefers broken over flat.

### Frozen subtrees are ordinary shapes

A frozen subtree (see Comments) reports its shape computed from preserved source rather than from layout logic. Parents don't know or care about the difference.

### Co-walked comments, no sidecar

Comments are already sorted by position. The formatter walks the AST in source order with a cursor into the sorted comment list. No map, no parallel CST class hierarchy. On each node visit:

1. Drain comments before node start → leading trivia.
2. Scan comments within node range for multi-line block comment → if present, mark as freeze boundary.
3. Otherwise dispatch normally; child nodes handle their own interior comments.
4. After node end, drain comments adjacent to last token → trailing trivia.

Optional precomputation: a `set<ast::Node*>` of frozen nodes, populated by a prepass over comments. Start lazy; add if profiling warrants.

## Comments

Four cases:

1. **End-of-line** (`// ...`): attach as trailing trivia of the line's statement-equivalent. The line's horizontal layout is locked (no reflow across the line boundary); indentation can still shift.

2. **Multi-line block** (`/* ... */` with `/*` and `*/` on different source lines): **freezes the enclosing statement-equivalent**. Emit verbatim; shift all interior lines by the same Δ when the enclosing suite re-indents. (Clamp Δ at column 0.)

3. **Single-line inline** (`/*...*/` on one line):
   - Attached to only one side (no space on that side): attach to that node.
   - Attached to neither (space on both sides): pick leading-of-next by default.
   - Attached to both (no space either side, e.g. `a/*c*/b`): render verbatim, preserve spacing.

4. **Standalone multi-line** (multi-line block with no code on the `/*` line or the `*/` line): does not affect code formatting. Attaches as **leading trivia of the next sibling at the comment's own indent level**, searching outward if no such sibling. Interior lines shift with the attached node's suite.

## Parens

Moving an expression may require inserting or removing parens (e.g. `foo (bar 499)` vs `foo\n    bar 499`). Rules:

- Paren insertion/removal is **semantic**: driven by AST node kind and target position, not by width math.
- Width estimation **ignores** parens. If we're off by two characters, a line is slightly too long or short — acceptable since there's no hard limit.

## Statement-equivalent unit

Toit does not have statements per se. The freeze unit (and the "one logical line" unit for EOL comments) is the **top-level item in a suite**: whatever expression or declaration occupies one primary indent slot. We'll refine this if specific cases push back.

"Block" in Toit means a closure-like construct — do not use the word for indented regions. Prefer "suite" or "indented region."

## Correctness harness

Build before any formatting logic. For every test input `S`:

1. Parse `S` → AST₁
2. `format(S)` → `S'`
3. Parse `S'` → AST₂
4. Assert AST₁ ≡ AST₂ modulo trivia. (The equivalence check must treat `foo (bar 499)` and `foo\n    bar 499` as equal at the AST level — it checks semantics, not source.)
5. `format(S')` → `S''`; assert `S' == S''` byte-for-byte.

Run over the core libraries in CI from M1 onward. Every subsequent change is gated on it staying green. Idempotence failures are signals that the inside-out invariant is broken somewhere — treat them as architectural bugs, not output tweaks.

## Milestones

### M0 — Correctness harness

Test runner that takes a Toit source file and performs the five-step check above. At this stage `format` can be the identity function — the harness just needs to exist and pass trivially. Wire it into CI over the core libraries.

### M1 — Verbatim round-trip

`format_unit` re-emits the input source byte-for-byte, trivia included. Pins down the comment co-walk mechanics before layout touches anything. Harness passes trivially at this stage too, but now on a real code path.

### M2 — Indentation-only pass

Recompute indentation from suite nesting; leave horizontal layout alone. Harness does real work now: step 4 catches accidental token drops, step 5 catches indentation inconsistencies. Small enough surface area that breakage is diagnosable.

### M3 — Shape abstraction + layout for one node kind

Pick the node that dominates Toit code — likely `Call` — and implement shape computation + flat/broken decisions end-to-end for it. Everything else stays verbatim. This is where the architecture earns its keep or doesn't.

### M4 — Expand to all node kinds

Roll out shape + layout for the remaining AST nodes (expressions, control flow `If`/`While`/`For`/`TryFinally`, declarations, literals, string interpolation, type annotations, etc.). Paren insertion/removal lands here. Freeze logic for multi-line block comments lands here.

### M5 — Dogfood on core libraries

Run on real code. Collect ugly cases. Tune per-node heuristics. No architectural changes at this stage — if something needs backtracking, something was wrong earlier.

## Scope markers / where to stop

- Don't build CST classes parallel to AST classes. Dispatch on AST kind directly.
- Don't build a standalone trivia-attachment pass outside the formatter yet. LSP can extract it later if needed.
- Don't add `last_line_width` until a real case demands it.
- Don't add backtracking. Ever. If a layout decision seems to need it, the node's heuristic is wrong.
