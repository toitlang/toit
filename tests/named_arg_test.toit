// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

no --no x:
  return 400 - x

main:
  // These two lines are parsed the same way:
  expect_equals 499 (no --no-99)
  expect_equals 499 (no --no -99)
