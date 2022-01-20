// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

global_value := 42
global --optional=499 -> any: return global_value
global= val: global_value = val

main:
  global += 499
  expect_equals 541 global_value

