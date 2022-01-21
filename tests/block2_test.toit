// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo [block]: return block.call

foo [--block]: return block.call

main:
  expect_equals 499 (foo: 499)
  expect_equals 499 (foo --block=: 499)
