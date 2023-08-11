// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:

test5:
  while (return 499):
    throw "bad"

test6:
  (return 499) or (throw "bad")

test7:
  (return 499) and (throw "bad")

none-fun -> none:

global := null

main:
  if none-fun: null
  none-fun ? true : false
  not none-fun
  while none-fun: null
  for ; none-fun;: null

  none-fun or none-fun
  none-fun and none-fun

  local := none-fun
  local = none-fun

  global = none-fun

  a := A
  a2 := null or a

  a2 = a or unreachable

  "" ? 4 : null
  if "":
    true
  else:
    throw "bad"

  null ? false : true
  null
    ? unreachable
    : null ? unreachable : true

  marker := null
  if 0:
    marker = "good"
  else:
    marker = "bad"

  unresolved
