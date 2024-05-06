// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x=499 [block] :
  return x + block.call

bar x=1 y=2 [block1] [block2]:
  return x + y + block1.call + block2.call

fun [b]:
  return b.call 489

gee x y=(fun: it + 1) [block]:
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
  unique-method-name x=400 y=99 [block]:
    return x + y + block.call

  some-method x:
    return x

  non-unique:
    // Regression Test:
    // The unique_method_name is only used as argument in a virtual call.
    // The first iteration of the collector that finds all call-selectors didn't
    //   go into virtual methods (but only collected the outermost call-selector).
    return this.some-method (unique-method-name: 22)

main:
  expect-equals 501 (foo: 2)
  expect-equals 19 (bar (:7) (:9))
  expect-equals 498 (gee 9 (:-1))

  a1 := A [1, 2] :99
  expect-equals 2 a1.y
  expect-equals 1 a1.x[0]
  expect-equals 2 a1.x[1]
  expect-equals 99 a1.z

  expect-equals 498 (A.foo: -1)

  b := B
  expect-equals 3 b.x.size
  expect-equals 3 b.y
  expect-equals 9 b.z

  expect-equals 49 (b.bar: 7)
  expect-equals 48 b.bar

  expect-equals 496 ((C).bar: -3)

  a2 := A: 22
  expect-equals 45 (a2.bar: 3)

  d := D
  expect-equals 521 d.non-unique
