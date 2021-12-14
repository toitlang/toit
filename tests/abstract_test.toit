// Copyright (C) 2019 Toitware ApS. All rights reserved.

import expect show *

class C0_0:
  foo:
    return 1

abstract class C0_1 extends C0_0:
  abstract foo

class C0_2 extends C0_1:
  foo:
    return super + 1

test0:
  c0_0 := C0_0
  c0_2 := C0_2

  expect_equals 1 c0_0.foo
  expect_equals 2 c0_2.foo

abstract class C1_0:
  abstract foo

class C1_1 extends C1_0:
  foo:
    return 499

test1:
  expect_equals 499 (C1_1).foo

abstract class C2_0:
  abstract operator < other

class C2_1 extends C2_0:
  operator < other:
    return 42

test2:
  expect_equals 42 (C2_1 < 499)

main:
  test0
  test1
  test2
