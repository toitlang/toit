// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

counter := 0
COUNTER_MAX ::= 5
counter_fun:
  if counter < COUNTER_MAX: return counter++
  return null

main:
  funs := []
  while i := counter_fun:
    funs.add (:: i)
  expect_equals COUNTER_MAX funs.size
  COUNTER_MAX.repeat:
    expect_equals it funs[it].call
