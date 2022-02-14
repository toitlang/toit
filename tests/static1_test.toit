// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

side_count := 0
side x:
  side_count++
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

  expect_equals 1 a.f
  expect_equals 1 b.f
  expect_equals 1 c.f

  expect_equals 3 (a.foo 2)
  expect_equals 3 (b.foo 2)
  expect_equals 3 (c.foo 2)

  expect_equals 0 side_count
  expect_equals 42 b.bar
  expect_equals 1 side_count
  expect_equals 42 b.bar
  expect_equals 1 side_count
  expect_equals 499 (b.gee 499)
