// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

foo [block]: return block.call

foo [--block]: return block.call

main:
  expect_equals 499 (foo: 499)
  expect_equals 499 (foo --block=: 499)
