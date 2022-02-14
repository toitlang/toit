// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  b :=: 499
  expect_equals 499 b.call

  b2 := (: 499)
  expect_equals 499 b2.call

  b3 := : |x y| x + y
  expect_equals 499 (b3.call 400 99)

  b4 ::=: 499
  expect_equals 499 b4.call

  b5 ::= (: 499)
  expect_equals 499 b5.call

  b6 ::= : |x y| x + y
  expect_equals 499 (b6.call 400 99)
