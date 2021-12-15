// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

class A:
  field := 0

  static foo:
    field := 499  // Allowed to shadow instance field.
    return field

  constructor:
    field := 42  // Allowed to shadow instance field.
    return A.named field

  constructor.named this.field:

main:
  expect_equals 499 A.foo
  expect_equals 42 (A).field
