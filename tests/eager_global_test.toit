// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that eager globals aren't going through the lazy getter.

This test is used by the optimization test (of the same name).
*/

import expect show *

eager_global := 499

counter := 0
side x:
  counter++
  return x
lazy_global := side 42

eager_test:
  return eager_global

lazy_test:
  return lazy_global

main:
  expect_equals 499 eager_test
  expect_equals 42 lazy_test
  eager_global++
  lazy_global++
  expect_equals 500 eager_test
  expect_equals 43 lazy_test
  expect_equals 1 counter
