// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

events := []

mixin Mix1:
  constructor:
    events.add "Mix1"

class A extends Object with Mix1:

class B extends Object with Mix1:
  constructor:
    events.add "ClassB"

class C extends Object with Mix1:
  field := 499

main:
  a := A
  expect-equals ["Mix1"] events
  events.clear

  b := B
  expect-equals ["ClassB", "Mix1"] events
  events.clear

  c := C
  expect-equals ["Mix1"] events
  events.clear
  expect-equals 499 c.field
