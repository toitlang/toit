# Toit pretty-printer

The Toit pretty-printer renders a canonical program from the parsed AST.  It
is not a whitespace-preserving formatter: it may move syntax such as a method
return type, reconstruct parentheses, and choose a different physical shape
for calls and collections.

## Invariants

The implementation must:

* reject input with parse errors without changing the destination;
* produce output that reparses to an equivalent AST;
* preserve every comment exactly once and in source order;
* preserve resolver-sensitive receiver parentheses when resolution data is
  unavailable;
* be deterministic and idempotent;
* emit no trailing whitespace and end files with one newline; and
* install changed files atomically.

Source whitespace, redundant parentheses, and source line breaks are not
layout preferences.  The exceptions are syntax whose bytes carry information
not represented in the AST, comments, and deliberately frozen lines.

## Comments

Comments are attached to semantic AST pieces and punctuation slots before
printing.  Moving a return type, parameter, expression, or punctuation also
moves its attached comments.

A line with code followed by `//` is frozen.  The complete physical line,
including code and spacing, is preserved.  Only its leading indentation may
shift with its enclosing construct.  No token may move into or out of the
line.  An own-line `//` comment may move with the statement or declaration to
which it is attached.

A multiline block comment is opaque.  Its bytes, internal spaces, and line
breaks are preserved.  When the comment moves, every physical line is shifted
by the same indentation delta as its first line; the comment is never
reflowed.

When a control-flow subtree contains a comment, the current conservative
policy freezes the complete subtree and shifts it uniformly.  This avoids
mistaking a nested inline suite's physical line for an independently movable
line.  The policy can be narrowed when comment slots are modeled for every
control-flow header and suite.

Every comment is consumed exactly once.  Own-line comments are assigned to
the following list item, or to the enclosing list when they follow its final
AST node.  Indentation disambiguates comments in nested statement sequences.

## Layout selection

AST printers first estimate the width of the flat spelling.  The estimate is
deliberately approximate: it ignores formatter-controlled parentheses,
optional commas, and continuation backslashes; insignificant source whitespace
is normalized.  Literal contents and collection separators are counted because
they materially affect the result.  The estimate is used only for a stable
yes/no decision; it is not rendered and need not equal the selected output's
actual width.

The flat decision uses a soft preference rather than a maximum width.  It
considers:

* line extent beyond a preferred region;
* the number of additional physical lines;
* the number of items split across lines;
* construct-specific readability costs; and
* slight pressure from the enclosing indentation.

An indented construct may extend farther right than a top-level construct.
Indentation may nevertheless move the soft breaking point slightly left
relative to the construct.  Neither condition is a hard limit.

Compact calls with many arguments may stay flat beyond the preferred extent
when breaking would introduce many lines.  A `\` continuation may be selected
when it provides a better result than either one long physical line or one
argument per line.

If flat output is rejected, the node selects a grammar-legal broken policy and
renders it directly.  Decisions inside the broken output are then made in
their new line and indentation context.  No complete broken alternative is
built or measured in advance, and no general token-order layout IR or
post-selection syntax-repair phase is used.

Initial canonical choices are:

* two spaces for suites, members, and collection contents;
* four spaces for continuation lines;
* trailing `and` and `or` at a logical line break;
* leading operators for other broken binary expressions;
* at most two preserved blank lines; and
* two spaces before a trailing comment unless it is lexically attached.

Consecutive fields form a compact group with one field per line.  Methods,
classes, and transitions between declaration kinds retain a blank separator.

Call, method-header, binary, and collection layouts are adaptive rather than
global modes.  Each AST node has small, explicit policies for flat, partially
broken, fully broken, packed-row, and backslash forms.  The common flat
decision and node-specific heuristics choose among them according to both
extent and item count.  There are no user-facing or development style switches
in the command.

## Calibration

The initial canonical output was measured over all 269 Toit files under
`lib`, `tools`, and `examples`.  The final policy formats every file and
changes 257 of them (8,160 inserted and 11,124 removed lines), so the first
application is intentionally a broad normalization rather than a small
whitespace cleanup.

Disabling clarity parentheses between unlike bitwise operators changed 43
files and repeatedly hid useful grouping, so those parentheses are canonical
and the experimental switch was removed.  Disabling indentation pressure
changed 10 files.  Counting only enclosing indentation, rather than counting
continuation indentation a second time, changes four files relative to the
original scoring and retains the desired slight pressure to break earlier.

The corpus and gold cases also exercise the adaptive outcomes: many compact
arguments may remain on one long line, a backslash may avoid a line per
argument, named suffixes may split independently, and collections may pack
several items per row.  These are outcomes of one deterministic policy, not
formatter modes or user preferences.  The flat-decision implementation
reproduces the same 269-file canonical output without constructing or scoring
complete broken alternatives.

## Grammar constraints

The AST printers must account for the following Toit grammar rules:

* A continuation-line call argument is one complete expression.  All such
  arguments use the same indentation, and once they start, subsequent
  arguments must also start on new lines.
* Same-line nested calls may need parentheses; a continuation line can provide
  the required delimiter without parentheses.
* Leading operators preserve left-associative binary trees.  Trailing
  `and`/`or` is safe because logical operators are right-associative.
* Prefix minus is attached while binary minus is surrounded by spaces.
* Suite-bearing conditions and suite arguments followed by more arguments
  require explicit delimiters.
* Binary, conditional, nested-call, prefix-`not`, and grouped suite arguments
  require parentheses in positional or named argument slots where the grammar
  would otherwise end the argument early.
* Parenthesized local initializers and parameter defaults retain the grouping
  required to contain suite-bearing calls and operator expressions.
* `{}` is an empty set and `{:}` is an empty map.
* Multiline string continuation whitespace contributes to the literal value.
  A frozen multiline-string region may move its first physical line, but its
  continuation bytes must remain unchanged.
* Parentheses in `(Foo).bar` may affect resolution.  Preserve them without
  resolution data; remove them only when resolution proves that lookup is
  unchanged.

## Test organization

User-visible behavior belongs in `tests/formatter/gold`: each `.toit` input is
formatted through the public `toit format` command, compared with its `.gold`
file, and formatted a second time to check idempotence.  Expression,
declaration, layout, comment, and source-preservation cases should normally be
added there.

CTest binaries are reserved for mechanisms that cannot be observed through
the command: AST equivalence diagnostics, atomic replacement failure modes,
source/comment fact extraction, flat-decision heuristics, and verifier
rejection.
Corpus probes over `lib`, `tools`, and `examples` find interactions that then
become focused gold cases; they are not substitutes for those cases.

## Roadmap and review stack

Every step is intended to compile and test independently.  Each step should
be one commit and may be submitted as one PR in a stacked review.

1. **Document the contract.** Add this roadmap and freeze the architectural
   and grammar decisions before implementation.
2. **Add output safety foundations.** Add in-memory reparsing, structural AST
   equivalence, comment fingerprints, and focused verifier tests.  No printer
   is introduced in this step.
3. **Add atomic file installation.** Introduce and test a reusable atomic
   writer independently of formatting.
4. **Capture source facts and trivia.** Record comments, physical lines,
   punctuation gaps, frozen trailing-comment lines, and opaque multiline
   comments.  Test ownership and indentation shifting without formatting AST
   nodes.
5. **Add flat decisions and output primitives.** Add a small line-oriented
   output builder and the rough `is flat acceptable?` heuristic.  Test soft
   width, line/item pressure, and indentation pressure.  This layer contains
   no Toit syntax policy and stores no speculative output.
6. **Print atoms and precedence expressions.** Cover identifiers, literals,
   unary, binary, dot, index, slice, and ternary expressions.  Reconstruct
   only required or selected clarity parentheses and verify every result by
   reparsing.
7. **Print method and declaration headers.** Cover parameters, return-type
   movement, fields, classes, imports, and exports, including comments that
   move with semantic pieces.
8. **Print calls and suites.** Add flat decisions and direct rendering for
   unnamed-prefix/named-continuation, fully broken, and
   backslash-continuation policies.  Cover blocks, lambdas, greedy calls, and
   layout-dependent parentheses.
9. **Print collections.** Add flat decisions and direct packed-row rendering
   for lists, sets, maps, and byte arrays, including all comment slots and
   trailing commas.
10. **Print statements and bodies.** Cover declarations, assignments,
    returns, control flow, loops, try/finally, empty suites, inline suites, and
    complete comment ownership across nested sequences.
11. **Print complete units.** Preserve preambles, Toitdoc, declaration order,
    blank lines, and the final newline.  Unsupported AST kinds fail explicitly
    rather than silently copying arbitrary source regions.
12. **Integrate `toit format`.** Add the hidden CLI command, verifier gate,
    atomic in-place writes, golden tests, idempotence tests, and corpus-level
    formatting over `lib`, `tools`, and `examples`.
13. **Calibrate canonical choices.** Compare call, collection,
    binary-argument, bitwise-grouping, and indentation-pressure alternatives
    over representative Toit repositories.  Record the churn, retain one
    deterministic flat-decision policy with node-specific heuristics, and
    remove the development switches before enabling the command.

The golden corpus is specification data.  Each case checks exact output,
idempotence, reparsing, AST equivalence, and comment preservation.  Corpus
runs supplement these focused cases but do not replace them.
