// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import .valid-assignment-test as pre

class A:
  field := null

  constructor:
    x := 42
    x = x = 499
    expect-equals 499 x

class B extends A:
  field= val:
    x := null
    super = x = 499
    expect-equals 499 field
    expect-equals 499 x

global := null

main:
  a := A
  x := null
  y := null
  x = y = 499
  expect-equals 499 x
  expect-equals 499 y

  pre.global = x = 42
  expect-equals 42 global

  a.field = x = 42
  expect-equals 42 a.field

  pre.A.field = x = 499
  expect-equals 499 x

  global = a
  pre.global.field = x = 11
  expect-equals 11 x
  expect-equals 11 a.field

  list := [0]
  list[0] = x = 99
  expect-equals 99 list[0]
  expect-equals 99 x

  counter := 0
  for x = 0; x < 2; x = y:
    y = x + 1
    counter++
  expect-equals 2 counter

