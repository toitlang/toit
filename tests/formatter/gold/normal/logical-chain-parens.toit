main:
  // Mixed and/or, fits flat: the parse is unambiguous, no parens.
  if foo and bar or gee: print "x"

  // Breaks at the top-level operator: the line structure carries the
  // nesting, no parens needed.
  if first-long-condition and second-long-condition or third-long-condition and fourth-long-condition-extended:
    print "y"

  // A nested chain too wide on its own line: it breaks, and its
  // continuation lines would sit at the same indent as the outer
  // chain's — parens make the grouping visible.
  if foo and (first-long-condition or second-long-condition or third-long-condition or fourth-long-condition-extended):
    print "z"

foo := true
bar := true
gee := true
first-long-condition := true
second-long-condition := true
third-long-condition := true
fourth-long-condition-extended := true
