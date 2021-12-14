// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

interface A:
  static x ::= 1
  static y ::= 2

main:
  expect_equals 1 A.x
  expect_equals 2 A.y
