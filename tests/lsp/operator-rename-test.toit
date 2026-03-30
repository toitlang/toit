// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: operator methods cannot be renamed.

class Vec:
  x := 0
  y := 0

  constructor .x .y:

  operator + other/Vec -> Vec:
/*
           ^
  []
*/
    return Vec (x + other.x) (y + other.y)

main:
  a := Vec 1 2
  b := Vec 3 4
  c := a + b
