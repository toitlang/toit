// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo x:

x := null
global := x = 499

class A:
  field := x = 499

  constructor:
    foo x = 499

  static bar:
    foo x = 499

  instance:
    foo x = 499

main:
  block := :
    foo x = 499
  lambda := ::
    foo x = 499

  try:
    foo x = 499
  finally:

  if true:
    foo x = 499
  y := x = 42 ? true : false
  y2 := true ? x = 42 : false
  y3 := true ? true : x = 42

  not x = 499

  (x = 499)

  if x = 42: null
  while x = 42: null
