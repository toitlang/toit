// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

class A:
  static foo x:
    return x

  static bar := 33

main:
  expect_equals 499 (A.foo 499)
  expect_equals 33 A.bar
  A.bar++
  expect_equals 34 A.bar
  A.bar += 2
  expect_equals 36 A.bar
