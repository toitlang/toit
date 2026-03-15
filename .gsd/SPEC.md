# SPEC.md — Toit Formatter Specification

> **Status**: `FINALIZED`

## Vision

An opinionated code formatter for the Toit programming language. The formatter
uses a bottom-up approach: subtrees compute their single-line width, and parents
decide whether to keep children on one line or break them apart. There is no
hard line-width limit.

## Goals

1. Accurately format Toit code into a canonical style.
2. Implement a bottom-up layout engine where subtrees report their flat width
   and parents decide when to break.
3. Handle comments correctly without mutating the core compiler AST.
4. Validate via gold-test driven test suite.

## Non-Goals (Out of Scope)

- Hard line-width limit (Wadler-style "does it fit in N columns").
- Re-architecting the core compiler AST.
- Real-time/in-editor performance optimizations (for version 1).

## Approach

### Bottom-Up Width Computation

Every formatter node knows its **flat width** — how many characters it would
take if rendered on a single line. This is computed bottom-up from the leaves:

- Leaf text: `text.length()` (includes any attached inline comments)
- Soft line break: `1` (the space it becomes when flat)
- Hard line break: `∞` (forces parent to break)
- Indent wrapper: `child.flat_width`
- Group: sum of children's flat widths

When deciding layout, parents check whether a child's flat width is
"reasonable" for inline rendering. The threshold is context-dependent — an
argument list might tolerate longer lines than a condition expression. There is
no global column limit. Parentheses are not factored into width calculations
(adding parens is ~2 chars — not worth complicating the engine for).

### Semantic Awareness

Formatter nodes carry lightweight semantic tags (expression, statement,
argument list, binary op, etc.). This enables context-dependent decisions:

- Whether to add parentheses around multi-line expressions.
- How to split argument lists vs binary chains.
- How to handle Toit-specific constructs like `:` blocks and named arguments.

### Comment Strategy

Comments are not stored on AST nodes. The formatter receives the scanner's
comment list (sorted by source position) and absorbs them into formatter nodes
during the AST-to-IR conversion.

Three categories:

1. **End-of-line comments** (`// ...`):
   The line containing this comment must not be reformatted, except for block
   indentation changes (where the entire statement's indentation shifts).
   Absorbed into the formatter node for the line/statement they appear on.

2. **Multi-line block comments** (`/* ... */` spanning multiple lines):
   The statement containing this comment should not be reformatted. The comment
   content is reproduced verbatim. Absorbed as a "frozen" region in the
   formatter IR.

3. **Inline comments** (`/*foo*/` on a single line, like `foo/List/*<int>*/`):
   Absorbed into the adjacent leaf's text node. For example, `List/*<int>*/`
   becomes a single text node of width 14. The flat-width computation includes
   the comment text — parentheses are NOT considered in width calculations.

### Parenthesization

The formatter may need to insert parentheses when reformatting changes the
parse. Examples:

- `print 1 + \n foo 3` → `print 1 + (foo 3)`
  (without parens, `foo` would be parsed as a separate call after reformatting)
- `if (map.get --if-absent=: null): ...`
  (parens needed so `:` doesn't interfere with `if`)

These decisions require semantic context — knowing whether something is a call
argument, a binary operand, etc.

## Users

Toit developers and users of the Jaguar/Toit extensions who want their code
automatically structured.

## Constraints

- **Language**: C++, inside the `toit::compiler` namespace.
- **Entry point**: `format_unit()` in `src/compiler/format.cc`.
- **AST Modification**: Do not add comment references directly to `ast::Node`.

## Success Criteria

- [ ] Formatter processes the entirety of `/lib` and reproduces it identically
      (copy-formatter baseline — proves comment handling works).
- [ ] Gold tests pass for comment edge cases (trailing, block, inline, toitdoc).
- [ ] `print 1 + \n foo 3` is rewritten to `print 1 + (foo 3)`.
- [ ] `print 1 + \n 2 + 3` is flattened without parentheses.
