// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo --flag --flag2 --named:
  if named == 1: return flag
  return flag2

main:
  expect_equals true
      foo --flag --flag2 --named=1
  expect_equals false
      foo --no-flag --flag2 --named=1
  expect_equals true
      foo --flag --flag2 --named=2
  expect_equals false
      foo --no-flag --no-flag2 --named=2
