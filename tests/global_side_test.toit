// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

side_counter := 0

side:
  side_counter++

global := side

main:
  global  // A reference to a global.
  expect_equals 1 side_counter
