// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .confuse

mixin MixA:
  a-method: return 41

mixin MixB extends MixA:
  b-method: return 42

mixin MixC:
  c-method: return 43

mixin MixD extends MixB with MixC:
  d-method: return 44

mixin MixE:
  e-method: return 45

class ClassA extends Object with MixD MixE:

class ClassB extends Object with MixD:

main:
  a := ClassA
  b := ClassB

  expect a is MixA
  expect a is MixB
  expect a is MixC
  expect a is MixD
  expect a is MixE

  expect b is MixA
  expect b is MixB
  expect b is MixC
  expect b is MixD
  expect b is not MixE

  expect (confuse a) is MixA
  expect (confuse a) is MixB
  expect (confuse a) is MixC
  expect (confuse a) is MixD
  expect (confuse a) is MixE

  expect (confuse b) is MixA
  expect (confuse b) is MixB
  expect (confuse b) is MixC
  expect (confuse b) is MixD
  expect (confuse b) is not MixE
