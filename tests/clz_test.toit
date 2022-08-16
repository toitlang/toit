// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_clz

test_clz:
  expect_equals 0
    count_leading_zeros -1
  expect_equals 64
    count_leading_zeros 0
  expect_equals 55
    count_leading_zeros 0x100
  expect_equals 23
    count_leading_zeros 0x100_0000_0000

  expect_equals 2
      count_trailing_zeros 4
  expect_equals 0
      count_trailing_zeros 1
  expect_equals 64
      count_trailing_zeros 0
  expect_equals 0
      count_trailing_zeros -1
  expect_equals 1
      count_trailing_zeros -2
  expect_equals 16
      count_trailing_zeros 0x10000
  expect_equals 16
      count_trailing_zeros 0xac450000
  expect_equals 32
      count_trailing_zeros 0x100000000
  expect_equals 32
      count_trailing_zeros 0x8765432100000000
  expect_equals 63
      count_trailing_zeros int.MIN
