# SPEC.md — Project Specification

> **Status**: `FINALIZED`

## Vision
An opinionated, context-aware code formatter for the Toit programming language that intelligently handles dynamic line widths and semantically aware parenthesization while flawlessly interleaving standard and documentation comments.

## Goals
1. Accurately format Toit language code into a canonical represented style.
2. Implement a layout engine utilizing Wadler's "A prettier printer" algorithm.
3. Establish robust comment handling without mutating the core compiler AST.
4. Establish a gold-test driven validation suite for the formatter.

## Non-Goals (Out of Scope)
- Building a constraint solver for formatting.
- Re-architecting the core compiler AST.
- Real-time/in-editor formatting performance optimizations (for version 1).

## Users
Toit developers and users of the Jaguar/Toit extensions who want their code automatically structured.

## Constraints
- **Technical constraints**: Must be implemented in C++ and integrate inside the `toit::compiler` namespace. The `CopyFormatter` AST visitor structure in `src/compiler/format.cc` should serve as the entry point.
- **AST Modification**: Do not add comment references directly to `ast::Node`.

## Success Criteria
- [ ] Formatter parses the entirety of `/lib` and reproduces a working formatting baseline.
- [ ] Gold tests accurately diff and pass for various edge cases (trailing, block, multi-line comments).
- [ ] `print 1 + \n foo 3` is rewritten to `print 1 + (foo 3)`.
- [ ] `print 1 + \n 2 + 3` is flattened without parentheses.
