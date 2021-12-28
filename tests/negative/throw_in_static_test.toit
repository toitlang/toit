// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  static foo: throw "x"

main:
  A.foo
