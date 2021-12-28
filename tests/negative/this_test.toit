// Copyright (C) 2019 Toitware ApS. All rights reserved.

bar x:
  return x

class A:
  foo:
    return 499

  constructor:
    foo
    super

  constructor.named:
    bar this
    super

  field := foo
  field2 := bar this

  static gee:
    return this + foo

main:
  a := A
