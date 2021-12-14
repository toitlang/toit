// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

interface A:
  constructor:
    return B

  constructor.named:
    return B

class B implements A:
  x := 0

main:
  expect_equals 0 (A as B).x
  expect_equals 0 (A.named as B).x
