// Copyright (C) 2019 Toitware ApS. All rights reserved.

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
