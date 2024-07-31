// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x/True:
bar x/False:
gee1 -> True: return true
gee2 -> False: return false

global1/True := true
global2/False := false
global3 := true
global4 := false

main:
  x := true
  y := gee1
  z := gee2

  // All of the following lines must be without warning and static errors.
  // Some would fail dynamically.
  x = false
  y = false
  z = true
  global3 = false
  global4 = true
  foo true
  bar false
  foo x
  foo y
  foo z
  bar x
  bar y
  bar z
  foo global1
  bar global2

  // The following lines should fail with a static error.
  global1 = false
  global2 = true
  foo false
  bar true
  foo gee2
  bar gee1
  global1 = gee2
  global2 = gee1
