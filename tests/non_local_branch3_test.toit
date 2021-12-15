// Copyright (C) 2018 Toitware ApS. All rights reserved.

import expect show *

foo_count := 0

foo1 [b]:
  foo_count++
  b.call 0

foo2 x [--named]:
  foo_count++
  named.call 1

main:
  limit ::= 3
  for mode := 0; mode < 2; mode++:
    foo_count = 0
    for i := 0; i < 5; i++:
      block :=:
        // Depending on the mode we use the first call or not.
        if it == mode:
          if i < limit:
            continue
          else:
            break
      for j := 0; j < 1; j++:
        foo1 block
        foo2 1 --named=block
        throw "UNREACHABLE"
    if mode == 0:
      expect_equals limit+1 foo_count
    else:
      expect_equals 2*(limit+1) foo_count
