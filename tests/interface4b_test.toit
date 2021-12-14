// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

interface A:
  constructor:
    return B

  constructor.named:
    return B

  x -> any

class B implements A:
  x := 0

main:
  expect_equals 0 (A).x
  expect_equals 0 A.named.x
