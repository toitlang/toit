// Copyright (C) 2019 Toitware ApS. All rights reserved.

// Regression test. This code yielded an argument-mismatch error.

class A:
  constructor.internal:

  constructor:
    return A 1 2

  constructor x y:
    return A.internal

main:
  a := A
