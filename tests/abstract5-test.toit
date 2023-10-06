// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  foo: return 1

abstract class B extends A:
  abstract foo x=null

class C extends B:
  foo x: return 2

abstract class D:
  abstract foo x=null
  foo: return 1

class E extends D:
  foo x: return 2

main:
  c := C
  expect_equals 1 c.foo
  expect_equals 2 (c.foo 1)

  e := E
  expect_equals 1 e.foo
  expect_equals 2 (e.foo 1)
