// Copyright (C) 2020 Toitware ApS. All rights reserved.

foo x / none:

class A:
  field / none := 0
  constructor field / none:

  instance x / none:
  static statik x / none:

main:
  foo null
  a := A null
  a.instance null
  A.statik null

