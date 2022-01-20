// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  expect_equals 7 foo
  expect_equals 5 (foo 4)
  expect_equals 3 (foo 7 4)

  c := C
  expect_equals 7 c.bar
  expect_equals 5 (c.bar 4)
  expect_equals 3 (c.bar 7 4)

foo:
  return 7
foo n:
  return n + 1
foo x y:
  return x - y

class C:
  bar:
    return 7
  bar n:
    return n + 1
  bar x y:
    return x - y
