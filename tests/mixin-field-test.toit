// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

mixin MixA:
  field-A/int? := null
  field-A2 := null

  get-field-A: return field-A
  get-field-A2: return field-A2

mixin MixB:
  field-B/string? := null
  field-B2 := null

  get-field-B: return field-B
  get-field-B2: return field-B2

class ClassA extends Object with MixA MixB:
  field-classA/string := "ClassA"

  this-field-A: return field-A
  this-field-A2: return field-A2
  this-field-B: return field-B
  this-field-B2: return field-B2

class SubClassA extends ClassA:
  field-classSubA/string := "ClassSubA"

  this-field-A: return field-A
  this-field-A2: return field-A2
  this-field-B: return field-B
  this-field-B2: return field-B2

mixin MixAA:
  field-AA/int? := null
  field-AA2 := null

mixin MixBB:
  field-BB/string? := null
  field-BB2 := null

mixin MixCC extends MixAA with MixBB:
  field-CC/string := "CC"
  field-CC2 := null

class ClassB extends Object with MixCC:
  field-classB/string := "ClassB"

  this-field-AA: return field-AA
  this-field-AA2: return field-AA2
  this-field-BB: return field-BB
  this-field-BB2: return field-BB2
  this-field-CC: return field-CC
  this-field-CC2: return field-CC2

class SubClassB extends ClassB:
  field-classSubB/string := "ClassSubB"

do-test a-or-sub-a/ClassA -> Map:
  expect-null a-or-sub-a.field-A
  expect-null a-or-sub-a.field-A2
  expect-null a-or-sub-a.field-B
  expect-null a-or-sub-a.field-B2

  a-or-sub-a.field-A = 1
  a-or-sub-a.field-A2 = 2
  a-or-sub-a.field-B = "3"
  a-or-sub-a.field-B2 = "4"
  a-or-sub-a.field-classA = "5"

  if a-or-sub-a is SubClassA:
    (a-or-sub-a as SubClassA).field-classSubA = "6"
    expect-equals "6" (a-or-sub-a as SubClassA).field-classSubA

  expect-equals 1 a-or-sub-a.field-A
  expect-equals 2 a-or-sub-a.field-A2
  expect-equals "3" a-or-sub-a.field-B
  expect-equals "4" a-or-sub-a.field-B2
  expect-equals "5" a-or-sub-a.field-classA

  expect-equals 1 a-or-sub-a.this-field-A
  expect-equals 2 a-or-sub-a.this-field-A2
  expect-equals "3" a-or-sub-a.this-field-B
  expect-equals "4" a-or-sub-a.this-field-B2
  expect-equals "5" a-or-sub-a.field-classA

  untyped/any := a-or-sub-a
  expect-throw "AS_CHECK_FAILED": untyped.field-A = true
  untyped.field-A2 = true
  expect-equals true untyped.field-A2
  expect-throw "AS_CHECK_FAILED": untyped.field-B = true
  untyped.field-B2 = true
  expect-equals true untyped.field-B2

  return {
    "field-A": a-or-sub-a.field-A,
    "field-A2": a-or-sub-a.field-A2,
    "field-B": a-or-sub-a.field-B,
    "field-B2": a-or-sub-a.field-B2,
    "field-classA": a-or-sub-a.field-classA,
  }

main:
  a := ClassA
  sub-a := SubClassA
  expect a.field-classA == "ClassA"
  expect sub-a.field-classSubA == "ClassSubA"

  values := do-test a
  // Check that a static resolution also works.
  expect-equals values["field-A"] a.field-A
  expect-equals values["field-A2"] a.field-A2
  expect-equals values["field-B"] a.field-B
  expect-equals values["field-B2"] a.field-B2
  expect-equals values["field-classA"] a.field-classA

  values = do-test sub-a
  expect-equals values["field-A"] sub-a.field-A
  expect-equals values["field-A2"] sub-a.field-A2
  expect-equals values["field-B"] sub-a.field-B
  expect-equals values["field-B2"] sub-a.field-B2
  expect-equals values["field-classA"] sub-a.field-classA
