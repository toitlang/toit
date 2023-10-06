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

foo-MixA o/MixA:
foo-MixB o/MixB:
foo-MixC o/MixC:

confuse x -> any: return x

main:
  a := ClassA
  foo-MixA a
  foo-MixB a
  foo-MixC a
