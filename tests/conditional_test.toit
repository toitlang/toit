// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

main:
  x := 0

  x = true ? 3 : 4
  expect_equals 3 x
  x = false ? 3 : 4
  expect_equals 4 x
