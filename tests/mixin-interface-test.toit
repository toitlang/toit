// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

interface I1:
interface I2:
interface I3:
interface I4:
interface I5:

mixin MixA implements I1:
  a-method: return 41

mixin MixB extends MixA implements I2:
  b-method: return 42

mixin MixC implements I3:
  c-method: return 43

mixin MixD extends MixB with MixC implements I4:
  d-method: return 44

mixin MixE implements I5:
  e-method: return 45

class ClassA extends Object with MixD MixE:

class ClassB extends Object with MixD:

confuse x -> any: return x

main:
  a := ClassA
  b := ClassB

  expect a is I1
  expect a is I2
  expect a is I3
  expect a is I4
  expect a is I5

  expect b is I1
  expect b is I2
  expect b is I3
  expect b is I4
  expect b is not I5

  expect (confuse a) is I1
  expect (confuse a) is I2
  expect (confuse a) is I3
  expect (confuse a) is I4
  expect (confuse a) is I5

  expect (confuse b) is I1
  expect (confuse b) is I2
  expect (confuse b) is I3
  expect (confuse b) is I4
  expect (confuse b) is not I5

  expect-equals 41 a.a-method
  expect-equals 42 a.b-method
  expect-equals 43 a.c-method
  expect-equals 44 a.d-method
  expect-equals 45 a.e-method

  expect-equals 41 b.a-method
  expect-equals 42 b.b-method
  expect-equals 43 b.c-method
  expect-equals 44 b.d-method

  expect-equals 41 (confuse a).a-method
  expect-equals 42 (confuse a).b-method
  expect-equals 43 (confuse a).c-method
  expect-equals 44 (confuse a).d-method
  expect-equals 45 (confuse a).e-method

  expect-equals 41 (confuse b).a-method
  expect-equals 42 (confuse b).b-method
  expect-equals 43 (confuse b).c-method
  expect-equals 44 (confuse b).d-method
