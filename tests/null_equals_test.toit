// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  operator == other:
    expect other != null
    return true

main:
  a := A
  expect_equals false (a == null)
  expect_equals false (null == a)
  expect a == a
