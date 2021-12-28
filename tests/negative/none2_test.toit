// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:

test5:
  while (return 499):
    throw "bad"

test6:
  (return 499) or (throw "bad")

test7:
  (return 499) and (throw "bad")

none_fun -> none:

global := null

main:
  if none_fun: null
  none_fun ? true : false
  not none_fun
  while none_fun: null
  for ; none_fun;: null

  none_fun or none_fun
  none_fun and none_fun

  local := none_fun
  local = none_fun

  global = none_fun

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
