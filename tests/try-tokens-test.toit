// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Try/finally since format 3 (verified/spec/format/23-format3-try.md): TRY
// calls its try block as a flagged block call, and the pending unwinding
// lives in the finally code's own slots (two token words next to the value
// and the reason). These are the semantic cases of that mechanism: nesting,
// finally code inside finally code, unwindings that finally code replaces
// or drops, and finally code that calls, grows the stack, collects and
// yields while an unwinding is pending.

import expect show *
import monitor

log := []

main:
  test-normal-completion
  test-deep-exception
  test-deep-non-local-return
  test-non-local-branch
  test-finally-inside-finally
  test-finally-throws
  test-finally-returns
  test-finally-breaks
  test-finally-continues
  test-finally-parameters
  test-catch-inside-finally
  test-heavy-finally
  test-task-switch-in-finally
  test-monitor
  test-many-sequential
  // tests/sandbox/CMakeLists.txt runs this test untrusted too.
  print "try tokens done"

// --- Normal completion: the finally code runs once, the value is kept. ---

test-normal-completion:
  log.clear
  x := 0
  try:
    x = 1
  finally:
    log.add "f"
  expect-equals 1 x
  expect-equals ["f"] log
  expect-equals 7 (value-through-finally 7)

value-through-finally v/int -> int:
  result := 0
  try:
    result = v
  finally:
    result++
  return result - 1

// --- An exception through many finally codes (deep recursion). ---

nest-throw n/int:
  try:
    if n == 0: throw "deep"
    nest-throw n - 1
  finally:
    log.add n

test-deep-exception:
  log.clear
  e := catch: nest-throw 50
  expect-equals "deep" e
  expect-equals 51 log.size
  51.repeat: expect-equals it log[it]

// --- A non-local return through many finally codes (nested blocks). ---

nest-return n/int [block] -> int:
  [0].do:
    try:
      if n == 0: block.call
      return nest-return n - 1 block
    finally:
      log.add n
  unreachable

through-many -> int:
  nest-return 40: return 99
  return -1

test-deep-non-local-return:
  log.clear
  expect-equals 99 through-many
  expect-equals 41 log.size
  41.repeat: expect-equals it log[it]

// --- A non-local branch (break out of a loop from a block) through finally. ---

test-non-local-branch:
  log.clear
  count := 0
  i := 0
  while true:
    i++
    [i].do: | j |
      try:
        try:
          if j == 3: break
          count += j
        finally:
          log.add "inner $j"
      finally:
        log.add "outer $j"
  expect-equals 3 count
  expect-equals ["inner 1", "outer 1", "inner 2", "outer 2", "inner 3", "outer 3"] log
  // A continue out of a block through finally code.
  log.clear
  k := 0
  while k < 3:
    k++
    [k].do: | j |
      try:
        continue
      finally:
        log.add "c $j"
    log.add "unreached"
  expect-equals ["c 1", "c 2", "c 3"] log

// --- Finally code with its own try/finally while an unwinding is pending. ---

inner-in-finally depth/int:
  try:
    throw "outer $depth"
  finally:
    if depth > 0:
      // The nested try completes normally, then the outer unwinding resumes.
      try:
        log.add "nested $depth"
      finally:
        log.add "nested-finally $depth"
      e := catch: inner-in-finally depth - 1
      log.add e

test-finally-inside-finally:
  log.clear
  e := catch: inner-in-finally 3
  expect-equals "outer 3" e
  expect-equals [
    "nested 3", "nested-finally 3",
    "nested 2", "nested-finally 2",
    "nested 1", "nested-finally 1",
    "outer 0", "outer 1", "outer 2",
  ] log

// --- Finally code that throws: the pending unwinding is dropped. ---

throw-replaces:
  try:
    throw "first"
  finally:
    throw "second"

return-then-throw -> int:
  [0].do:
    try:
      return 1
    finally:
      throw "replaced return"
  return 2

test-finally-throws:
  expect-equals "second" (catch: throw-replaces)
  expect-equals "replaced return" (catch: return-then-throw)

// --- Finally code that returns: the pending exception is dropped. ---

return-drops-exception -> int:
  try:
    throw "dropped"
  finally:
    return 42
  unreachable

non-local-return-drops [block] -> int:
  block.call
  return -1

return-in-finally-of-block -> int:
  non-local-return-drops:
    try:
      throw "dropped too"
    finally:
      return 43
  return -2

test-finally-returns:
  expect-equals 42 return-drops-exception
  expect-equals 43 return-in-finally-of-block

// --- Finally code that breaks or continues: the unwinding is dropped. ---

test-finally-breaks:
  count := 0
  while true:
    try:
      throw "dropped"
    finally:
      count++
      break
  expect-equals 1 count
  // A break out of a block loop inside finally code, dropping a pending
  // non-local return.
  expect-equals 5 break-drops-return

break-drops-return -> int:
  result := 0
  while true:
    [1].do:
      try:
        return 1
      finally:
        result = 5
        break
  return result

test-finally-continues:
  n := 0
  i := 0
  while i < 1000:
    i++
    try:
      if i % 2 == 0: throw "x"
      n++
    finally:
      continue
  expect-equals 1000 i
  expect-equals 500 n

// --- The finally parameters: the reason and the value. ---

test-finally-parameters:
  log.clear
  catch:
    try:
      throw "boom"
    finally: | is-exception exception |
      log.add "$is-exception $exception.value"
  try:
    null
  finally: | is-exception exception |
    log.add "$is-exception $exception"
  expect-equals ["true boom", "false null"] log

// --- A catch inside finally code while an exception is pending. ---

test-catch-inside-finally:
  log.clear
  e := catch:
    try:
      throw "pending"
    finally:
      log.add (catch: throw "inner")
  expect-equals "pending" e
  expect-equals ["inner"] log

// --- Finally code that recurses deeply (stack growth) and allocates (GC). ---

deep n/int -> int:
  if n == 0: return 0
  return 1 + (deep n - 1)

heavy level/int -> int:
  [0].do:
    try:
      if level > 0: return heavy level - 1
      return 100
    finally:
      d := deep 500
      list := List 2000: it
      if d != 500 or list.size != 2000: throw "bad"
  return -1

test-heavy-finally:
  sum := 0
  10.repeat: sum += heavy 5
  expect-equals 1000 sum
  e := catch:
    try:
      throw "kept"
    finally:
      expect-equals 400 (deep 400)
  expect-equals "kept" e
  // A stack overflow inside finally code unwinds from there: it replaces
  // the pending exception (as an exception the finally code throws).
  e = catch:
    try:
      throw "lost"
    finally:
      deep 100000
  expect-equals "STACK_OVERFLOW" e
  // Caught inside the finally code, it leaves the pending exception.
  e = catch:
    try:
      throw "kept again"
    finally:
      expect-equals "STACK_OVERFLOW" (catch: deep 100000)
  expect-equals "kept again" e

// --- Task switches inside finally code with pending unwindings. ---

switching level/int -> int:
  [0].do:
    try:
      if level > 0: return switching level - 1
      return 1
    finally:
      yield
  return -1

switching-throw level/int:
  try:
    if level == 0: throw "switched"
    switching-throw level - 1
  finally:
    yield
    deep 100

test-task-switch-in-finally:
  results := []
  done := 0
  4.repeat: | t |
    task::
      sum := 0
      20.repeat: sum += switching 6
      e := catch: switching-throw 8
      results.add "$t $sum $e"
      done++
  while done < 4: yield
  expect-equals ["0 20 switched", "1 20 switched", "2 20 switched", "3 20 switched"] results.sort

// --- The monitor pattern: a return out of a locked method's body. ---

monitor Counter:
  n := 0
  increment-and-return-early -> int:
    n++
    if n > 0: return n
    return -1

test-monitor:
  c := Counter
  expect-equals 1 c.increment-and-return-early
  expect-equals 2 c.increment-and-return-early

// --- Many try/finally in a row do not accumulate anything. ---

test-many-sequential:
  total := 0
  100000.repeat:
    try:
      total++
    finally:
      total++
  expect-equals 200000 total
