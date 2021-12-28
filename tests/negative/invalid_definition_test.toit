// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo x:

global := x := 499

class A:
  field := x := 499

  constructor:
    foo x := 499
    foo y ::= 499

  static bar:
    foo x := 499
    foo y ::= 499

  instance:
    foo x := 499

bar -> int:
  return x + x x := 499

main:
  block := :
    foo x := 499
  lambda := ::
    foo x := 499

  try:
    x := 499
    foo y := 499
  finally:

  if true:
    foo x := 499
  y := x := 42 ? true : false
  y2 := true ? z := 42 : false
  y3 := true ? true : zz := 42

  not x := 499

  (x := 499)
