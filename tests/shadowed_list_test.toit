// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

class List:
  foo:
    return "foo"
main:
  a := List
  expect_equals "foo" a.foo

  a2 := []
  expect_equals 0 a2.size
