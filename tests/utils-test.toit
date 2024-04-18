// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-min-and-max

test-min-and-max:
  NAN := 0.0/0.0
  expect-equals 0 (min 2 0)
  expect-equals 1 (min 1 2)
  expect-equals 2 (min 2 2)
  expect-identical -0.0 (min -0.0 0.0)
  expect-identical -0.0 (min 0.0 -0.0)
  expect-identical NAN (min -10 NAN)
  expect-identical NAN (min -10.0 NAN)
  expect-identical NAN (min NAN -10)
  expect-identical NAN (min NAN -10.0)

  expect-equals 2 (max 1 2)
  expect-equals 2 (max 2 0)
  expect-equals 2 (max 2 2)
  expect-identical 0.0 (max -0.0 0.0)
  expect-identical 0.0 (max 0.0 -0.0)
  expect-identical NAN (max 10 NAN)
  expect-identical NAN (max 10.0 NAN)
  expect-identical NAN (max NAN 10)
  expect-identical NAN (max NAN 10.0)
