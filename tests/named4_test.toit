// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

counter := 0
side:
  counter++
  return counter

class A:
  bar gee=side --arg=side --expected:
    expect_equals expected gee + arg
    return gee

main:
  a := A
  expect_equals 1
      a.bar --expected=3
