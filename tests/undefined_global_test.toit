// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

global := ?

main:
  global = 499
  expect_equals 499 global
