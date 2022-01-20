// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

other := 0
global_setter= x:
  other = x + 1

main:
  global_setter = 42
  expect_equals 43 other
