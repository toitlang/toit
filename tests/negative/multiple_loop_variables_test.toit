// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x y:

main:
  for (foo (x := 499) (y := 42)); x < 500 and y < 44; foo x++ y++:
    foo x y
  
  while (foo (x := 499) (y := 42)):
    x++
    y++
