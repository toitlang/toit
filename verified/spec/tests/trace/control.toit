// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// A compute-only workload for the trace comparison: blocks, lambdas,
// non-local returns and branches, try/finally and exceptions.

class Counter:
  count := 0
  step/int
  constructor .step:
  bump -> int:
    count += step
    return count

find list/List target/int -> int:
  list.size.repeat:
    if list[it] == target: return it
  return -1

nested-break -> int:
  result := 0
  for i := 0; i < 50; i++:
    [1, 2, 3].do:
      if i > 40: break
      result += it
  return result

finally-count := 0

protected n/int -> int:
  try:
    if n % 3 == 0: throw "boom $n"
    return n
  finally:
    finally-count++

main:
  list := List 100: it * 3
  hits := 0
  200.repeat: if (find list it) >= 0: hits++
  counter := Counter 3
  lambdas := List 20: :: counter.bump
  lambdas.do: it.call
  caught := 0
  sum := 0
  300.repeat:
    e := catch: sum += protected it
    if e: caught++
  print "$hits $counter.count $(nested-break) $caught $sum $finally-count"
