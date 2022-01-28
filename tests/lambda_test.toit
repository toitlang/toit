// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  x ::= 99

  foo:
    fun := (:: bar it)
    return fun.call 400

  bar b:
    return x + b

foo:
  y := 99
  fun := (:: it + y)
  return fun.call 400

main:
  expect_equals 499 (A).foo
  expect_equals 499 foo
  expect_equals
      1_000_001
      (:: |a| 1_000_000 + a).call 1
  expect_equals
      1_000_021
      (:: |a b| 1_000_000 + a + b * 10).call 1 2
  expect_equals
      1_000_321
      (:: |a b c| 1_000_000 + a + b * 10 + c * 100).call 1 2 3
  expect_equals
      1_004_321
      (:: |a b c d| 1_000_000 + a + b * 10 + c * 100 + d * 1_000).call 1 2 3 4
