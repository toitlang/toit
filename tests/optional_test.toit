// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x=499:
  return x

bar x=1 y=2:
  return x + y

fun [b]:
  return b.call 489

gee x y=(fun: it + 1):
  return x + y

class A:
  x := 0
  y := 0
  constructor .x=[1, 2, 3] .y=x.size:

  static foo x=499:
    return x

  bar x=42:
    return x

class B extends A:
  // Note that there is an implicit call to the super-constructor.

  bar:
    return super + 1

class C:
  foo:
    return 499

  bar x=foo:
    return x

class D:
  unique_method_name x=400 y=99:
    return x + y

  some_method x:
    return x

  non_unique:
    // Regression Test:
    // The unique_method_name is only used as argument in a virtual call.
    // The first iteration of the collector that finds all call-selectors didn't
    //   go into virtual methods (but only collected the outermost call-selector).
    return this.some_method unique_method_name

main:
  expect_equals 499 foo
  expect_equals 3 bar
  expect_equals 499 (gee 9)

  a1 := A [1, 2]
  expect_equals 2 a1.y
  expect_equals 1 a1.x[0]
  expect_equals 2 a1.x[1]

  expect_equals 499 A.foo

  b := B
  expect_equals 3 b.x.size
  expect_equals 3 b.y
  expect_equals 43 b.bar

  expect_equals 499 (C).bar

  a2 := A
  expect_equals 42 a2.bar

  d := D
  expect_equals 499 d.non_unique
