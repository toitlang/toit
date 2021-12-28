// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  constructor .x:
    unresolved

  foo .x:
    unresolved

  static bar .x:
    unresolved

main:
  a := A 5
  a.foo 3
  A.bar 5
