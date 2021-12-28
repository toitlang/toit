// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  foo= x:
    throw "ok"

main:
  a := null
  a = A
  a.foo = 499
