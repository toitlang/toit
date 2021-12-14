// Copyright (C) 2020 Toitware ApS. All rights reserved.

import core as pre
import expect show *

foo x [block]:
  expect_equals 499 (block.call 1 null null)

foo x fun:
  expect_equals 499 (fun.call 1 null null)

bar: return 42

main:
  foo
      bar: |x/int
            y /
              string?
            z / pre.List?|
    499
  foo
      bar:: |x/int
             y /
               string?
             z / pre.List?|
    499
