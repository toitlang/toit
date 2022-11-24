// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  test_simple

test_simple:
  a := A 12
  id a.x  // Expect: smi|string|null
  a = A "horse"
  id a.x  // Expect: smi|string|null

  b := B true 42
  id b.x  // Expect: true|null
  id b.y  // Expect: smi|null

id x:
  return x

class A:
  x ::= ?
  constructor .x:

class B extends A:
  y ::= ?
  constructor x .y:
    super x
