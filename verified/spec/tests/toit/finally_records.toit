// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Finally codes entered by an unwinding (format note 17): nested try/finally
// inside finally code, breaks out of finally code, and the value slot.

log := []

// A non-local return passes a finally whose code runs another try/finally
// left by a non-local branch (a `break` in a block): the outer return must
// still complete.
outer-return-survives-inner-branch -> int:
  try:
    [1].do: return 1
  finally:
    while true:
      try:
        [2].do: break
      finally:
        log.add "inner finally"
      log.add "after inner"
      break
    log.add "outer finally"
  return 0

// The exception passes the inner finally, which a `break` leaves (swallowing
// it); the outer unwinding (a throw) resumes afterwards.
inner-break-swallows -> none:
  try:
    throw "outer"
  finally: | is-exception exception |
    while true:
      try:
        throw "inner"
      finally:
        break
    log.add "outer finally $is-exception $exception.value"

// A loop whose finally code breaks out on every iteration while an
// exception is pending: the stale records must not accumulate.
loop-break-out-of-finally n/int -> int:
  count := 0
  while count < n:
    try:
      throw "x"
    finally:
      count++
      continue
  return count

// The first slot of a finally code entered by a non-local return holds the
// return value.
return-value-visible -> any:
  seen := null
  [0].do:
    try:
      return 7
    finally: | is-exception value |
      seen = is-exception
  return seen

catch-in-finally -> int:
  result := 0
  try:
    try:
      return 5
    finally:
      result = catch: throw "in finally"
  finally:
    log.add "caught $result"
  return -1

main:
  log.add "r=$outer-return-survives-inner-branch"
  catch: inner-break-swallows
  log.add "loop=$(loop-break-out-of-finally 1000)"
  log.add "rv=$return-value-visible"
  log.add "cf=$catch-in-finally"
  log.do: print it
