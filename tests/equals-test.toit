// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

counter := 0

class A:
  operator == other:
    counter++
    return identical other this

class B:
  operator == other -> bool:
    throw "Unreachable since only called with null."

confuse x:
  return x

class C:
  x := 0

  foo:
    // We must keep a virtual equality call here,
    // since the RHS might be null, and the interpreter
    // checks for the null case first.
    return this == (confuse null)

  operator == other:
    return other.x == 0

nul: return null

foo b / B:
  expect-not (b == nul)

main:
  a1 := A
  a2 := A
  expect-equals a1 a1
  expect-equals 0 counter
  expect (not a1 == a2)
  expect-equals 1 counter
  expect (not B == null)
  foo B

  c := C
  expect (not c.foo)
