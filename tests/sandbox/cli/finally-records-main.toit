// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. Finally code entered by an unwinding
// keeps the pending unwinding in its own slots (format 3, two token words:
// verified/spec/format/23-format3-try.md; before, a finally record,
// 17-finally-records.md): it must survive calls, stack growth, GC and task
// switches, and nested try/finally inside finally code.

deep n/int -> int:
  if n == 0: return 0
  return 1 + (deep n - 1)

// Non-local returns pass finally code that recurses (the stack grows with
// live records), allocates (GC) and yields (task switches with records).
nested level/int -> int:
  [0].do:
    try:
      if level > 0:
        return nested level - 1
      return 100
    finally:
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

log := []

// A `break` out of an inner finally (entered by a branch) inside the outer
// finally code: the outer return still completes.
outer-return-survives-inner-branch -> int:
  try:
    [1].do: return 1
  finally:
    while true:
      try:
        [2].do: break
      finally:
        log.add "inner"
      break
  return 0

// Breaking out of finally code on every iteration while an exception is
// pending: the stale records do not accumulate.
loop-break-out-of-finally n/int -> int:
  count := 0
  while count < n:
    try:
      throw "x"
    finally:
      count++
      continue
  return count

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
  print "r=$outer-return-survives-inner-branch $log"
  print "loop=$(loop-break-out-of-finally 100000)"
  print "finally records done"
