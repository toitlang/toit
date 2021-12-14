// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

class A:
  field / any
  constructor .field:

main:
  a := A 499
  expect_equals 499 a.field
