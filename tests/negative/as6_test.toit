// Copyright (C) 2020 Toitware ApS. All rights reserved.

interface A:

class B:

class C implements A:

main:
  c := C  // Instantiate C, so that the `as` check isn't constant folded.
  B as A
