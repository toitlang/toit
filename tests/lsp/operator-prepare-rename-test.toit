// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming an operator should be refused (prepareRename returns null).

class Vec:
  x := 0
  y := 0
  constructor .x .y:

  operator + other/Vec -> Vec:
/*
           ^
  null
*/
    return Vec (x + other.x) (y + other.y)

main:
  a := Vec 1 2
  b := Vec 3 4
  c := a + b
