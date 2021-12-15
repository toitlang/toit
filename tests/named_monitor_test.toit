// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

monitor MyMonitor:
  foo --named:
    return named

main:
  m := MyMonitor
  expect_equals 5
    m.foo --named=5
  expect_equals 7
    m.foo --named=7
