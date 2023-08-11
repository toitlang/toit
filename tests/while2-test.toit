// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

counter := 0
COUNTER-MAX ::= 5
counter-fun:
  if counter < COUNTER-MAX: return counter++
  return null

main:
  funs := []
  while i := counter-fun:
    funs.add (:: i)
  expect-equals COUNTER-MAX funs.size
  COUNTER-MAX.repeat:
    expect-equals it funs[it].call
