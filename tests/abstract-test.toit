// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class C0-0:
  foo:
    return 1

abstract class C0-1 extends C0-0:
  abstract foo

class C0-2 extends C0-1:
  foo:
    return super + 1

test0:
  c0-0 := C0-0
  c0-2 := C0-2

  expect-equals 1 c0-0.foo
  expect-equals 2 c0-2.foo

abstract class C1-0:
  abstract foo

class C1-1 extends C1-0:
  foo:
    return 499

test1:
  expect-equals 499 (C1-1).foo

abstract class C2-0:
  abstract operator < other
  abstract operator > other

class C2-1 extends C2-0:
  hit-lt := false
  operator < other:
    hit-lt = true
    return true

  hit-gt := false
  operator > other:
    hit-gt = true
    return false

test2:
  c2-1 := C2-1
  expect-equals true (c2-1 < 499)
  expect c2-1.hit-lt

  expect-equals false (c2-1 > 499)
  expect c2-1.hit-gt

main:
  test0
  test1
  test2
