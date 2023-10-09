// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  field-A/int := 499

class ClassA extends Object with MixA:

confuse x -> any: return x

main:
  a := ClassA
  expect-throw "AS_CHECK_FAILED": (confuse a).field-A = "str"
