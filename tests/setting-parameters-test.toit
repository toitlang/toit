// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  using-this
  using-period

using-this:
  sp := SettingParameters
  expect-equals 0 sp.x
  expect-equals 499 sp.y

  sp.foo 42 123
  expect-equals 42 sp.x
  expect-equals 123 sp.y

  sp.bar 1 2
  expect-equals 43 sp.x
  expect-equals 3 sp.y

  sp2 := SettingParameters2
  sp2.bar 1 2
  expect-equals 1 sp2.x
  expect-equals 2 + 11 + 7 + 1 + 11 + 7 sp2.y  // Access of `y` goes through the overwritten getter/setter.

using-period:
  sp := SettingParametersB
  expect-equals 0 sp.x
  expect-equals 499 sp.y

  sp.foo 42 123
  expect-equals 42 sp.x
  expect-equals 123 sp.y

  sp.bar 1 2
  expect-equals 43 sp.x
  expect-equals 3 sp.y

  sp2 := SettingParameters2B
  sp2.bar 1 2
  expect-equals 1 sp2.x
  expect-equals 2 + 11 + 7 + 1 + 11 + 7 sp2.y  // Access of `y` goes through the overwritten getter/setter.

class SettingParameters:
  x := 0
  y := 499

  foo this.x this.y:

  bar x this.y:  // The this.y is not visible as parameter in the body.
    this.x += x
    y++  // Updates the variable.

class SettingParameters2 extends SettingParameters:
  y:
    return super + 7

  y= x:
    super = (x + 11)

class SettingParametersB:
  x := 0
  y := 499

  foo .x .y:

  bar x .y:  // The this.y is not visible as parameter in the body.
    this.x += x
    y++  // Updates the variable.

class SettingParameters2B extends SettingParametersB:
  y:
    return super + 7

  y= x:
    super = (x + 11)
