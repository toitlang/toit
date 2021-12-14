// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  test_toplevel
  test_split

test_toplevel:
  expect_equals
    7
    3 + 4
  expect_equals
    7
    // Second:
    3 + 4
  expect_equals
    // First:
    7
    // Second:
    3 + 4
  expect_equals
    // First:
    7

    // Second:
    3 + 4

test_split:
  expect_equals 7
    3 + 4
