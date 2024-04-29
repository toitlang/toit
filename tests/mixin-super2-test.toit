// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  method: return "MixA"

mixin MixB:
  method: return "MixB"

class ClassA extends Object with MixA MixB:
  method: return "ClassA-$super"

main:
  a := ClassA
  // Check that the order of the mixins is correct.
  expect-equals "ClassA-MixB" a.method
