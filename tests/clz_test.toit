// Copyright (C) 2021 Toitware ApS. All rights reserved.

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
