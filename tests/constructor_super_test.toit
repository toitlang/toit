// Copyright (C) 2018 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

blocked [f]:
  f.call

class A0:
  f := 0

  constructor:

  constructor x:
    super

class A1:
  f := 0

  constructor this.f:

  constructor this.f x:
    super

class A2:
  f := 0

  constructor:
    f = 499

  constructor x:
    this.f = 499

  constructor x y:
    super
    this.f = 499

  constructor x y z:
    this.f = 499
    super

  constructor x y z t:
    f = 499
    super

class A3:
  f := 0

  constructor:
    if 1 == 1:
      f = 499

  constructor x:
    if 1 == 1:
      this.f = 499

  constructor x y:
    super
    if 1 == 1:
      this.f = 499

  constructor x y z:
    if 1 == 1:
      this.f = 499
    super

  constructor x y z t:
    if 1 == 1:
      f = 499
    super

class A4:
  f := 0

  constructor:
    if 1 == 1:
      f = 499

  constructor x:
    if 1 == 1:
      this.f = 499

  constructor x y:
    super
    if 1 == 1:
      this.f = 499

  constructor x y z:
    if 1 == 1:
      this.f = 499
    super

  constructor x y z t:
    if 1 == 1:
      f = 499
    super

class A5:
  f := 0

  constructor:
    if 1 == 1:
      blocked: f = 499

  constructor x:
    if 1 == 1:
      blocked: this.f = 499

  constructor x y:
    super
    if 1 == 1:
      blocked: this.f = 499

  constructor x y z:
    if 1 == 1:
      blocked: this.f = 499
    super

  constructor x y z t:
    if 1 == 1:
      blocked: f = 499
    super

class B:
  f := 0

  constructor:
    if 1 == 1:
      blocked: f = 499

  constructor x:
    if 1 == 1:
      blocked: this.f = 499

  constructor x y:
    super
    if 1 == 1:
      blocked: this.f = 499

  constructor x y z:
    if 1 == 1:
      blocked: this.f = 499
    super

  constructor x y z t:
    if 1 == 1:
      blocked: f = 499
    super

class B2 extends B:
  was_called := false

  constructor:

  constructor x:
    super x

  constructor x y:
    super x y

  constructor x y z:
    super x y z

  constructor x y z t:
    super x y z t

  f x:
    was_called = true

class C:
  f ::= 0
  f2 ::= 0
  f3 ::= 0

  constructor this.f arg:
    this.f2 = arg
    arg = 3
    f3 = arg

class D:
  f := null
  f2 := null
  f3 := null
  f4 := null

  constructor:
    f = 498
    this.f2 = 498
    f++
    this.f2++
    f3 = 498
    this.f4 = 498
    f3 = (f3 + 1)
    this.f4 = (this.f4 + 1)

  constructor x:
    super
    f = 498
    this.f2 = 499
    f++
    if f == f2: f = f2
    f3 = 498
    this.f4 = 498
    f3 = (f3 + 1)
    this.f4 = (this.f4 + 1)

  constructor x y:
    f = 498
    this.f2 = 498
    f++
    f2++
    f3 = 498
    this.f4 = 498
    f3 = (f3 + 1)
    this.f4 = (this.f4 + 1)
    super

class D2 extends D:
  was_called := false

  constructor:
    super

  constructor x:
    super x

  constructor x y:
    super x y

  f x:
    was_called = true

  f2 x:
    was_called = true

class E:
  f := ?

  constructor:
    f = (::499)


collected := []

side x:
  collected.add x
  return x

exec [block]: return block.call

class F:
  f1 := side 0

class F2 extends F:
  f2 := side 2
  f3 := side 3

  instance:
    side f2
    side f3

  instance x:
    side f2
    side f3

  constructor:
    f2 = side 497
    f2 = (side (f2 + 1))
    this.f2 = (side (this.f2 + 1))

  constructor x:
    super
    f2 = side 497
    f2 = (side (f2 + 1))
    this.f2 = (side (this.f2 + 1))

  constructor x y:
    instance
    f2 = side 497
    f2 = (side (f2 + 1))
    this.f2 = (side (this.f2 + 1))

  constructor x y z:
    f2 = side 497
    f2 = (side (f2 + 1))
    this.f2 = (side (this.f2 + 1))
    instance
    f3 = side 497
    f3 = (side (f3 + 1))
    this.f3 = (side (this.f3 + 1))

  constructor x y z t:
    f2 = side 497
    f2 = (side (f2 + 1))
    instance (exec: this.f2 = (side (this.f2 + 1)))

class G:
  f := 0
  f2 := -1
  f3 := -1

  constructor:
    f2 = f++
    this.f3 = this.f++

expect_list_equals l1 l2:
  expect_equals l1.size l2.size
  for i := 0; i < l1.size; i++:
    expect_equals l1[i] l2[i]

main:
  a := null

  a = A0
  expect_equals 0 a.f
  a = A0 0
  expect_equals 0 a.f

  a = A1 499
  expect_equals 499 a.f
  a = A1 499 0
  expect_equals 499 a.f

  a = A2
  expect_equals 499 a.f
  a = A2 1
  expect_equals 499 a.f
  a = A2 1 2
  expect_equals 499 a.f
  a = A2 1 2 3
  expect_equals 499 a.f
  a = A2 1 2 3 4
  expect_equals 499 a.f

  a = A3
  expect_equals 499 a.f
  a = A3 1
  expect_equals 499 a.f
  a = A3 1 2
  expect_equals 499 a.f
  a = A3 1 2 3
  expect_equals 499 a.f
  a = A3 1 2 3 4
  expect_equals 499 a.f

  a = A4
  expect_equals 499 a.f
  a = A4 1
  expect_equals 499 a.f
  a = A4 1 2
  expect_equals 499 a.f
  a = A4 1 2 3
  expect_equals 499 a.f
  a = A4 1 2 3 4
  expect_equals 499 a.f

  a = A5
  expect_equals 499 a.f
  a = A5 1
  expect_equals 499 a.f
  a = A5 1 2
  expect_equals 499 a.f
  a = A5 1 2 3
  expect_equals 499 a.f
  a = A5 1 2 3 4
  expect_equals 499 a.f

  b := B2
  expect_equals b.f 499
  expect_equals false b.was_called
  b = B2 1
  expect_equals b.f 499
  expect_equals false b.was_called
  b = B2 1 2
  expect_equals b.f 499
  expect_equals false b.was_called
  b = B2 1 2 3
  expect_equals b.f 499
  expect_equals false b.was_called
  b = B2 1 2 3 4
  expect_equals b.f 499
  expect_equals false b.was_called

  c := C 1 2
  expect_equals 1 c.f
  expect_equals 2 c.f2
  expect_equals 3 c.f3

  d := D2
  expect_equals 499 d.f
  expect_equals 499 d.f2
  expect_equals false d.was_called
  d = D2 1
  expect_equals 499 d.f
  expect_equals 499 d.f2
  expect_equals false d.was_called
  d = D2 1 2
  expect_equals 499 d.f
  expect_equals 499 d.f2
  expect_equals false d.was_called

  expect_equals 499 (E).f.call

  f := F2
  expect_equals 499 f.f2
  expect_list_equals [2, 3, 497, 498, 499, 0] collected
  collected = []

  f = F2 1
  expect_equals 499 f.f2
  expect_list_equals [2, 3, 0, 497, 498, 499] collected
  collected = []

  f = F2 1 2
  expect_equals 499 f.f2
  expect_list_equals [2, 3, 0, 2, 3, 497, 498, 499] collected
  collected = []

  f = F2 1 2 3
  expect_equals 499 f.f2
  expect_equals 499 f.f3
  expect_list_equals [2, 3, 497, 498, 499, 0, 499, 3, 497, 498, 499] collected
  collected = []

  f = F2 1 2 3 4
  expect_equals 499 f.f2
  expect_list_equals [2, 3, 497, 498, 0, 499, 499, 3] collected
  collected = []

  g := G
  expect_equals 2 g.f
  expect_equals 0 g.f2
  expect_equals 1 g.f3
