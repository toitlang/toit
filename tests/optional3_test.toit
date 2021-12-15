// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

foo --named=400 unnamed:
  return named + unnamed

main:
  expect_equals 499 (foo 99)
