// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field := ?
  field2 /any := ?
  field3 /int := ?

  field4 ::= ?
  field5 /any ::= ?
  field6 /int ::= ?

  constructor .field .field2 .field3 .field4 .field5 .field6:

  constructor.named x:
    field = x
    field2 = x
    field3 = x
    field4 = x
    field5 = x
    field6 = x

main:
  a := A 1 2 3 4 5 6
  expect_equals 1 a.field
  expect_equals 2 a.field2
  expect_equals 3 a.field3
  expect_equals 4 a.field4
  expect_equals 5 a.field5
  expect_equals 6 a.field6

  a.field = 499
  a.field2 = 42
  a.field3 = 314
  expect_equals 499 a.field
  expect_equals 42 a.field2
  expect_equals 314 a.field3

  a2 := A.named 499
  expect_equals 499 a2.field
  expect_equals 499 a2.field2
  expect_equals 499 a2.field3
  expect_equals 499 a2.field4
  expect_equals 499 a2.field5
  expect_equals 499 a2.field6
