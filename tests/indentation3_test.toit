// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  x := {
    1: 2
  , 3: 4
  , 5: 6
  }
  expect_equals 4 x[3]

  x = {
    1: 2
   , 3: 4
  , 5: 6
  }
  expect_equals 4 x[3]

  y := {
    1
  , 2
  , 3
  , 4
  }
  expect_equals 4 y.size

  y = {
    1
   , 2
    , 3
  , 4
  }
  expect_equals 4 y.size
