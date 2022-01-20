// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field / any := 42
  fun / Lambda
  fun2 / Lambda
  fun3 / Lambda? := null
  fun4 / Lambda? := null

  constructor:
    fun  = :: field
    fun2 = :: this.field
    super
    fun3 = :: this.field
    fun4 = :: (this).field  // This is the only lambda that does a dynamic lookup.

class B extends A:
  constructor:
    super

  field:
    return 499

main:
  b := B
  expect_equals 42 b.fun.call
  expect_equals 42 b.fun2.call
  expect_equals 42 b.fun3.call
  expect_equals 499 b.fun4.call
