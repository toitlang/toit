// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class List:
  foo:
    return "foo"
main:
  a := List
  expect_equals "foo" a.foo

  a2 := []
  expect_equals 0 a2.size
