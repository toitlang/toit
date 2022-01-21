// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  x := 0

  x = true ? 3 : 4
  expect_equals 3 x
  x = false ? 3 : 4
  expect_equals 4 x
