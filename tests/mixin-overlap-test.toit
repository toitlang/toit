// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Tests that partially overridden methods are still available and
  called correctly.
*/

import expect show *

mixin MixA:
  method --only-mixA/bool=false: return "MixA"

mixin MixB extends MixA:
  method --only-mixB/bool=false: return "MixB"

mixin MixC extends MixB:
  method --only-mixC/bool=false: return "MixC"

class ClassA extends Object with MixC:
  method: return "ClassA"

main:
  a := ClassA
  expect-equals "ClassA" a.method
  expect-equals "MixA" (a.method --only-mixA)
  expect-equals "MixB" (a.method --only-mixB)
  expect-equals "MixC" (a.method --only-mixC)
