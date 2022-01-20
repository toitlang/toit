// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  field1 ::= 42

class B extends A:
  field1b := 0
  field1= val:
    field1b = val

class C extends B:
  counter := 0
  field1:
    counter++
    return super + 1
  field1= val:
    counter++
    super = val + 1

class D extends C:
  counter2 := 0
  field1= val:
    counter2++
    super = val + 2

class E extends D:
  counter3 := 0
  field1:
    counter3++
    return super + 3

class F extends E:
  counter4 := 0
  field1:
    counter4++
    return super

class G extends F:
  field1= x:
    super += x

main:
  b := B
  b.field1 = 10
  expect_equals 10 b.field1b
  b.field1++
  expect_equals 43 b.field1b

  e := E
  e.field1++
  expect_equals 1 e.counter3
  expect_equals 1 e.counter2
  expect_equals 2 e.counter
  expect_equals 50 e.field1b
  expect_equals 46 e.field1

  g := G
  g.field1 = 13
  expect_equals 1 g.counter4
  expect_equals 1 g.counter3
  expect_equals 1 g.counter2
  expect_equals 2 g.counter
  expect_equals 62 g.field1b
  expect_equals 46 g.field1
