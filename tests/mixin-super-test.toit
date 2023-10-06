// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  a-method: return 41

mixin MixB extends MixA:
  b-method: return 42

mixin MixC extends MixB:
  c-method: return 43

class ClassA extends Object with MixC:
  a-method: return super
  b-method: return super
  c-method: return super

main:
  a := ClassA
  // The static type check doesn't complain, but we still have a dynamic error.
  // expect-equals 41 a.a-method
  // expect-equals 42 a.b-method
  // expect-equals 43 a.c-method
