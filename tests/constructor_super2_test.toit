// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

class A0:
  x ::= 0
  constructor.named:
    x = 499

  constructor.named x:
    this.x = x

  constructor.named [b]:
    this.x = b.call

  constructor.foo:
    // Does not clash with static `foo`, because of different arity.
    // TODO(florian): disallow this?
    this.x = 0

class A1 extends A0:
  constructor:
    super.named

  constructor x:
    super.named x

  constructor [b]:
    super.named b

  constructor.foo:
    super.foo

main:
  expect_equals 499 (A1).x
  expect_equals 42 (A1 42).x
  expect_equals 314 (A1: 314).x

  expect_equals 0 A1.foo.x
