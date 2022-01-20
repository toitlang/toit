// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test_min_and_max

test_min_and_max:
  NAN := 0.0/0.0
  expect_equals 0 (min 2 0)
  expect_equals 1 (min 1 2)
  expect_equals 2 (min 2 2)
  expect_identical -0.0 (min -0.0 0.0)
  expect_identical -0.0 (min 0.0 -0.0)
  expect_identical NAN (min -10 NAN)
  expect_identical NAN (min -10.0 NAN)
  expect_identical NAN (min NAN -10)
  expect_identical NAN (min NAN -10.0)

  expect_equals 2 (max 1 2)
  expect_equals 2 (max 2 0)
  expect_equals 2 (max 2 2)
  expect_identical 0.0 (max -0.0 0.0)
  expect_identical 0.0 (max 0.0 -0.0)
  expect_identical NAN (max 10 NAN)
  expect_identical NAN (max 10.0 NAN)
  expect_identical NAN (max NAN 10)
  expect_identical NAN (max NAN 10.0)
