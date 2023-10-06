// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

abstract mixin M1:
  abstract foo x y

class A extends Object with M1:
  foo x y: return x + y

class B:
  foo x y: return x * y

class C extends B with M1:
  foo:
    return super 2 3

mixin M2:
  foo:

abstract mixin M3 extends M2:
  abstract foo x=null

class D extends Object with M3:
  foo x: return x

mixin Empty:

mixin M4 extends Empty with M2:

abstract mixin M5 extends Empty with M4:
  abstract foo x=null

class E extends Object with M5:
  foo x: return x

main:
  a := A
  expect_equals 3 (a.foo 1 2)
  c := C
  expect_equals 6 c.foo
  d := D
  expect_equals 42 (d.foo 42)
  e := E
  expect_equals 42 (e.foo 42)
