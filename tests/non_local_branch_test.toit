// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

bar [b]:
  i := 0
  b.call i

finally_count := 0

foo [b]:
  try:
    b.call
    print "in foo"
  finally:
    finally_count++

main:
  before_count := 0
  after_count := 0
  for i := 0; i < 5; i++:
    expect_equals i before_count
    expect_equals i finally_count

    before_count++
    bar:
      limit := 3
      foo:
        if i < limit:
          continue
        else:
          break
    after_count++
  expect_equals 0 after_count
  expect_equals 4 before_count
  expect_equals 4 finally_count
  print "done"
