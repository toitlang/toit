// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

no --no x:
  return 400 - x

main:
  // These two lines are parsed the same way:
  expect_equals 499 (no --no-99)
  expect_equals 499 (no --no -99)
