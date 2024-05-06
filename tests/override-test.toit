// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .confuse

class A:
  foo x=0:
    return "A $x"

class B extends A:
  foo x:
    return "B $x"

main:
  actually-b := (confuse 0) == 0 ? B : A
  expect-equals "B 5" (actually-b.foo 5)
  // Since `foo` is not overridden in B we fall back to A.foo.
  // However, it's important that the stub doesn't redirect to B.foo.
  expect-equals "A 0" actually-b.foo
