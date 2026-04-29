// Control-flow canonicalisation: a single-stmt-body If or While
// produces inline form when the rendered total fits
// INLINE_CONTROL_FLOW_WIDTH (60), broken otherwise. The choice is a
// function of (AST + width), not of the source's layout.

main:
  // Source-broken short If: collapsed to inline.
  if x > 0:
    return x
  // Source-inline short If: stays inline.
  if y > 0: return y

  // Source-broken short While: collapsed.
  while x < 10:
    x++
  // Source-inline short While: stays.
  while y < 10: y++

  // Inline form ≤ 60 cols: stays inline.
  if x: return x
  while y: y++

  // Source-inline but > 60 cols: forced to broken.
  if very-long-cond and another-long-cond: do-something with-many args here

  // Source-broken and inline form > 60 cols: stays broken.
  if very-long-cond and another-long-cond:
    do-something with-many args here

  // Body has multiple stmts: must be broken regardless of width.
  if x:
    a
    b

x := 0
y := 0
very-long-cond := true
another-long-cond := true

a: return 0
b: return 0
do-something a b c d -> any: return 0
with-many: return 0
args: return 0
here: return 0
