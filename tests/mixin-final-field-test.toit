// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

import .confuse

mixin MixA:
  field-A/int ::= 499

class ClassA extends Object with MixA:

main:
  a := ClassA
  expect-throw "FINAL_FIELD_ASSIGNMENT_FAILED": (confuse a).field-A = 42
