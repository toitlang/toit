// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

events := []

mixin MixA:
  constructor:
    events.add "MixA1"
    super
    events.add "MixA2"

add-event:
  events.add "e"

class ClassB:
  constructor i [block]:
    events.add "ClassB"
    o := block.call
    if i == 0: expect o is ClassB
    if i == 1: expect-null o

class ClassA extends ClassB with MixA:
  constructor:
    events.add "ClassA1"
    // Test that we only change the super call to 'ClassB', and no
    // other call to the constructor.
    super 0: (ClassB 1: null)
    events.add "ClassA2"

main:
  a := ClassA
  expected := ["ClassA1", "MixA1", "ClassB", "ClassB", "MixA2", "ClassA2"]
  expect-list-equals expected events
