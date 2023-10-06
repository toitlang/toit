// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  foo: return 1

abstract class B extends A:
  abstract foo x=null

class C extends B:
  foo x=null:
    return super

class D:
  foo:
    return 33

confuse x: return x

main:
  c := confuse C
  expect_equals 1 c.foo
  expect_equals 1 (c.foo 1)

  d := confuse D
  expect_equals 33 d.foo
