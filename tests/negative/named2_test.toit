// Copyright (C) 2019 Toitware ApS. All rights reserved.
// TEST_FLAGS: --force

import expect show *

counter := 0
side:
  return counter++

class A:
  bar gee=side --arg=side --expected:
    expect_equals expected gee + arg
    return gee

main:
  a := A
  a.bar 3
