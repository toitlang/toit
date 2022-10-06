// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x=499 [block] :
  return x + block.call

bar x=1 y=2 [block1] [block2]:
  return x + y + block1.call + block2.call

func [b]:
  return b.call 489

gee x y=(func: it + 1) [block]:
  return x + y + block.call

class A:
  x := 0
  y := 0
  z := 0
  constructor .x=[1, 2, 3] .y=x.size [block]:
    z = block.call

  static foo x=499 [block]:
    return x + block.call

  bar x=42 [block]:
    return x + block.call

class B extends A:
  constructor:
    super: 9
  bar:
    return (super: 5) + 1

class C:
  foo:
    return 499

  bar x=foo [block]:
    return x + block.call

class D:
  unique_method_name x=400 y=99 [block]:
    return x + y + block.call

  some_method x:
    return x

  non_unique:
    // Regression Test:
    // The unique_method_name is only used as argument in a virtual call.
    // The first iteration of the collector that finds all call-selectors didn't
    //   go into virtual methods (but only collected the outermost call-selector).
    return this.some_method (unique_method_name: 22)

main:
  expect_equals 501 (foo: 2)
  expect_equals 19 (bar (:7) (:9))
  expect_equals 498 (gee 9 (:-1))

  a1 := A [1, 2] :99
  expect_equals 2 a1.y
  expect_equals 1 a1.x[0]
  expect_equals 2 a1.x[1]
  expect_equals 99 a1.z

  expect_equals 498 (A.foo: -1)

  b := B
  expect_equals 3 b.x.size
  expect_equals 3 b.y
  expect_equals 9 b.z

  expect_equals 49 (b.bar: 7)
  expect_equals 48 b.bar

  expect_equals 496 ((C).bar: -3)

  a2 := A: 22
  expect_equals 45 (a2.bar: 3)

  d := D
  expect_equals 521 d.non_unique
