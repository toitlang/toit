// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .import3_a

foo:
  return "main"

main:
  expect_equals "main" foo
