// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Regression test. This code yielded an argument-mismatch error.

class A:
  constructor.internal:

  constructor:
    return A 1 2

  constructor x y:
    return A.internal

main:
  a := A
