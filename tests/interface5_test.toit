// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

interface A:
  static x ::= 1
  static y ::= 2

main:
  expect_equals 1 A.x
  expect_equals 2 A.y
