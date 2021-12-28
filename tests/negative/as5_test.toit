// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:

class B extends A:

main:
  b := B  // Instantiate, so that the `as` test isn't constant-folded.
  A as B
