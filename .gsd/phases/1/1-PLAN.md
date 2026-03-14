---
phase: 1
plan: 1
wave: 1
---

# Plan 1.1: Foundation & Printing Engine

## Objective
Implement the Wadler-style intermediate representation (IR) and the core context-aware printing logic. Introduce the `tests/formatter` infrastructure for gold tests.

## Context
- .gsd/SPEC.md
- .gsd/ROADMAP.md
- src/compiler/format.h
- src/compiler/format.cc

## Tasks

<task type="auto">
  <name>Define Document IR classes in format.h</name>
  <files>src/compiler/format.h</files>
  <action>
    - Add forward declarations or definitions for `Document` IR primitives: `Text`, `Line`, `Group`, `Indent`.
    - Define a `Printer` class/struct to maintain indentation and column state.
    - DO NOT alter `ast::Node` structure.
  </action>
  <verify>make compiler</verify>
  <done>format.h compiles without errors</done>
</task>

<task type="auto">
  <name>Implement Document IR and Printer logic in format.cc</name>
  <files>src/compiler/format.cc</files>
  <action>
    - Implement the Wadler-style formatting algorithm: `measure` (fits on one line), `print` (recursive formatting with indentation contexts).
    - Ensure `Line` can be forced (hard break) or rendered as a space if a `Group` fits.
    - Write a basic instantiation method to test strings.
  </action>
  <verify>make compiler</verify>
  <done>format.cc compiles successfully and exposes formatting entry points</done>
</task>

<task type="auto">
  <name>Scaffold Gold Test Infrastructure</name>
  <files>tests/formatter/test.toit, tests/formatter/runner.py (or similar Make target)</files>
  <action>
    - Look at how `tests/negative` is structured and setup a similar directory at `tests/formatter`.
    - Provide a way to run the formatter CLI (e.g. `toit compile --format` or `toit.format`) against a `.toit` file and diff it against `.gold` files.
    - This task might entail adding a `--format` flag to `toit.cc` or similar.
  </action>
  <verify>make test</verify>
  <done>A dummy gold test can be run successfully</done>
</task>

## Success Criteria
- [ ] `format.h` and `format.cc` contain the Document IR classes.
- [ ] Printing engine logic correctly handles indentation and line breaks.
- [ ] `tests/formatter` directory exists and integrates with `make test` or `ctest`.
