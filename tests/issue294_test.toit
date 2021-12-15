// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

expect_throws name [code]:
  expect_equals
    name
    catch code

// Out-of-bounds with large strings leads to segfault #294
main:
  long := "foo" * 1000
  expect_throws "OUT_OF_BOUNDS":
    long[long.size]
