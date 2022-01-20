// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo -> int:
  while confuse true:
    return 499
  unreachable

confuse x -> any: return x

main:
  expect_equals 499 foo
