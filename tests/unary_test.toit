// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect (-1) < 0     --message="unary #0"
  expect (-0) == 0    --message="unary #1"
  expect -1 < 0       --message="unary #2"
  expect -0 == 0      --message="unary #3"

  n := 1
  expect (-n) < 0     --message="unary #4"
  expect (-(-n)) == 1 --message="unary #5"
  expect -n < 0       --message="unary #6"
  expect -(-n) == 1   --message="unary #7"

  // The unary minus binds to literal numbers.
  expect_equals 4 -4.abs
  // It doesn't bind to identifiers.
  expect_equals -1 -n.abs
