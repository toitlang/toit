// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  a-method: return 41

mixin MixB extends MixA:
  b-method: return 42

abstract mixin MixC extends MixB:
  abstract c-method -> int

class ClassA extends Object with MixC:
  c-method: return 43

class SubClassA extends ClassA:
  c-method: return 44

abstract mixin MixForMixin:
  abstract e-method -> int

mixin MixD extends MixA with MixForMixin:
  e-method: return 499

class ClassB extends Object with MixD:
  c-method: return 44

class SubClassB extends ClassB:
  c-method: return 45

confuse x -> any: return x

main:
  a := ClassA
  sub-a := SubClassA
  b := ClassB
  sub-b := SubClassB

  expect-equals 41 a.a-method
  expect-equals 42 a.b-method
  expect-equals 43 a.c-method

  expect-equals 41 sub-a.a-method
  expect-equals 42 sub-a.b-method
  expect-equals 44 sub-a.c-method

  expect-equals 41 b.a-method
  expect-equals 44 b.c-method
  expect-equals 499 b.e-method

  expect-equals 41 sub-b.a-method
  expect-equals 45 sub-b.c-method
  expect-equals 499 sub-b.e-method

  confused := confuse a
  expect-equals 41 confused.a-method
  expect-equals 42 confused.b-method
  expect-equals 43 confused.c-method

  confused = confuse sub-a
  expect-equals 41 confused.a-method
  expect-equals 42 confused.b-method
  expect-equals 44 confused.c-method

  confused = confuse b
  expect-equals 41 confused.a-method
  expect-equals 44 confused.c-method
  expect-equals 499 confused.e-method

  confused = confuse sub-b
  expect-equals 41 confused.a-method
  expect-equals 45 confused.c-method
  expect-equals 499 confused.e-method
