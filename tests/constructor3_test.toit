// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

traces := []

trace msg:
  traces.add msg

class A:
  x := 0
  constructor:
    trace "in A"
    trace "x = $x"

class B extends A:
  constructor:
    x = 499

class C extends B:
  x= val:
    trace "in C"
    super = val

expect_list_equals list1 list2:
  expect_equals list1.size list2.size
  for i := 0; i < list1.size; i++:
    expect_equals list1[i] list2[i]

main:
  c := C
  trace "c.x = $(c.x)"

  expect_list_equals ["in A", "x = 0", "in C", "c.x = 499"] traces
