// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .prefixed_assign as prefix

main:
  prefix.x = 3
  expect_equals 3 prefix.x
  prefix.x++
  expect_equals 4 prefix.x
  prefix.x += 2
  expect_equals 6 prefix.x
