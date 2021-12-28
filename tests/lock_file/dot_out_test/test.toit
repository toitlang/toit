// Copyright (C) 2021 Toitware ApS. All rights reserved.

import expect show *

import ..dot_out_test.test as pre

foo: return "OK"

main:
  expect_equals "OK" pre.foo
