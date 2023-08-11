// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:

class B extends A:

main:
  a := A
  a2 := A
  expect-not-equals a a2

  b := B

  a-id := Object.class-id a
  a2-id := Object.class-id a2
  expect-equals a-id a2-id

  b-id := Object.class-id b
  expect-not-equals b-id a-id
