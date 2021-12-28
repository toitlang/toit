// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:
  constructor:

  constructor.factory -> A:
    return A

  constructor.factory2 x -> B:
    return B

class B extends A:

main:
  A
  A.factory
  A.factory2 499
