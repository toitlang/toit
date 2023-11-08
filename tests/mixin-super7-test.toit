// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin Mix1:
  field/int := 499

class A extends Object with Mix1:
  constructor.named:

main:
  a := A.named
  expect-equals 499 a.field
