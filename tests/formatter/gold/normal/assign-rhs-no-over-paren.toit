main:
  // RHS of an assignment is at a stmt-level boundary — no defensive
  // parens needed around the Call even though it's not at outer NONE
  // per precedence walking.
  x := compute a b c
  y := other-call 1 2 3
  // Redundant source parens on an assignment RHS are dropped.
  z := (other-call 1 2 3)
  // A Binary RHS (no Call) still renders without parens.
  w := 1 + 2 * 3

compute a b c -> any:
  return null

other-call a b c -> any:
  return null
