// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

side-count := 0
side x:
  side-count++
  return x

class A:
  f := 1
  foo x:
    return x + 1

class B extends A:
  static f := side 42
  static foo x:
    return x

  bar:
    return f

  gee x:
    return foo x

class C extends B:

main:
  a := A
  b := B
  c := C

  expect-equals 1 a.f
  expect-equals 1 b.f
  expect-equals 1 c.f

  expect-equals 3 (a.foo 2)
  expect-equals 3 (b.foo 2)
  expect-equals 3 (c.foo 2)

  expect-equals 0 side-count
  expect-equals 42 b.bar
  expect-equals 1 side-count
  expect-equals 42 b.bar
  expect-equals 1 side-count
  expect-equals 499 (b.gee 499)
