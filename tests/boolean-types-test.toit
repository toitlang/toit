// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo x/True:
bar x/False:
gee1 -> True:
  local := false
  return local
gee2 -> False:
  local := true
  return local

global1/True := true
global2/False := false

main:
  x := true
  y := false
  expect-throw "AS_CHECK_FAILED": foo y
  expect-throw "AS_CHECK_FAILED": bar x
  expect-throw "AS_CHECK_FAILED": global1 = y
  expect-throw "AS_CHECK_FAILED": global2 = x
  expect-throw "AS_CHECK_FAILED": gee1
  expect-throw "AS_CHECK_FAILED": gee2
