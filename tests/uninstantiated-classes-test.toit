// Copyright (C) 2020 Toitware ApS.
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
  expect-equals "A|B.foo" (B).foo
  expect-equals "B.bar" (B).bar
  expect-equals "B.gee" (B).gee

  expect-equals "C.foo" (C).foo
  expect-equals "C.bar" (C).bar
  expect-equals "A.gee" (C).gee
