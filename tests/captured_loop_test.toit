// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  funs := []

  for i := 0; i < 3; i++:
    funs.add (:: i)
  3.repeat:
    expect_equals it funs[it].call

  funs = []
  for i := 0; i < 6; i++:
    funs.add (:: i)
    i++
  3.repeat:
    expect_equals (2 * it + 1) funs[it].call
