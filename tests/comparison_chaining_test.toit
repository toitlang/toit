// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

count := 0

side x:
  count++
  return x

check_side_count expected_side_calls [b]:
  before := count
  b.call
  expect_equals expected_side_calls (count - before)

run [b]:
  return b.call

main:
  x := 1 < 2 < 3 < 4
  expect_equals true x

  x =
    if 3 > 2 < 4: true else: false
  expect_equals true x

  check_side_count 4:
    expect_equals true ((side 1) < (side 2) < (side 3) < (side 4))

  check_side_count 1:
    x = run: 1 < (side 2) > 3 ? "no!" : "ok"
  expect_equals "ok" x

  check_side_count 1:
    x = run: 1 <= (side 2) >= 3 ? "no!" : "ok"
  expect_equals "ok" x

  b := true
  expect_equals true (b == 1 < 2)
  expect_equals false (b == 2 < 1)
  expect_equals true (1 < 2 == b)
  expect_equals false (2 < 1 == b)
  expect_equals false (b != 1 < 2)
  expect_equals true (b != 2 < 1)
  expect_equals false (1 < 2 != b)
  expect_equals true (2 < 1 != b)
