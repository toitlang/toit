// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

foo -> int:
  while confuse true:
    return 499
  unreachable

confuse x -> any: return x

main:
  expect_equals 499 foo
