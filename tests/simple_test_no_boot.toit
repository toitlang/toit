// Copyright (C) 2020 Toitware ApS. All rights reserved.

import expect show *

foo x: return x

main:
  // Main purpose of this test is to make sure that we still run
  // when no boot snapshot-bundle is present.
  expect_equals 499 (foo 499)
