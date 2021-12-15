// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

import .import4_a show foo
import .import4_b  // Not showing 'foo'

main:
  expect_equals "a" foo
