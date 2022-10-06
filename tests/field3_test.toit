// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field / any := 42
  func / Lambda
  func2 / Lambda
  func3 / Lambda? := null
  func4 / Lambda? := null

  constructor:
    func  = :: field
    func2 = :: this.field
    super
    func3 = :: this.field
    func4 = :: (this).field  // This is the only lambda that does a dynamic lookup.

class B extends A:
  constructor:
    super

  field:
    return 499

main:
  b := B
  expect_equals 42 b.func.call
  expect_equals 42 b.func2.call
  expect_equals 42 b.func3.call
  expect_equals 499 b.func4.call
