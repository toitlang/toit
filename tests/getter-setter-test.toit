// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

global-value := 42
global --optional=499 -> any: return global-value
global= val: global-value = val

main:
  global += 499
  expect-equals 541 global-value

