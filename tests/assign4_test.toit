// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

other := 42
counter := 0

global_accessor:
  counter++
  return other
global_accessor= x:
  counter++
  other = x + 1

main:
  expect_equals 42 other
  expect_equals 42 global_accessor
  expect_equals 1 counter
  expect_equals 42 global_accessor++
  expect_equals 44 other
  expect_equals 44 global_accessor
  expect_equals 4 counter
  global_accessor *= 2
  expect_equals 89 other
  expect_equals 89 global_accessor
  expect_equals 7 counter
