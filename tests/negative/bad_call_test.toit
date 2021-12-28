// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  constructor:
    super
    super foo := 0
    print foo

  constructor.named:
    print
      super foo := 0
    print foo

  constructor.factory:
    print
      super foo := 0
    print foo
    return A

  static method:
    super foo := 0
    print foo

main:
  foo foo := 0
  debug foo
