// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

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
