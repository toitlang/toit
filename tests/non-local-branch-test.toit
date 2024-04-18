// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

bar [b]:
  i := 0
  b.call i

finally-count := 0

foo [b]:
  try:
    b.call
    print "in foo"
  finally:
    finally-count++

main:
  before-count := 0
  after-count := 0
  for i := 0; i < 5; i++:
    expect-equals i before-count
    expect-equals i finally-count

    before-count++
    bar:
      limit := 3
      foo:
        if i < limit:
          continue
        else:
          break
    after-count++
  expect-equals 0 after-count
  expect-equals 4 before-count
  expect-equals 4 finally-count
  print "done"
