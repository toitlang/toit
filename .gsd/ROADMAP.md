# ROADMAP.md

> **Current Phase**: Phase 1
> **Milestone**: v1.0

## Must-Haves (from SPEC)

- [ ] Copy formatter that reproduces `/lib` identically (comment proof)
- [ ] Bottom-up layout engine (flat width, no line limit)
- [ ] Gold-test suite
- [ ] Semantic parenthesis insertion
- [ ] Opinionated formatting rules

## Phases

### Phase 1: Copy Formatter with Comments
**Status**: 🔄 In Progress
**Objective**: Build a formatter that reproduces the original source exactly,
proving we have control over every character including comments.

Key deliverables:
- Comment manager that maps comments to AST node positions (before, after,
  inline).
- AST visitor that walks the tree and emits original source text with comments
  interleaved.
- The formatter processes all of `/lib` and produces identical output.
- Gold test infrastructure (reuse existing `tests/formatter/` scaffolding).

The Document IR from the previous approach may be largely scrapped. In this
phase, the visitor can emit directly to a string buffer, or use a minimal IR
that is just text + hard newlines. The point is to get comment handling right.

### Phase 2: Bottom-Up Layout Engine
**Status**: ⬜ Not Started
**Objective**: Implement the flat-width computation and group-breaking logic.

Key deliverables:
- Document IR nodes with `flat_width` computed in constructors.
- Group node that decides flat vs broken based on child widths.
- Semantic context tags on nodes.
- Simple formatting: flatten expressions that fit on one line, break those
  that don't.
- Tests showing expressions being flattened/broken.

### Phase 3: Opinionated Formatting Rules
**Status**: ⬜ Not Started
**Objective**: Implement per-node-type formatting for common constructs.

Key deliverables:
- Method/function declarations: parameter layout, body indentation.
- Call expressions: argument splitting.
- Binary expressions: operator chain formatting.
- Import/export formatting.
- Class declarations.
- Control flow (if/while/for).

### Phase 4: Semantic Parenthesization
**Status**: ⬜ Not Started
**Objective**: Insert parentheses where reformatting would change the parse.

Key deliverables:
- `print 1 + \n foo 3` → `print 1 + (foo 3)`.
- Handle `:` interference with `if`/`while`/`for`.
- Never remove user-written parentheses.

### Phase 5: Standard Library Validation
**Status**: ⬜ Not Started
**Objective**: Run the formatter on `/lib`, review output, iterate on rules.

Key deliverables:
- Format all of `/lib` and verify the code still compiles and tests pass.
- Manual review of formatting aesthetics.
- Fix edge cases discovered during validation.
