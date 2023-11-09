// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

events := []

mixin Mix1:
  bool-field := false
  int-field := 499

mixin Mix2 extends Mix1:

class A extends Object with Mix2:

class B extends Object with Mix2:
  constructor:
    events.add "ClassB"

class C extends Object with Mix2:
  field := 499

main:
  a := A
  expect-equals false a.bool-field
  expect-equals 499 a.int-field

  b := B
  expect-equals ["ClassB"] events
  expect-equals false b.bool-field
  expect-equals 499 b.int-field

  c := C
  expect-equals false c.bool-field
  expect-equals 499 c.int-field
  expect-equals 499 c.field
