// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  x := 0
  y := 1
  z := -1

  constructor .x:
    this.y = 2

  constructor.foo .x .y:
    this.z = x + y

  bar:
    return 499

main:
  a := A.foo 3 4
  expect_equals 3 a.x
  expect_equals 4 a.y
  expect_equals 7 a.z
  expect_equals true (a is A)
  expect_equals 499 (a.bar)
