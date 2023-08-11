// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

check-int63 large-int63:
  expect-equals 9223372036854775807 large-int63
  expect-equals 0xFFFFFFFF (large-int63 & 0xFFFFFFFF)
  expect-equals 0x7FFFFFFF (large-int63 >> 32)

check-neg-int63 neg-large-int63:
  expect-equals -9223372036854775808 neg-large-int63
  expect-equals 0x0 (neg-large-int63 & 0xFFFF_FFFF)
  expect-equals 0x8000_0000 ((neg-large-int63 >> 32) & 0xFFFF_FFFF)
  expect-equals neg-large-int63 (-neg-large-int63)

main:
  test-integer-literals
  test-float-literals

test-integer-literals:
  expect true --message="true test"
  expect true == true --message="true equals true test"
  expect false == false --message="false equals false test"
  expect 1000 == 250 * 4
  expect 1000000 > 1000
  expect-equals 255 0xff
  expect-equals 128 0X80
  expect-equals 10 010
  expect-equals 5 0b101
  expect-equals 5 0B101
  check-int63 9223372036854775807
  check-int63 0x7FFFFFFFFFFFFFFF
  check-int63 0b111111111111111111111111111111111111111111111111111111111111111
  expect-equals 255 0xf_f
  expect-equals 128 0X8_0
  expect-equals 10 0_1_0
  expect-equals 5 0b1_0_1
  expect-equals 5 0B1_01
  check-int63 922337_203685_4775807
  check-int63 0x7FFF_FFFF_FFFF_FFFF
  check-int63 0b111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111

  expected := -7
  expect-equals expected -7
  expected = -42
  expect-equals expected -42

  expect-equals -255 -(0xff)
  expect-equals -128 -(0X80)
  expect-equals -10 -010
  expect-equals -5 -(0b101)
  expect-equals -5 -(0B101)
  check-neg-int63 -9223372036854775808
  check-neg-int63 (-(0x7FFFFFFFFFFFFFFF) - 1)
  check-neg-int63 (-(0b111111111111111111111111111111111111111111111111111111111111111) - 1)
  check-neg-int63 (-(0b111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111) - 1)
  check-neg-int63 0x8000_0000_0000_0000
  check-neg-int63 0b1000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000

  expect-equals -1 0xFFFF_FFFF_FFFF_FFFF
  expect-equals -1 0b1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111_1111

  expect-equals 0 {}.size
  expect-equals 2 {1, 2}.size
  expect-equals 3 {1, 2, 3}.size

  expect-equals 0 {:}.size
  expect-equals 2 {1: 2, 2: 3}.size
  expect-equals 3 {1: 2, 2: 3, 3: 4}.size

  expect-equals 0x21 '!'
  expect-equals 0x41 'A'
  expect-equals 0x61 'a'
  expect-equals 0x27 '\''

test-float-literals:
  expected := -352.56376676179076
  expect-equals expected -352.56376676179076

  expect-equals 5.0 0_5.0_0
  expect-equals 0.0 0e+0
  expect-equals 10.0 1e1
  expect-equals 10.0 1e+1
  expect-equals 0.1 1e-1
  expect-equals 0.0 0e+00
  expect-equals 10.0 1e01
  expect-equals 10.0 1e+01
  expect-equals 0.1 1e-01
  expect-equals 0.0 0e+0_0
  expect-equals 10.0 1e0_1
  expect-equals 10.0 1e+0_1
  expect-equals 0.1 1e-0_1
  expect-equals 1234.5678 1_2_3_4.5_6_7_8
  expect-equals 1234.5678 1_2_3_4_5_6_7_8e-0_0_4

  expect-equals 5.0 0x0_5.0_0p0
  expect-equals 0.0 0x0P+0
  expect-equals 10.0 0xAp0
  expect-equals 16.0 0x1P4
  expect-equals 0.5 0x1p-1
  expect-equals 0.0 0x0P+00
  expect-equals 16.0 0x1p04
  expect-equals 16.0 0x1p+04
  expect-equals 255.0 0xFFP0
  expect-equals 16.0 0x100P-4
  expect-equals 0.0 0x0p+0_0
  expect-equals 2.0 0x1P0_1
  expect-equals 16.0 0x1p+0_4
  expect-equals 0.25 0x1p-0_2
  expect-equals 255.5 0xf_f.8_0_0p0
  expect-equals 255.000244140625 0xf_f.0_0_1p0
  expect-equals (255.000244140625 * 2) 0xf_f.0_0_1p1
  expect-equals (255.000244140625 * 4) 0xf_f.0_0_1p2
  expect-equals (255.000244140625 * 8) 0xf_f.0_0_1p3
  expect-equals (255.000244140625 * 16) 0xf_f.0_0_1p4

  expect-equals 1.7976931348623157e+308 1.7976931348623158e+308
  expect-equals 1.7976931348623157e+308 0x1F_FFFF_FFFF_FFFFp971
  expect-equals 5e-324 0x1p-1074
  // Denormals have very little precision.
  expect-equals 5e-324 5.0002e-324
