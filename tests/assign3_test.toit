// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

other := 0
global_setter= x:
  other = x + 1

main:
  global_setter = 42
  expect_equals 43 other
