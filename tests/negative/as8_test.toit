// Copyright (C) 2020 Toitware ApS. All rights reserved.

class A:

class B extends A:

main:
  x := null
  x = 499
  if Time.now.s_since_epoch == 0: x = B
  // The class A is removed from the output, since it is
  // never initialized. We still want to have an error message
  // that mentions "A" and not just "B"
  x as A
