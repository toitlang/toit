// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  p := Point 2 3
  expect-equals 2 p.x
  expect-equals 3 p.y
  expect-equals 0 p.z

  p = Point 2 3: it + 4
  expect-equals 2     p.x
  expect-equals 3 + 4 p.y
  expect-equals 0     p.z

  cp := ColorPoint 4 5 100
  expect-equals 4   cp.x
  expect-equals 5   cp.y
  expect-equals 100 cp.color

  cp = ColorPoint 4 5: 100
  expect-equals 4     cp.x
  expect-equals 5 + 2 cp.y
  expect-equals 100   cp.color

  mp := MyPoint 2 3
  expect-equals 2     mp.x
  expect-equals 3     mp.y
  expect-equals 2 + 3 mp.magic

  yp := YourPoint 1 2
  expect-equals 4 yp.x
  expect-equals 5 yp.y
  expect-equals 1 yp.w
  expect-equals 2 yp.h

  sp := SettingParameters 123
  expect-equals 124 sp.x
  expect-equals 42  sp.y

  sp = SettingParameters 99 88
  expect-equals 99 sp.x  // Implicit setting parameter.
  expect-equals 88 sp.y

  sp = SettingParameters 1 2 3
  expect-equals 0 sp.x
  expect-equals 2 sp.y

  sp = SettingParameters 11 22 33 44
  expect-equals 33 sp.x
  expect-equals 44 sp.y

class Point:
  x := ?
  y := ?
  z := 0
  constructor .x .y:

  constructor .x v [block]:
    y = block.call v

class ColorPoint extends Point:
  color := null
  constructor x y this.color:
    super x y
  constructor x y [block]:
    super x y: it + 2
    color = block.call

class MyPoint extends Point:
  magic := 0
  constructor x y:
    super x y
    magic = x + y

class YourPoint extends Point:
  w := ?
  h := 42
  constructor .w .h:
    super 4 5

class SettingParameters:
  x := 0
  y ::= 499

  constructor this.x:
    x++  // Changing the field.
    y = 42

  constructor x .y:
    this.x = x

  constructor not-field this.y z:

  constructor not-field1 not-field2 this.x this.y:
