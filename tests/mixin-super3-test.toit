// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

events ::= []

class W:
  x/any
  constructor .x:
    events.add "constructing $x"

mixin MixA:
  fieldA := W "A"
  constructor:
    events.add "in mix a"

mixin MixB extends MixA:
  fieldB1 := W "B1"
  fieldB2 := W "B2"

  constructor:
    events.add "in mix b"

mixin MixC:
  fieldC := W "C"

  constructor:
    events.add "in mix c"

mixin MixD extends MixB with MixC:
  fieldD1 := W "D1"
  fieldD2 := ?
  fieldD3 := ?

  constructor:
    fieldD2 = W "D2"
    fieldD3 = W "D3"
    events.add "in mix d"

mixin MixE:
  fieldE := ?
  constructor:
    fieldE = W "E"
    events.add "in mix e"

class ClassA extends ClassB with MixD MixE:
  constructor x:
    block-local := (: x + 1)
    local-var := 9911
    super p1 local-var "literal" block-local:
      events.add "in block a"
      499

p1:
  events.add "1"
  return 11

class ClassB:
  constructor param1 param2 param3 [block1] [block2]:
    events.add "in constructor B"
    events.add "param1: $param1"
    events.add "param2: $param2"
    events.add "param3: $param3"
    events.add block1.call
    events.add block2.call

main:
  a := ClassA 1234

  expected := [
    "1",  // Created as part of the argument to the constructor of the ClassB super call.
    "constructing E",  // A field of the MixE mixin.
    "in mix e",
    "constructing D1", // Fields of the MixD mixin.
    "constructing D2",
    "constructing D3",
    "in mix d",
    "constructing C",
    "in mix c",
    "constructing B1",
    "constructing B2",
    "in mix b",
    "constructing A",
    "in mix a",
    "in constructor B",
    "param1: 11",       // Arguments to the constructor of ClassB.
    "param2: 9911",
    "param3: literal",
    1235,
    "in block a",
    499,
  ]
  expect_equals expected events

  expect a is MixA
  expect a is MixB
  expect a is MixC
  expect a is MixD
  expect a is MixE

  expect_equals "A" a.fieldA.x
  expect_equals "B1" a.fieldB1.x
  expect_equals "B2" a.fieldB2.x
  expect_equals "C" a.fieldC.x
  expect_equals "D1" a.fieldD1.x
  expect_equals "D2" a.fieldD2.x
  expect_equals "D3" a.fieldD3.x
  expect_equals "E" a.fieldE.x
