// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Native code can reuse the object of a float that nothing else refers to for
// the result of the next operation. Values that are still in use must not change.

class Box:
  value/float := 0.0

identity x/float -> float: return x

test-expressions a/float b/float c/float d/float:
  expect-equals 26.0 (a * b + c * d)
  expect-equals -22.0 (a * b - c * d)
  expect-equals 28.5 (a + b) * (c + d) / 2.0 + 12.0
  expect-equals 2.0 (a + a) * (a + a) / 2.0
  expect-equals 0.25 a / (b + b)

test-locals a/float b/float:
  x := a * b
  y := x + 1.0
  expect-equals 2.0 x
  expect-equals 3.0 y
  z := x + x
  expect-equals 4.0 z
  expect-equals 2.0 x

test-stored a/float b/float:
  box := Box
  box.value = a + b
  sum := box.value + 1.0
  expect-equals 3.0 box.value
  expect-equals 4.0 sum
  list := [a + b, 0.0]
  sum = list[0] * 2.0
  expect-equals 3.0 list[0]
  expect-equals 6.0 sum

test-arguments a/float b/float:
  x := identity a + b
  y := (identity x) + 1.0
  expect-equals 3.0 x
  expect-equals 4.0 y

test-branches a/float b/float:
  x := a + b
  y := x > 2.0 ? x + 1.0 : x - 1.0
  expect-equals 3.0 x
  expect-equals 4.0 y

test-loop a/float:
  sum := 0.0
  last := 0.0
  10.repeat:
    last = sum
    sum = sum + a * 2.0
    expect-equals last + a * 2.0 sum
  expect-equals 20.0 sum

test-literals:
  // Literals are shared, so they cannot be reused.
  10.repeat:
    x := 1.5
    y := x + 1.0 + 1.0
    expect-equals 1.5 x
    expect-equals 3.5 y

main:
  test-expressions 1.0 2.0 3.0 8.0
  test-locals 1.0 2.0
  test-stored 1.0 2.0
  test-arguments 1.0 2.0
  test-branches 1.0 2.0
  test-loop 1.0
  test-literals
