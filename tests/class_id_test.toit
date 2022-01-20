// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:

class B extends A:

main:
  a := A
  a2 := A
  expect_not_equals a a2

  b := B

  a_id := Object.class_id a
  a2_id := Object.class_id a2
  expect_equals a_id a2_id

  b_id := Object.class_id b
  expect_not_equals b_id a_id
