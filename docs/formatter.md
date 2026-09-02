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

Every comment is consumed exactly once.  Own-line comments are assigned to
the following list item, or to the enclosing list when they follow its final
AST node.  Indentation disambiguates comments in nested statement sequences.

## Layout selection

AST printers construct a small set of legal, node-specific output shapes.
There is no general token-order layout IR and no post-selection relocation or
syntax-repair phase.  Required parentheses and reordered semantic pieces are
part of each candidate before it is measured.

Candidates are selected with a soft score rather than a maximum width.  The
score considers:

* line extent beyond a preferred region;
* the number of additional physical lines;
* the number of items split across lines;
* construct-specific readability costs; and
* optional, slight pressure from the current indentation.

An indented construct may extend farther right than a top-level construct.
Indentation may nevertheless move the soft breaking point slightly left
relative to the construct.  Neither condition is a hard limit.

Compact calls with many arguments may stay flat beyond the preferred extent
when breaking would introduce many lines.  A `\` continuation is a legal
candidate when it provides a better result than either one long physical line
or one argument per line.

Initial canonical choices are:

* two spaces for suites, members, and collection contents;
* four spaces for continuation lines;
* trailing `and` and `or` at a logical line break;
* leading operators for other broken binary expressions;
* at most two preserved blank lines; and
* two spaces before a trailing comment unless it is lexically attached.

Collection and call shapes deliberately remain scoring experiments.  Internal
style switches may compare alternatives during development, but the released
formatter will expose one canonical style rather than user configuration.

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
* `{}` is an empty set and `{:}` is an empty map.
* Parentheses in `(Foo).bar` may affect resolution.  Preserve them without
  resolution data; remove them only when resolution proves that lookup is
  unchanged.

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
5. **Add scoring and output primitives.** Add a small line-oriented output
   builder and candidate scorer.  Test soft width, line/item pressure,
   indentation pressure, and dominance pruning.  This layer contains no Toit
   syntax policy.
6. **Print atoms and precedence expressions.** Cover identifiers, literals,
   unary, binary, dot, index, slice, and ternary expressions.  Reconstruct
   only required or selected clarity parentheses and verify every result by
   reparsing.
7. **Print method and declaration headers.** Cover parameters, return-type
   movement, fields, classes, imports, and exports, including comments that
   move with semantic pieces.
8. **Print calls and suites.** Add flat, unnamed-prefix/named-continuation,
   fully broken, and backslash-continuation candidates.  Cover blocks,
   lambdas, greedy calls, and layout-dependent parentheses.
9. **Print collections.** Add flat, packed-row, and one-item-per-line
   candidates for lists, sets, maps, and byte arrays, including all comment
   slots and trailing commas.
10. **Print statements and bodies.** Cover declarations, assignments,
    returns, control flow, loops, try/finally, empty suites, inline suites, and
    complete comment ownership across nested sequences.
11. **Print complete units.** Preserve preambles, Toitdoc, declaration order,
    blank lines, and the final newline.  Unsupported AST kinds fail explicitly
    rather than silently copying arbitrary source regions.
12. **Integrate `toit format`.** Add the hidden CLI command, verifier gate,
    atomic in-place writes, golden tests, idempotence tests, and corpus-level
    formatting over `lib`, `tools`, and `examples`.
13. **Calibrate canonical choices.** Run experimental call, collection,
    binary-argument, and indentation-pressure modes over representative Toit
    repositories.  Record churn and shape counts, choose one mode for each,
    and remove the development switches before enabling the command.

The golden corpus is specification data.  Each case checks exact output,
idempotence, reparsing, AST equivalence, and comment preservation.  Corpus
runs supplement these focused cases but do not replace them.
