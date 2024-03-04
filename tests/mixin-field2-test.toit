// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo [block]:
  block.call

mixin MixA:
  field/int? := null
  field2/int := 99

  constructor:
    field = 42
    foo:
      foo:
        field = 400 + field2

class ClassA extends Object with MixA:

main:
  a := ClassA
  expect-equals 499 a.field
