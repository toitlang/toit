// Copyright (C) 2019 Toitware ApS. All rights reserved.

class A:
  + x:
    return x

  bar x y:

  foo:
    // Make sure we don't report invalid shape errors, when
    // we used "invalid" identifiers.
    this.- 42 unresolved
    this.bar 33

main:
  (A).foo
