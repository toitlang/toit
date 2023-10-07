// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field / any := 42
  fun1 / Lambda? := null
  fun2 / Lambda? := null

  constructor:
    super
    // After a `super` call, `this` is dynamic.
    fun1 = :: this.field
    fun2 = :: (this).field

class B extends A:
  constructor:
    super

  field:
    return 499

main:
  b := B
  expect-equals 499 b.fun1.call
  expect-equals 499 b.fun2.call
