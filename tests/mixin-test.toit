// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .confuse

mixin MixA:
  a_method: return 41

mixin MixB extends MixA:
  b_method: return 42

abstract mixin MixC extends MixB:
  abstract c_method -> int

class ClassA extends Object with MixC:
  c_method: return 43

class SubClassA extends ClassA:
  c_method: return 44

abstract mixin MixForMixin:
  abstract e_method -> int

mixin MixD extends MixA with MixForMixin:
  e_method: return 499

class ClassB extends Object with MixD:
  c_method: return 44

class SubClassB extends ClassB:
  c_method: return 45

main:
  a := ClassA
  sub-a := SubClassA
  b := ClassB
  sub-b := SubClassB

  expect-equals 41 a.a_method
  expect-equals 42 a.b_method
  expect-equals 43 a.c_method

  expect-equals 41 sub-a.a_method
  expect-equals 42 sub-a.b_method
  expect-equals 44 sub-a.c_method

  expect-equals 41 b.a_method
  expect-equals 44 b.c_method
  expect-equals 499 b.e_method

  expect-equals 41 sub-b.a_method
  expect-equals 45 sub-b.c_method
  expect-equals 499 sub-b.e_method

  confused := confuse a
  expect-equals 41 confused.a_method
  expect-equals 42 confused.b_method
  expect-equals 43 confused.c_method

  confused = confuse sub-a
  expect-equals 41 confused.a_method
  expect-equals 42 confused.b_method
  expect-equals 44 confused.c_method

  confused = confuse b
  expect-equals 41 confused.a_method
  expect-equals 44 confused.c_method
  expect-equals 499 confused.e_method

  confused = confuse sub-b
  expect-equals 41 confused.a_method
  expect-equals 45 confused.c_method
  expect-equals 499 confused.e_method
