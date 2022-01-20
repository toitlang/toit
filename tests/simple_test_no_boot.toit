// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x: return x

main:
  // Main purpose of this test is to make sure that we still run
  // when no boot snapshot-bundle is present.
  expect_equals 499 (foo 499)
