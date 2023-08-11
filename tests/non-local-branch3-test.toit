// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo-count := 0

foo1 [b]:
  foo-count++
  b.call 0

foo2 x [--named]:
  foo-count++
  named.call 1

main:
  limit ::= 3
  for mode := 0; mode < 2; mode++:
    foo-count = 0
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
      expect-equals limit+1 foo-count
    else:
      expect-equals 2*(limit+1) foo-count
