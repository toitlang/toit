// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

class A:

main:
  a := A
  a2 := null or a
  expect_equals a a2

  a2 = a or false
  expect_equals a a2

  a2 = a or unreachable
  expect_equals a a2

  x := a and null
  expect_null x

  x = null and a
  expect_null x

  a3 := A

  a4 := (a and null) or
    (a and a3)
  expect_equals a3 a4
