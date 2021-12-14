// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

global_value := 42
global --optional=499 -> any: return global_value
global= val: global_value = val

main:
  global += 499
  expect_equals 541 global_value

