// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

counter := 0

class A:
  operator == other:
    counter++
    return identical other this

class B:
  operator == other -> bool:
    throw "Unreachable since only called with null."

nul: return null

foo b / B:
  expect_not (b == nul)

main:
  a1 := A
  a2 := A
  expect_equals a1 a1
  expect_equals 0 counter
  expect (not a1 == a2)
  expect_equals 1 counter
  expect (not B == null)
  foo B
