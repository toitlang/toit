// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .static2_test as p

main:
  expect_equals 499 (p.A.foo 499)
  expect_equals 33 p.A.bar
  p.A.bar++
  expect_equals 34 p.A.bar
  p.A.bar += 2
  expect_equals 36 p.A.bar
