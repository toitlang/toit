// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

// https://github.com/toitware/toit/issues/38

main:
  print "$(%10d 1111222233334444)"
  expect_equals
    "  1111222233334444"
    "$(%18d 1111222233334444)"
  expect_equals
    "1"
    "$(%d 1)"
  expect_equals
    "abe"
    "$(%x 2750)"
  expect_equals
    "234"
    "$(%o 156)"
  expect_equals
    "234.0"
    "$(%.1f 234)"
