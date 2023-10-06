// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  method-1: return "A1"
  method-2: return "A2"
  method-4: return "A4"

mixin MixB:
  method-1: return "B1"
  method-3: return "B3"

class ClassA extends Object with MixA MixB:
  method-4: return "ClassA-4"


mixin MixAA:
  method-1: return "AA1"
  method-2: return "AA2"
  method-3: return "AA3"

mixin MixBB:
  method-1: return "BB1"
  method-2: return "BB2"

mixin MixCC extends MixAA with MixBB:
  method-1: return "CC1"
  method-3: return "CC3"

class ClassB extends Object with MixCC:

main:
  a := ClassA
  expect-equals "B1" a.method-1
  expect-equals "A2" a.method-2
  expect-equals "B3" a.method-3
  expect-equals "ClassA-4" a.method-4

  b := ClassB
  expect-equals "CC1" b.method-1
  expect-equals "BB2" b.method-2
  expect-equals "CC3" b.method-3
