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

class D extends C:
  foo:
    return 33

confuse x: return x

main:
  c := confuse C
  expect-equals 1 c.foo
  expect-equals 1 (c.foo 1)

  d := confuse D
  expect-equals 33 d.foo
  expect-equals 1 (d.foo 1)
