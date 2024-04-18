// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

expect-throws name [code]:
  expect-equals
    name
    catch code

// Out-of-bounds with large strings leads to segfault #294
main:
  long := "foo" * 1000
  expect-throws "OUT_OF_BOUNDS":
    long[long.size]
