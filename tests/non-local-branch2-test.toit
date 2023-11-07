// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo-count := 0

foo1 [b]:
  foo-count++
  b.call

foo2 x [b]:
  foo-count++
  b.call

foo3 [b] [b2]:
  foo-count++
  b.call

foo4 [b] [b2]:
  foo-count++
  b2.call

foo5 [--named]:
  foo-count++
  named.call

foo6 x [--named]:
  foo-count++
  named.call

main:
  for mode := 1; mode <= 7; mode++:
    foo-count = 0
    before-count := 0
    after-count := 0
    finally-count := 0
    expected-finally-count := 0

    for i := 0; i < 5; i++:
      expect-equals i foo-count
      expect-equals i before-count
      expect-equals 0 after-count
      expect-equals expected-finally-count finally-count

      before-count++

      limit := 3
      block :=
        : if i < limit:
            continue
          else:
            break
      if mode == 1:
        foo1 block
      else if mode == 2:
        foo2 499 block
      else if mode == 3:
        foo3 block: null
      else if mode == 4:
        foo4 (: null) block
      else if mode == 5:
        foo5 --named=block
      else if mode == 6:
        foo6 499 --named=block
      else:
        expected-finally-count++
        try:
          foo6 499 --named=:
            if i < limit:
              continue
            else:
              break
        finally:
          finally-count++
      after-count++
    expect-equals 0 after-count
    expect-equals 4 before-count
    expect-equals expected-finally-count finally-count

