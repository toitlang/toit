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
  expect_equals a1 a2
  expect (identical a1 a1)
  expect (identical a2 a2)
  expect_identical a1 a1
  expect_identical a2 a2

  expect (not identical a1 a2)
  expect_not_identical a1 a2

  expect_equals 0 0.0
  expect_not_identical 0 0.0
  expect_identical 1.0 (sum 0.0 1.0)
  expect_equals 0.0 -0.0
  expect_not_identical 0.0 -0.0
  expect_identical -0.0 (-(sum -0.0 0.0) - 0.0)

  expect_identical float.NAN float.NAN
  expect_not_identical float.NAN (float.from_bits (float.NAN.bits + 1))

  expect_equals 0x7FFF_FFFF_FFFF_FFFF 0x7FFF_FFFF_FFFF_FFFF
  expect_equals 0x7FFF_FFFF_FFFF_FFFF (sum 0x7FFF_FFFF_FFFF_FFF0 0xF)
  expect_identical 0x7FFF_FFFF_FFFF_FFFF (sum 0x7FFF_FFFF_FFFF_FFF0 0xF)
