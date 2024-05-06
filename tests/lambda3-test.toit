// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  fun := null

  constructor:
  constructor .fun:

  foo: return fun.call
  bar: return 499

  test:
    x := 0
    result := :: x
    x++
    return result

was-executed := false
class B:
  foo:
    a := null
    a = A::
      expect-equals 499 a.bar
      was-executed = true
    return a

main:
  f := (A).test
  expect-equals 1 f.call

  a := (B).foo
  a.foo
  expect was-executed
