// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo a b [c] [d]:
  return (a.call 1000)
   + (b.call 100)
   + (c.call 10)
   + (d.call 1)

unless_ b [bl]:
  if not b: return bl.call
  return null

main:
  x := foo
    :: it * 1
    :: it * 2
    : it * 3
    : it * 4
  expect_equals 1234 x

  unless_ 4 * 6 == 0: print 499

  gee bar: 12

gee x [b]:

bar:
  return 499
