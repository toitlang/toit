// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  x := 0
  static constructor:
    this.x = 5

main:
  print (A).x
