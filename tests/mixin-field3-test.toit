// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo [block]:
  block.call

mixin MixA:
  field/int? := null
  field2/int := 499

  constructor:
    field = 42

mixin MixB extends MixA:
  foo:
    return field

  bar:
    return field2

class ClassA extends Object with MixA:

class ClassB extends Object with MixB:
  b-field1 := "a"
  b-field2 := "b"

main:
  a := ClassA
  expect-equals 42 a.field
  expect-equals 499 a.field2

  b := ClassB
  expect-equals 42 b.field
  expect-equals 499 b.field2
  expect-equals "a" b.b-field1
  expect-equals "b" b.b-field2

  expect-equals 42 b.foo
  expect-equals 499 b.bar
