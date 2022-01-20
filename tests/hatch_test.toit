// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  // TODO(kasper): Need new way of communicating between processes.

/*
test_simple
  other := hatch_::
    respond:
      expect_equals 42 it
      it + 45
  expect_equals
    87
    other.send 42

test_nested
  other := hatch_:: respond: | n | task:: respond: n + it + 3
  expect_equals
    6
    (other.send 1).send 2

test_code
  worker := hatch_::
    respond: it.call
    respond: it.call + 1
  expect_equals
    42
    worker.send:: 42
  expect_equals
    23
    worker.send:: 22

test_fib
  expect_equals 21
    fib 8
  expect_equals 55
    fib 10

fib n
  if n <= 2: return 1
  n1 := hatch_:: respond: fib it - 1
  n2 := hatch_:: respond: fib it - 2
  return (n1.send n) + (n2.send n)

test_chain
  expect_equals
    10
    (create_chain 10 0).send 0
  expect_equals
    100 + 87 + 42
    (create_chain 100 87).send 42
  expect_equals
    300
    (create_chain 200 99).send 1

create_chain n seed
  result := hatch_:: respond: it + seed
  for i := 0; i < n; i++:
    sub := result
    result = hatch_:: respond: sub.send (it + 1)
  return result
*/
