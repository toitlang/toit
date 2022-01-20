// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

use x:
  // Do nothing.

class A:
  x := 0
  constructor:
    use x
    x = 499
    super

class B:
  x:
    throw "bad"

  x val:
    throw "bad too"

main:
  b := B
