// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
