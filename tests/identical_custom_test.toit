// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect_equals "42" identical
  expect_equals 42 (identical 42)
  expect_equals 42 - 87 (identical 42 87)
  expect_equals 42 - 87 + 99 (identical 42 87 99)

identical:
  return "42"

identical x:
  return x

identical x y:
  return x - y

identical x y z:
  return x - y + z
