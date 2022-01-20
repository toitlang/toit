// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A:
  operator [..] --from --to:
    return from + to

class B:
  operator [..] --from=499 --to=42:
    return from + to

class C:
  operator [..] --from=499 --to:
    return from + to

class D:
  operator [..] --from --to=42:
    return from + to

main:
  a := A
  expect_equals 3 a[1..2]
  expect_equals -3 a[-1..-2]
  expect_equals 1.9 a[1.4...5]

  b := B
  expect_equals 3 b[1..2]
  expect_equals -3 b[-1..-2]
  expect_equals 1.9 b[1.4...5]
  expect_equals 499 b[..0]
  expect_equals 42 b[0..]
  expect_equals 42 + 499 b[..]

  c := C
  expect_equals 3 c[1..2]
  expect_equals -3 c[-1..-2]
  expect_equals 1.9 c[1.4...5]
  expect_equals 499 c[..0]

  d := D
  expect_equals 3 d[1..2]
  expect_equals -3 d[-1..-2]
  expect_equals 1.9 d[1.4...5]
  expect_equals 42 d[0..]
