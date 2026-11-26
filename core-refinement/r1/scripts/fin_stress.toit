// Copyright (C) 2026 Toit contributors.
// Finally records across stack growth, GC and task switches.

deep n/int -> int:
  if n == 0: return 0
  return 1 + (deep n - 1)

// Unwinding by a non-local return; the finally code recurses deeply (stack
// growth with live records) and yields (task switch with live records).
nested level/int -> int:
  [0].do:
    try:
      if level > 0:
        return nested level - 1
      return 100
    finally: | is-exception value |
      d := deep 300
      yield
      list := List 1000: it
      if d != 300 or list.size != 1000: throw "bad"
  return -1

thrower level/int:
  try:
    if level == 0: throw "boom"
    thrower level - 1
  finally:
    yield
    deep 200

main:
  results := []
  done := 0
  3.repeat: | t |
    task::
      sum := 0
      20.repeat: sum += nested 5
      e := catch: thrower 10
      results.add "$t: $sum $e"
      done++
  while done < 3: yield
  results.sort.do: print it
