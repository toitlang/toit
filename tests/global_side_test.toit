// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

side_counter := 0

side:
  return side_counter++

global := side

main:
  global  // A reference to a global.
  expect_equals 1 side_counter
