// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  static foo:
    super
    unresolved1
  constructor:
    super
    unresolved2
    return A.named
  constructor.named:

main:
  a := A
