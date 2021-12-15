// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

use x:
  // Do nothing.

trace := []
class A:
  x := 0
  constructor:
    trace.add "in A"

class B extends A:
  constructor:
    trace.add "in B"

class C
  extends B:

class D
  extends B
  implements I1
    I2
    I3:
  foo:

interface
  I1:
interface I2:
interface I3
 implements I2:

monitor
  X:

main:
  b := B
  expect_list_equals ["in B", "in A"] trace
  trace = []
  c := C
  expect_list_equals ["in B", "in A"] trace
  trace = []
  d := D
  expect_list_equals ["in B", "in A"] trace
  trace = []
  x := X
