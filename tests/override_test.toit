// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  foo x=0:
    return "A $x"

class B extends A:
  foo x:
    return "B $x"

confuse x: return x

main:
  actually_b := (confuse 0) == 0 ? B : A
  expect_equals "B 5" (actually_b.foo 5)
  // Since `foo` is not overridden in B we fall back to A.foo.
  // However, it's important that the stub doesn't redirect to B.foo.
  expect_equals "A 0" actually_b.foo
