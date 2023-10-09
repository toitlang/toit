// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

interface I1:
interface I2:
interface I3:
interface I4:

mixin M1 implements I1:
mixin M2 extends M1 implements I2:
mixin M3 implements I3:
mixin M4 extends M3 with M2 implements I4:

class A extends Object with M4:

expect-I1 o/I1:
expect-I2 o/I2:
expect-I3 o/I3:
expect-I4 o/I4:

confuse x -> any: return x

main:
  a := A
  expect-I1 a
  expect-I2 a
  expect-I3 a
  expect-I4 a

  expect a is I1
  expect a is I2
  expect a is I3
  expect a is I4

  expect (confuse a) is I1
  expect (confuse a) is I2
  expect (confuse a) is I3
  expect (confuse a) is I4
