// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:

class B extends A:

main:
  x := null
  x = 499
  if Time.now.s-since-epoch == 0: x = B
  // The class A is removed from the output, since it is
  // never initialized. We still want to have an error message
  // that mentions "A" and not just "B"
  x as A
