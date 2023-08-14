// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  bar := 499

class B extends A:
  bar= x:
    super = 22

  field := 42
  counter := 0
  gee:
    counter++
    return field
  gee= val:
    counter++
    field = val

class C extends B:
  gee: return super
  gee= val: super = val + 1

class D extends B:
  gee: return super
  gee= val:
    super = (super * val)

main:
  b := B
  b.bar = 42
  expect-equals 22 b.bar

  c := C
  expect-equals 0 c.counter
  expect-equals 42 c.field
  expect-equals 42 c.gee
  expect-equals 1 c.counter
  c.gee++
  expect-equals 3 c.counter
  expect-equals 44 c.field
  expect-equals 44 c.gee
  expect-equals 4 c.counter

  d := D
  expect-equals 0 d.counter
  expect-equals 42 d.field
  expect-equals 42 d.gee
  expect-equals 1 d.counter
  d.gee++
  expect-equals 4 d.counter
  expect-equals (42 * 43) d.field
  expect-equals (42 * 43) d.gee
  expect-equals 5 d.counter
