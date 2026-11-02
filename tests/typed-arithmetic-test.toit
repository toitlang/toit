// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Native code does arithmetic on values with known types without leaving the
// code it's in, and it keeps floats unboxed. These are the rare paths through
// that: leaving the smi range, wrapping around and running out of new space.

add a/int b/int -> int: return a + b
sub a/int b/int -> int: return a - b
mul a/int b/int -> int: return a * b

test-overflow:
  max := 0x3fff_ffff_ffff_ffff
  expect-equals 0x4000_0000_0000_0000 (add max 1)
  expect-equals 0x7fff_ffff_ffff_fffe (add max max)
  min := -(0x3fff_ffff_ffff_ffff) - 1
  expect-equals min - 1 (sub min 1)
  expect-equals 0x4000_0000 * 0x4000_0000 (mul 0x4000_0000 0x4000_0000)
  // Large integers on both sides.
  big := 0x7fff_ffff_ffff_ffff
  expect-equals 0x8000_0000_0000_0000 (add big 1)
  expect-equals big (sub 0x8000_0000_0000_0000 1)
  expect-equals 1 (mul big big)
  expect-equals 0 (add big -big)
  expect-equals 0 (mul 0x1_0000_0000 0x1_0000_0000)

test-mixed-locals:
  x := 0x3fff_ffff_ffff_ffff
  y := x
  x = x + 1
  expect-equals 0x4000_0000_0000_0000 x
  expect-equals 0x3fff_ffff_ffff_ffff y
  z := x + y - x
  expect-equals y z

scale a/float b/float -> float: return a * b

test-unboxed a/float b/float:
  // A chain that doesn't need any boxes on the way.
  expect-equals 16.5 (a * b + a * b - a + 0.5 + a + a * 0.0 - 0.0)
  x := a + b
  y := x * x
  expect-equals 6.0 x
  expect-equals 36.0 y
  list := [x, y, x + y]
  expect-equals 42.0 list[2]
  expect-equals 6.0 list[0]
  expect-equals true (x < y)
  expect-equals false (x > y)
  expect-equals false (x == y)
  is-less := x < y
  expect is-less
  nan := 0.0 / 0.0
  expect-equals false (nan == nan)
  expect-equals true (0.0 == -0.0)
  expect-equals float.INFINITY (a / 0.0)

test-boxing-under-pressure:
  sum := 0.0
  floats := []
  20000.repeat: | i |
    a := i.to-float
    b := a * 2.0 + 1.0
    garbage := List 8
    floats.add b + a
    if floats.size > 100: floats = floats[50..].copy
    sum = sum + b
  expect-equals 400000000.0 sum
  total := 0
  list := List 1000: it
  100.repeat:
    keep := []
    list.do: keep.add it * 0x7fff_ffff_ffff
    total = keep[999]
  expect-equals 999 * 0x7fff_ffff_ffff total

main:
  test-overflow
  test-mixed-locals
  test-unboxed 2.0 4.0
  test-boxing-under-pressure
