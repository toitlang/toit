// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:

main:
  a := A
  a2 := null or a
  expect-equals a a2

  a2 = a or false
  expect-equals a a2

  a2 = a or unreachable
  expect-equals a a2

  x := a and null
  expect-null x

  x = null and a
  expect-null x

  a3 := A

  a4 := (a and null) or
    (a and a3)
  expect-equals a3 a4
