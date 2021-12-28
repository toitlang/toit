// Copyright (C) 2019 Toitware ApS. All rights reserved.

x := 9
foo .x:
  unresolved

class A:
  z := 0
  static y := 0

  static bar .y:
    unresolved

  static gee .z:
    unresolved

main:
  foo 19
  A.bar 20
  A.gee 99
