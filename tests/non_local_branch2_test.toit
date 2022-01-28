// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo_count := 0

foo1 [b]:
  foo_count++
  b.call

foo2 x [b]:
  foo_count++
  b.call

foo3 [b] [b2]:
  foo_count++
  b.call

foo4 [b] [b2]:
  foo_count++
  b2.call

foo5 [--named]:
  foo_count++
  named.call

foo6 x [--named]:
  foo_count++
  named.call

main:
  for mode := 1; mode <= 7; mode++:
    foo_count = 0
    before_count := 0
    after_count := 0
    finally_count := 0
    expected_finally_count := 0

    for i := 0; i < 5; i++:
      expect_equals i foo_count
      expect_equals i before_count
      expect_equals 0 after_count
      expect_equals expected_finally_count finally_count

      before_count++

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
        expected_finally_count++
        try:
          foo6 499 --named=:
            if i < limit:
              continue
            else:
              break
        finally:
          finally_count++
      after_count++
    expect_equals 0 after_count
    expect_equals 4 before_count
    expect_equals expected_finally_count finally_count

