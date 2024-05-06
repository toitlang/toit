// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  operator == other: return true

sum a b: return a + b

main:
  a1 := A
  a2 := A
  expect-equals a1 a2
  expect (identical a1 a1)
  expect (identical a2 a2)
  expect-identical a1 a1
  expect-identical a2 a2

  expect (not identical a1 a2)
  expect-not-identical a1 a2

  expect-equals 0 0.0
  expect-not-identical 0 0.0
  expect-identical 1.0 (sum 0.0 1.0)
  expect-equals 0.0 -0.0
  expect-not-identical 0.0 -0.0
  expect-identical -0.0 (-(sum -0.0 0.0) - 0.0)

  expect-identical float.NAN float.NAN
  expect-not-identical float.NAN (float.from-bits (float.NAN.bits + 1))

  expect-equals 0x7FFF_FFFF_FFFF_FFFF 0x7FFF_FFFF_FFFF_FFFF
  expect-equals 0x7FFF_FFFF_FFFF_FFFF (sum 0x7FFF_FFFF_FFFF_FFF0 0xF)
  expect-identical 0x7FFF_FFFF_FFFF_FFFF (sum 0x7FFF_FFFF_FFFF_FFF0 0xF)
