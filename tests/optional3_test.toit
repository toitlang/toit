// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo --named=400 unnamed:
  return named + unnamed

main:
  expect_equals 499 (foo 99)
