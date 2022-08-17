// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_clz
  test_ctz
  test_popcount

test_clz:
  expect_equals 0
      (-1).count_leading_zeros
  expect_equals 64
      (0).count_leading_zeros
  expect_equals 55
      (0x100).count_leading_zeros
  expect_equals 23
      (0x100_0000_0000).count_leading_zeros
  expect_equals 0
      int.MIN.count_leading_zeros
  expect_equals 1
      int.MAX.count_leading_zeros

test_ctz:
  expect_equals 2
      (4).count_trailing_zeros
  expect_equals 0
      (1).count_trailing_zeros
  expect_equals 64
      (0).count_trailing_zeros
  expect_equals 0
      (-1).count_trailing_zeros
  expect_equals 1
      (-2).count_trailing_zeros
  expect_equals 16
      (0x10000).count_trailing_zeros
  expect_equals 16
      (0xac450000).count_trailing_zeros
  expect_equals 32
      (0x100000000).count_trailing_zeros
  expect_equals 32
      (0x8765432100000000).count_trailing_zeros
  expect_equals 63
      int.MIN.count_trailing_zeros
  expect_equals 0
      int.MAX.count_trailing_zeros

test_popcount:
  expect_equals 1
      (4).population_count
  expect_equals 1
      (1).population_count
  expect_equals 0
      (0).population_count
  expect_equals 64
      (-1).population_count
  expect_equals 63
      (-2).population_count
  expect_equals 1
      (0x10000).population_count
  expect_equals 7
      (0xac450000).population_count
  expect_equals 1
      (0x100000000).population_count
  expect_equals 13
      (0x8765432100000000).population_count
  expect_equals 1
      int.MIN.population_count
  expect_equals 63
      int.MAX.population_count
