# ROADMAP.md

> **Current Phase**: Not started
> **Milestone**: v1.0

## Must-Haves (from SPEC)
- [ ] Copying formatter baseline
- [ ] Wadler's algorithm styling
- [ ] Gold-test suites
- [ ] AST-independent comment handling
- [ ] Semantic parenthesis insertion

## Phases

### Phase 1: Foundation & Printing Engine
**Status**: ⬜ Not Started
**Objective**: Build the Document IR classes (Line, Text, Group) and the line-measuring/printer engine in `format.h`/`format.cc`.

### Phase 2: Copying Formatter Baseline
**Status**: ⬜ Not Started
**Objective**: Build `IRFormatVisitor` to parse the AST directly to the Document IR faithfully reproducing original spans and layout. Tests out comment attachment logic mapping via `CommentsManager`.

### Phase 3: Gold Test Infrastructure
**Status**: ⬜ Not Started
**Objective**: Introduce `tests/formatter` test suite replicating `tests/negative` mechanisms. Allow running formatter on `.toit` files against expected results to visualize modifications.

### Phase 4: Opinionated Formatting Rules
**Status**: ⬜ Not Started
**Objective**: Enhance `IRFormatVisitor` to handle smart concatenation. Implements parenthesis rendering based on AST node depth for nested calls/binary expressions.

### Phase 5: Standard Library Refactoring Validation
**Status**: ⬜ Not Started
**Objective**: Evaluate and refactor the `/lib` Toit standard library code using the formatter. Review changes manually for aesthetics and correctness.
