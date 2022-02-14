// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field / any
  constructor .field:

main:
  a := A 499
  expect_equals 499 a.field
