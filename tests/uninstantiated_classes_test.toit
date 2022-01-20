// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Test that uninstantiated classes don't drag in code.

This code is used in the same-named optimization test.
*/

import expect show *

class A:
  foo: return "A|B.foo"
  bar: return "A.bar"
  gee: return "A.gee"

class B extends A:
  foo: return super
  bar: return "B.bar"
  gee: return "B.gee"

class C extends A:
  foo: return "C.foo"
  bar: return "C.bar"

main:
  // Class A should be shaken away, but we should still have A.foo,
  // as it's used in the `super` call of B.foo.
  expect_equals "A|B.foo" (B).foo
  expect_equals "B.bar" (B).bar
  expect_equals "B.gee" (B).gee

  expect_equals "C.foo" (C).foo
  expect_equals "C.bar" (C).bar
  expect_equals "A.gee" (C).gee
